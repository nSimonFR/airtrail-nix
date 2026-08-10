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
# Requires nurl + nix + python3 on PATH (the CI workflow installs them).
#
# The src hash is system-independent, but the two FOD hashes are NOT: `bun install`
# pulls the optional deps matching the host arch, so each system gets its own slot
# in package.nix's `depsHashes`. This script only ever rewrites the slot for the
# system it is running on — the workflow runs it once on x86_64 and once on arm64.
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
  ver=$(grep -oE 'version = "[^"]+"' package.nix | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
echo ">> recomputing hashes for airtrail v$ver"

# 1. src hash. Only the fetchFromGitHub line is `  hash = "sha256-…"` (lowercase h);
# the two FODs use `outputHash = "…"`, so anchoring on `^\s*hash = "` is unambiguous.
# SKIP_SRC_HASH=1 on the arm64 leg: the src hash is system-independent and was
# already written by the x86_64 leg, so that run needs neither nurl nor the fetch.
if [ "${SKIP_SRC_HASH:-0}" = 1 ]; then
  echo ">> src hash   = skipped (SKIP_SRC_HASH=1)"
else
  newsrc=$(nurl "https://github.com/johanohly/AirTrail" "v$ver" 2>/dev/null \
             | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  [ -n "$newsrc" ] || { echo "ERROR: nurl returned no src hash for v$ver"; exit 1; }
  sed -i -E "s#(^[[:space:]]*hash = \")sha256-[A-Za-z0-9+/=]+#\1$newsrc#" package.nix
  echo ">> src hash   = $newsrc"
fi

# 2+3. Each bun-install FOD: build in isolation; on a hash mismatch capture the
# real `got:` hash and write it into this system's slot.
#
# The substitution is scoped to the `<system> = { … };` block rather than done by
# value: two systems can legitimately hold the SAME stale value (e.g. a fresh slot
# seeded from the other arch, or two placeholders), and a global value-based sed
# would then silently clobber the other arch's hash with this arch's result.
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
echo ">> system      = $system"

set_hash() {
  local attr="$1" value="$2"
  python3 - "$system" "$attr" "$value" <<'PY'
import re, sys
system, attr, value = sys.argv[1], sys.argv[2], sys.argv[3]
src = open("package.nix").read()

# Locate `  <system> = {` … matching `  };` (the blocks are single-nested, so the
# first line that dedents back to the block's own indent closes it).
block = re.search(rf'^(\s*){re.escape(system)} = \{{\n(.*?)^\1\}};\n',
                  src, re.M | re.S)
if not block:
    sys.exit(f"ERROR: no depsHashes slot for {system} in package.nix")

body = block.group(2)
new_body, n = re.subn(rf'({re.escape(attr)}\s*=\s*")[^"]*(")',
                      rf'\g<1>{value}\g<2>', body)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 {attr} in the {system} slot, found {n}")

open("package.nix", "w").write(src[:block.start(2)] + new_body + src[block.end(2):])
PY
}

recompute_fod() {
  local attr="$1" out got
  out=$(nix build ".#airtrail.$attr" --no-link 2>&1) || true
  if printf '%s\n' "$out" | grep -q 'hash mismatch'; then
    got=$(printf '%s\n' "$out" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
    [ -n "$got" ] || { printf '%s\n' "$out"; echo "ERROR: $attr mismatch without a got: hash"; exit 1; }
    set_hash "$attr" "$got"
    echo ">> $attr = $got (updated for $system)"
    nix build ".#airtrail.$attr" --no-link >/dev/null # confirm it now resolves
  elif printf '%s\n' "$out" | grep -qE '^/nix/store/'; then
    echo ">> $attr unchanged for $system"
  else
    printf '%s\n' "$out"; echo "ERROR: $attr build failed for a reason other than a hash mismatch"; exit 1
  fi
}
recompute_fod depsBuild
recompute_fod depsProd

echo ">> hash recompute complete for airtrail v$ver"
