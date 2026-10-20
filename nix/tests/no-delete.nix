# Fast, sandboxed check (no VM): run the real server binary over MCP stdio and
# prove the delete surface is gone, then prove the in-process guard holds.
{ pkgs }:

pkgs.runCommand "devbox-mcp-no-delete"
  {
    nativeBuildInputs = [ pkgs.nodejs ];
  }
  ''
    export HOME=$TMPDIR
    node ${./probe.mjs} \
      ${pkgs.lib.getExe pkgs.devbox-mcp} \
      ${pkgs.devbox-mcp}/lib/node_modules/@microsoft/devbox-mcp/dist/delete-guard.mjs

    # Negative control: the same probe MUST fail against stock upstream,
    # otherwise the assertions above are vacuous.
    if node ${./probe.mjs} ${pkgs.lib.getExe pkgs.devbox-mcp-unpatched} - > unpatched.log 2>&1; then
      cat unpatched.log
      echo "FAIL: probe passed against unpatched upstream; the test proves nothing" >&2
      exit 1
    fi
    grep -E "AssertionError|delete" unpatched.log | head -5
    echo "ok: negative control: stock upstream exposes delete and the probe catches it"
    touch $out
  ''
