# The patched source re-packed as a normal npm package, published to Azure
# Artifacts so Windows can `npx` it. Nix is the only thing that ever applies the
# patch; Windows just installs the result.
#
# Version: <upstream>.nodelete.<revision> (or <upstream>-nodelete.<revision> when
# upstream has no prerelease tag). Bump nix/publish.json `revision` whenever the
# patch changes without an upstream version change.
#
# The tarball is reproducible (pinned inputs, fixed mtimes), so CI can compare
# its sha512 with what the feed already holds and refuse to publish different
# bytes under an existing version.
{ lib, runCommand, nodejs, jq, fetchurl, devbox-mcp-src }:

let
  publish = lib.importJSON ./publish.json;
  upstream = devbox-mcp-src.upstream;
  sep = if lib.hasInfix "-" upstream.version then "." else "-";
  version = "${upstream.version}${sep}nodelete.${toString publish.revision}";

  # Upstream's npm tarball ships no LICENSE file; MIT requires the notice.
  license = fetchurl {
    url = "https://raw.githubusercontent.com/microsoft/devbox-mcp-server/4ec8c247278a6e79ae23de4b1eb0315557f00ff2/LICENSE";
    hash = "sha256-mKlsOElN9JY5UeMrgexO/+vkyKgSq42efRhdWehv4vw=";
  };

  notice = ''
    > **Unofficial rebuild of [`@microsoft/devbox-mcp@${upstream.version}`](https://www.npmjs.com/package/@microsoft/devbox-mcp/v/${upstream.version}) with every delete capability removed.**
    > `devbox_resource` accepts only `read`/`create`, `workplanner_delete_task` is gone, and the
    > process refuses to send any HTTP `DELETE` or call any `/delete…` endpoint.
    > Built reproducibly with Nix; not supported by Microsoft.

  '';
in
assert devbox-mcp-src.blockDelete;
runCommand "devbox-mcp-nodelete-${version}.tgz"
  {
    nativeBuildInputs = [ nodejs jq ];
    passthru = { inherit version; packageName = publish.name; };
  }
  ''
    cp -r ${devbox-mcp-src} pkg
    chmod -R u+w pkg
    cd pkg

    jq --arg name ${lib.escapeShellArg publish.name} --arg version ${lib.escapeShellArg version} \
       --arg upstream ${lib.escapeShellArg upstream.version} '
      .name = $name
      | .version = $version
      | .description = "Microsoft Dev Box MCP server (@microsoft/devbox-mcp " + $upstream + ") with all delete operations removed"
      | .keywords += ["no-delete"]
      | .upstream = { name: "@microsoft/devbox-mcp", version: $upstream }
    ' package.json > package.json.new
    mv package.json.new package.json

    cp ${license} LICENSE
    { printf '%s' ${lib.escapeShellArg notice}; cat README.md; } > README.md.new
    mv README.md.new README.md

    export HOME=$TMPDIR npm_config_cache=$TMPDIR/npm-cache
    mkdir -p $out
    npm pack --ignore-scripts --pack-destination $out
    cd $out
    tgz=$(echo *.tgz)
    tar -tzf "$tgz" > $TMPDIR/files
    grep -qx 'package/dist/delete-guard.mjs' $TMPDIR/files
    echo "$tgz" > name
    node -e 'const c=require("crypto"),f=require("fs");process.stdout.write("sha512-"+c.createHash("sha512").update(f.readFileSync(process.argv[1])).digest("base64"))' "$tgz" > integrity
  ''
