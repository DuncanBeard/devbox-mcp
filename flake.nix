{
  description = "Microsoft Dev Box MCP server with every delete capability compiled out (overlay, checks, VM test, OCI image)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      }));
    in
    {
      overlays.default = import ./nix/overlay.nix;

      packages = forAllSystems (pkgs: {
        inherit (pkgs) devbox-mcp;
        default = pkgs.devbox-mcp;
        dockerImage = import ./nix/docker.nix { inherit pkgs; };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = pkgs.lib.getExe pkgs.devbox-mcp;
        };
      });

      checks = forAllSystems (pkgs: {
        devbox-mcp = pkgs.devbox-mcp;
        no-delete = import ./nix/tests/no-delete.nix { inherit pkgs; };
        no-delete-vm = import ./nix/tests/no-delete-vm.nix { inherit pkgs; };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.devbox-mcp pkgs.nodejs ];
        };
      });
    };
}
