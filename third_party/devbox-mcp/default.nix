# Linux build of the patched devbox-mcp (node_modules + bin wrapper), for
# `nix run`, dev shells, the VM test and the OCI image.
# The patching itself lives in ./patched-src.nix.
#
# Usage in overlay:
#   devbox-mcp-src = final.callPackage ../third_party/devbox-mcp/patched-src.nix { };
#   devbox-mcp     = final.callPackage ../third_party/devbox-mcp { src = final.devbox-mcp-src; };

{ lib
, buildNpmPackage
, python3
, pkg-config
, libsecret
, src
}:

buildNpmPackage {
  pname = lib.removeSuffix "-src" (lib.replaceStrings [ "-src-" ] [ "-" ] src.pname);
  inherit (src) version;
  inherit src;

  # Generated from upstream's package.json after ./package-json.jq, against
  # registry.npmjs.org (see scripts/bump-upstream.sh).
  postPatch = ''
    chmod -R u+w .
    cp ${./package-lock.json} package-lock.json
  '';

  inherit (src.upstream) npmDepsHash;
  dontNpmBuild = true; # dist/ is prebuilt upstream

  nativeBuildInputs = [ python3 pkg-config ];
  buildInputs = [ libsecret ]; # keytar (token cache) links against libsecret

  passthru = { inherit (src) msg; inherit src; };

  meta = {
    description = "Microsoft Dev Box MCP server with delete operations removed";
    homepage = "https://github.com/microsoft/devbox-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "devbox-mcp-server";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
