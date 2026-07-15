#!/usr/bin/env bash
# Recompute AirTrail's Nix hashes after Renovate bumps `version` in package.nix.
#
# Renovate's customManager rewrites the `version = "X.Y.Z"` string in package.nix,
# then runs this as a postUpgradeTask (arg $1 = the new version). Three hashes are
# recomputed in dependency order:
#   1. src hash        — fetchFromGitHub johanohly/AirTrail (deterministic via nurl)
#   2. depsBuild FOD   — `bun install` full tree, outputHash
#   3. depsProd FOD    — `bun install --production`, outputHash
# The two FODs are exposed via passthru (package.nix) so each can be built alone.
# Requires nurl + nix on PATH (the CI workflow installs them).
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
  ver=$(grep -oE 'version = "[^"]+"' package.nix | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
echo ">> recomputing hashes for airtrail v$ver"

# 1. src hash. Only the fetchFromGitHub line is `  hash = "sha256-…"` (lowercase h);
# the two FODs use `outputHash = "…"`, so anchoring on `^\s*hash = "` is unambiguous.
newsrc=$(nurl "https://github.com/johanohly/AirTrail" "v$ver" 2>/dev/null \
           | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
[ -n "$newsrc" ] || { echo "ERROR: nurl returned no src hash for v$ver"; exit 1; }
sed -i -E "s#(^[[:space:]]*hash = \")sha256-[A-Za-z0-9+/=]+#\1$newsrc#" package.nix
echo ">> src hash   = $newsrc"

# 2+3. Each bun-install FOD: build in isolation; on a hash mismatch capture the
# real `got:` hash and replace the stale `specified:` value (unique per FOD, so a
# value-based substitution never touches the other FOD or the src).
recompute_fod() {
  local attr="$1" out spec got
  out=$(nix build ".#airtrail.$attr" --no-link 2>&1) || true
  if printf '%s\n' "$out" | grep -q 'hash mismatch'; then
    spec=$(printf '%s\n' "$out" | grep -oE 'specified:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
    got=$(printf '%s\n' "$out"  | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+'       | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
    [ -n "$spec" ] && [ -n "$got" ] || { printf '%s\n' "$out"; echo "ERROR: $attr mismatch without spec/got"; exit 1; }
    sed -i "s#$spec#$got#g" package.nix
    echo ">> $attr = $got (updated)"
    nix build ".#airtrail.$attr" --no-link >/dev/null # confirm it now resolves
  elif printf '%s\n' "$out" | grep -qE '^/nix/store/'; then
    echo ">> $attr unchanged"
  else
    printf '%s\n' "$out"; echo "ERROR: $attr build failed for a reason other than a hash mismatch"; exit 1
  fi
}
recompute_fod depsBuild
recompute_fod depsProd

echo ">> hash recompute complete for airtrail v$ver"
