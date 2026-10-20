# Edits applied to upstream's package.json. Shared by the Nix build and
# scripts/bump-upstream.sh (lockfile regeneration) so they can't drift.
#
# - devcenter-internal-stable: Microsoft-internal, already webpacked into dist/,
#   not on the public registry.
# - ffi-napi / ref-napi: optional, never referenced by the bundle.
# - devDependencies / scripts: upstream's source build, irrelevant to the prebuilt dist/.
del(
  .dependencies["devcenter-internal-stable"],
  .bundleDependencies,
  .optionalDependencies,
  .devDependencies,
  .scripts
)
