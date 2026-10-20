# OCI image shipping the patched server. No Dockerfile, no npm at runtime:
# the image is exactly the closure of pkgs.devbox-mcp.
{ pkgs }:

pkgs.dockerTools.buildLayeredImage {
  name = "devbox-mcp-no-delete";
  tag = "latest";
  contents = with pkgs; [ devbox-mcp cacert azure-cli ];
  extraCommands = "mkdir -p tmp && chmod 1777 tmp";
  config = {
    Entrypoint = [ (pkgs.lib.getExe pkgs.devbox-mcp) ];
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "HOME=/tmp"
    ];
  };
}
