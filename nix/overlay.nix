# THE single source of truth: anything that asks for pkgs.devbox-mcp gets the
# build with delete compiled out. Dev shells, VMs, containers and agent sandboxes
# all evaluate this one definition, so they can't drift.
final: prev: {
  devbox-mcp = final.callPackage ../third_party/devbox-mcp { };

  # Stock upstream build. Not for use: only the negative control in nix/tests.
  devbox-mcp-unpatched = final.callPackage ../third_party/devbox-mcp { blockDelete = false; };
}
