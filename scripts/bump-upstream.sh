#!/usr/bin/env bash
# Bump the pinned upstream @microsoft/devbox-mcp to a new version.
#
#   nix develop .#bump -c ./scripts/bump-upstream.sh            # latest dist-tag
#   nix develop .#bump -c ./scripts/bump-upstream.sh 0.0.4      # specific version
#   nix develop .#bump -c ./scripts/bump-upstream.sh --force    # regenerate for current (idempotence check)
#
# Updates third_party/devbox-mcp/{upstream.json,package-lock.json} and resets
# nix/publish.json revision to 1. It does NOT touch the patch sites: if upstream
# moved code, `nix build` fails at a --replace-fail and a human updates
# third_party/devbox-mcp/patched-src.nix.
#
# Writes `changed`, `from`, `to` to $GITHUB_OUTPUT when run in Actions.
set -euo pipefail
cd "$(dirname "$0")/.."

REG=https://registry.npmjs.org
PKG=@microsoft/devbox-mcp
UP=third_party/devbox-mcp/upstream.json

force=false target=""
for a in "$@"; do
  case "$a" in
    --force) force=true ;;
    "") ;;
    *) target=$a ;;
  esac
done

current=$(jq -r .version "$UP")
target=${target:-$(npm view "$PKG" version --registry "$REG")}
$force && target=${target:-$current}

out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }
out from "$current"
out to "$target"

if [[ "$current" == "$target" ]] && ! $force; then
  echo "up to date: $PKG@$current"
  out changed false
  exit 0
fi

integrity=$(npm view "$PKG@$target" dist.integrity --registry "$REG")
[[ "$integrity" == sha512-* ]] || { echo "no sha512 integrity for $PKG@$target" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
npm pack "$PKG@$target" --registry "$REG" --pack-destination "$tmp" --silent >/dev/null
tar -xzf "$tmp"/*.tgz -C "$tmp"
jq -f third_party/devbox-mcp/package-json.jq "$tmp/package/package.json" > "$tmp/package.json"
mv "$tmp/package.json" "$tmp/package/package.json"
rm -rf "$tmp/package/node_modules"
( cd "$tmp/package" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund --registry "$REG" --silent )
cp "$tmp/package/package-lock.json" third_party/devbox-mcp/package-lock.json

npmDepsHash=$(prefetch-npm-deps third_party/devbox-mcp/package-lock.json 2>/dev/null)

jq -n --arg version "$target" --arg integrity "$integrity" --arg npmDepsHash "$npmDepsHash" \
  '{version: $version, integrity: $integrity, npmDepsHash: $npmDepsHash}' > "$UP"

if [[ "$current" != "$target" ]]; then
  jq '.revision = 1' nix/publish.json > "$tmp/publish.json" && mv "$tmp/publish.json" nix/publish.json
fi

if git diff --quiet -- "$UP" third_party/devbox-mcp/package-lock.json nix/publish.json; then
  echo "no changes"
  out changed false
else
  echo "bumped $PKG: $current -> $target"
  out changed true
fi
