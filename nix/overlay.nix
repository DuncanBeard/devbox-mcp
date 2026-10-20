# THE single source of truth: anything that asks for pkgs.devbox-mcp (or the
# published npm tarball) gets the build with delete compiled out. Dev shells,
# VMs, containers, agent sandboxes and the Windows npm package all evaluate
# this one definition, so they can't drift.
final: prev: {
  devbox-mcp-src = final.callPackage ../third_party/devbox-mcp/patched-src.nix { };
  devbox-mcp = final.callPackage ../third_party/devbox-mcp { src = final.devbox-mcp-src; };
  devbox-mcp-npm = final.callPackage ./npm-tarball.nix { };

  # Stock upstream build. Not for use: only the negative control in nix/tests.
  devbox-mcp-unpatched = final.callPackage ../third_party/devbox-mcp {
    src = final.callPackage ../third_party/devbox-mcp/patched-src.nix { blockDelete = false; };
  };
}
