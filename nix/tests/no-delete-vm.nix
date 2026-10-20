# NixOS VM test: the whole OS is the system under test. The VM gets
# devbox-mcp from the overlaid package set (runNixOSTest hands every node the
# pkgs it was called with), exactly like an agent sandbox would.
{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "devbox-mcp-no-delete";

  nodes.machine = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.devbox-mcp pkgs.nodejs ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Prove the VM sees the overlaid package, not some other build.
    assert machine.succeed("readlink -f $(command -v devbox-mcp-server)").strip().startswith("${pkgs.devbox-mcp}"), \
        "VM is not using the patched devbox-mcp"

    with subtest("MCP surface has no delete and the guard holds"):
        out = machine.succeed(
            "HOME=/tmp node ${./probe.mjs} "
            "$(command -v devbox-mcp-server) "
            "${pkgs.devbox-mcp}/lib/node_modules/@microsoft/devbox-mcp/dist/delete-guard.mjs 2>&1"
        )
        print(out)
        assert "PASS" in out
  '';
}
