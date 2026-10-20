# The upstream npm tarball with every delete capability compiled out.
#
# Output is a plain source tree (package.json + dist/), platform-independent JS.
# It is consumed by:
#   - ./default.nix              Linux build (adds node_modules, used by nix run / VM test)
#   - ../../nix/npm-tarball.nix  re-packed .tgz published to Azure Artifacts for Windows
# so every consumer gets exactly the same patched bytes.
#
# Upstream publishes a single minified webpack bundle (dist/devbox-mcp-server.mjs,
# ~880 KB on ONE line), not source, so unified diffs are impractical. Instead each
# "patch" is a `substituteInPlace --replace-fail`: if upstream changes the code
# around a patch site, the build FAILS rather than silently shipping without the
# block. That is the same contract a .patch file gives you.
#
# Layers (defence in depth, like nix-demo's 001/002 git patches):
#
#   001 tool surface   - `devbox_resource` loses operation "delete" (schema + dispatch +
#                        validation + handler); every tool whose name matches /delete/i is
#                        dropped at both registries AND at the base-class register() that
#                        calls server.tool(), so `workplanner_delete_task` never exists.
#   002 Azure SDK      - ServiceClient.sendOperationRequest and NodeHttpClient.sendRequest
#                        refuse httpMethod DELETE. Covers devBoxes.deleteDevBox,
#                        environments.deleteEnvironment and any future DELETE operation.
#   003 process guard  - delete-guard.mjs is injected as the bundle's first import and
#                        wraps fetch + node:http + node:https: no DELETE verb and no
#                        `/delete...` endpoint can leave the process, whatever the caller.

{ lib
, stdenvNoCC
, fetchurl
, jq
  # false = stock upstream, used only as the negative control in nix/tests.
, blockDelete ? true
}:

let
  upstream = lib.importJSON ./upstream.json;

  msg = "devbox-mcp: delete is disabled and not allowed";
  err = ''new Error("${msg}")'';
  bundle = "dist/devbox-mcp-server.mjs";

  # [ from to ] pairs, applied with --replace-fail.
  substitutions = [
    # --- 001: tool surface -------------------------------------------------
    # Schema: the agent is never offered "delete" (zod rejects it before any code runs).
    [ ''operation:s.z.enum([n.READ,n.CREATE,n.DELETE]).describe("Operation to perform: read (list/get/query resources), create (create new resource), delete (delete resource)")''
      ''operation:s.z.enum([n.READ,n.CREATE]).describe("Operation to perform: read (list/get/query resources), create (create new resource). Deleting Dev Boxes is not available.")'' ]
    # Dispatch + validation: "delete" falls through to `Unsupported operation parameter`.
    [ "case n.DELETE:c=o.DELETE;break;" "" ]
    [ "case o.DELETE:return await this.handleDeleteOperation(a,{devCenterName:e,locationInUri:t});" "" ]
    [ ''case o.DELETE:if(e.devBoxName===d.bs)throw new Error("Delete operation requires specific devBoxName");if(e.projectName===d.bs)throw new Error("Delete operation requires specific projectName");break;'' "" ]
    # Handler: unreachable now, but make it inert anyway.
    [ "async deleteDevBox(e,t,r,n){" "async deleteDevBox(e,t,r,n){throw ${err};" ]
    # Registration: drop /delete/i tools from the aggregate registry...
    [ "for(const n of r)e.push({tool:n,registrationIndex:t})"
      "for(const n of r)/delete/i.test(n.name)||e.push({tool:n,registrationIndex:t})" ]
    # ...from the per-group registry...
    [ "registerAllTools(){const e=[];for(const t of this.tools)this.disabledTools.has(t.name)||"
      "registerAllTools(){const e=[];for(const t of this.tools)/delete/i.test(t.name)||this.disabledTools.has(t.name)||" ]
    [ "enableTool(e){if(this.disabledTools.has(e)){"
      "enableTool(e){if(/delete/i.test(e))return!1;if(this.disabledTools.has(e)){" ]
    # ...and at the one place every tool reaches the MCP server.
    [ "register(){return this.toolRegistration=this.server.tool(this.name,"
      "register(){if(/delete/i.test(this.name))return this.toolRegistration=void 0;return this.toolRegistration=this.server.tool(this.name," ]
    # WorkPlanner delete-task: no URL to call.
    [ "s=`\${d.C.WORKPLANNER_BASE_URL}\${d.C.WORKPLANNER_DELETE_TASK_API}`"
      "s=(()=>{throw ${err}})()" ]

    # --- 002: Azure SDK ----------------------------------------------------
    [ "async sendOperationRequest(e,t){const r=t.baseUrl||this._endpoint;"
      ''async sendOperationRequest(e,t){if(String(t.httpMethod).toUpperCase()==="DELETE")throw ${err};const r=t.baseUrl||this._endpoint;'' ]
    [ "class y{constructor(){this.cachedHttpsAgents=new WeakMap}async sendRequest(e){"
      ''class y{constructor(){this.cachedHttpsAgents=new WeakMap}async sendRequest(e){if(String(e.method).toUpperCase()==="DELETE")throw ${err};'' ]

    # --- 003: process-wide guard (must be the first import) -----------------
    [ ''import{createRequire as e}from"node:module";''
      ''import"./delete-guard.mjs";import{createRequire as e}from"node:module";'' ]
  ];

  substituteArgs = lib.concatMapStringsSep " \\\n      "
    (p: "--replace-fail ${lib.escapeShellArg (lib.elemAt p 0)} ${lib.escapeShellArg (lib.elemAt p 1)}")
    substitutions;
in
stdenvNoCC.mkDerivation {
  pname = "devbox-mcp-src${lib.optionalString (!blockDelete) "-unpatched"}";
  inherit (upstream) version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@microsoft/devbox-mcp/-/devbox-mcp-${upstream.version}.tgz";
    hash = upstream.integrity;
  };
  sourceRoot = "package";

  nativeBuildInputs = [ jq ];

  postPatch = ''
    jq -f ${./package-json.jq} package.json > package.json.new
    mv package.json.new package.json
    rm -rf node_modules # vendored copy of devcenter-internal-stable; already in dist/
  '' + lib.optionalString blockDelete ''

    cp ${./delete-guard.mjs} dist/delete-guard.mjs
    substituteInPlace ${bundle} \
      ${substituteArgs}

    # Belt and braces: the shapes we removed must be gone.
    for needle in 'n.READ,n.CREATE,n.DELETE' 'case o.DELETE:' 'case n.DELETE:'; do
      if grep -qF "$needle" ${bundle}; then
        echo "delete capability still present: $needle" >&2; exit 1
      fi
    done
    test "$(grep -oF '${msg}' ${bundle} | wc -l)" -ge 4
  '';

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # keep `#!/usr/bin/env node`: this tree is also published for Windows
  installPhase = "cp -r . $out";

  passthru = { inherit msg upstream blockDelete; };
}
