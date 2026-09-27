# AirTrail — self-hosted personal flight tracker (johanohly/AirTrail).
#
# Derivation for the AirTrail SvelteKit application. Notable facts that make
# this simpler than a typical Node-on-Nix package:
#   * The generated Kysely schema (src/lib/db/*) is committed upstream, so
#     Prisma is NOT needed at build time — no `prisma generate`, no engines.
#   * DB migrations are plain .sql applied by a hand-rolled `pg`-based runner
#     (docker/migrate.js) — no Prisma at runtime either.
#   * The only runtime native module, @node-rs/argon2, ships a prebuilt arm64
#     .node that loads under nixpkgs Node with no patchelf (Node already
#     provides glibc/libgcc in-process).
#
# node_modules are materialised by two fixed-output derivations that run
# `bun install` (network is allowed in FODs). To refresh a hash after bumping
# the version or bun.lock: set it to lib.fakeHash, build, copy the "got:" hash.
#
# Those hashes are PER-SYSTEM. `bun install` resolves the optional deps that
# match the host (lightningcss-linux-{arm64,x64}-gnu, @rollup/rollup-linux-*,
# @swc/core-linux-*, …), so the recursive hash of the tree differs between
# aarch64 and x86_64. A hash recomputed on one arch can never validate on the
# other — hence `depsHashes` below, one entry per supported system, and the
# .github/workflows/renovate-hashes-arm.yml leg that fills the aarch64 slot on a
# native arm64 runner after Renovate's x86_64 run has filled its own.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  nodejs_22,
  makeWrapper,
  cacert,
  # Optional: a path/derivation containing `airport-overlay.pmtiles`. When set,
  # the file is copied into build/client so the map airport overlay renders.
  # Upstream bakes this from the johly/airtrail-airport-overlay image (~178 MB);
  # left null the app works fine, the overlay layer is simply absent.
  airportOverlay ? null,
}:

let
  pname = "airtrail";
  version = "3.13.0";

  src = fetchFromGitHub {
    owner = "johanohly";
    repo = "AirTrail";
    rev = "v${version}";
    hash = "sha256-PfJ775FqZ8Kkrb8ajl6LDdCBwg25uffYaaT7Hv/Ltbw=";
  };

  # Shared env for the two bun-install FODs. Skip browser/binary downloads that
  # some devDeps (playwright, puppeteer) trigger — they are irrelevant to a
  # production build and would add non-determinism and hundreds of MB.
  bunInstallEnv = ''
    export HOME=$TMPDIR
    export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    export PUPPETEER_SKIP_DOWNLOAD=1
    export CI=1
  '';

  # One entry per system in meta.platforms. Keys match the FOD attribute names
  # so ci/renovate-update.sh can target `<system>.<attr>` unambiguously.
  depsHashes = {
    aarch64-linux = {
      depsBuild = "sha256-WpYTcWvMmi9nDqYIglsq3+2F8rOsracJv1BygeUk4kI=";
      depsProd = "sha256-XR0TF3SjDKznIY5efa0swVqunwUPqWyiegjN0+71qM4=";
    };
    x86_64-linux = {
      depsBuild = "sha256-RzzTtdYEKfsGIRPtP3TAoV/xX0am2fT6gStYfbGeh4Q=";
      depsProd = "sha256-LQBOyhrXVcgPszKROljDUJzzRihJAH5NHTZAlJkRaSM=";
    };
  };

  inherit (stdenv.hostPlatform) system;

  hashes = depsHashes.${system} or (throw
    "airtrail: no bun dependency hashes recorded for ${system}. "
    + "Run `bash ci/renovate-update.sh` on that platform and commit the result.");

  mkBunModules = { name, args, outputHash }:
    stdenvNoCC.mkDerivation {
      inherit src;
      name = "${pname}-${name}-${version}";
      nativeBuildInputs = [ bun ];
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${bunInstallEnv}
        bun install ${args} --frozen-lockfile --no-progress
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        # Drop caches / non-reproducible bits before hashing the tree.
        rm -rf node_modules/.cache
        mkdir -p $out
        cp -R node_modules $out/node_modules
        runHook postInstall
      '';
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      inherit outputHash;
    };

  # Full dependency tree (dev + prod) used to run `vite build`.
  depsBuild = mkBunModules {
    name = "deps-build";
    args = "";
    outputHash = hashes.depsBuild;
  };

  # Production-only tree shipped at runtime (pg, geo-tz, memoize, @node-rs/argon2
  # and their transitive deps). adapter-node keeps `dependencies` external, and
  # docker/{migrate,admin}.js require `pg` + argon2 at runtime.
  depsProd = mkBunModules {
    name = "deps-prod";
    args = "--production";
    outputHash = hashes.depsProd;
  };

in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [ bun nodejs_22 makeWrapper ];

  configurePhase = ''
    runHook preConfigure
    export HOME=$TMPDIR
    cp -R ${depsBuild}/node_modules ./node_modules
    chmod -R u+w node_modules
    # node_modules/.bin scripts ship a `#!/usr/bin/env node` shebang; /usr/bin/env
    # does not exist in the pure build sandbox (it does on the live system, which
    # is why a manual `bun run build` worked). Rewrite shebangs to the store node.
    patchShebangs node_modules
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    export NODE_ENV=production
    # Vite/Rollup are memory-hungry; cap heap so constrained builders (rpi5)
    # lean on swap rather than being OOM-killed mid-build.
    export NODE_OPTIONS=--max-old-space-size=3072
    bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    appDir=$out/share/airtrail
    mkdir -p $appDir

    # adapter-node output + everything the runtime/migrator need.
    cp -R build $appDir/build
    cp -R prisma $appDir/prisma          # migrations/*/migration.sql
    cp -R docker $appDir/docker          # migrate.js, admin.js, healthcheck.js
    cp package.json $appDir/package.json
    cp -R ${depsProd}/node_modules $appDir/node_modules
  '' + lib.optionalString (airportOverlay != null) ''
    cp ${airportOverlay}/airport-overlay.pmtiles $appDir/build/client/airport-overlay.pmtiles
  '' + ''

    mkdir -p $out/bin

    # Main server (adapter-node entry). WorkingDirectory/uploads are set by the
    # NixOS module at runtime; the store app dir stays read-only.
    makeWrapper ${nodejs_22}/bin/node $out/bin/airtrail \
      --add-flags "$appDir/build/index.js" \
      --set NODE_ENV production \
      --chdir "$appDir"

    # Idempotent SQL migration runner (replaces `prisma migrate deploy`).
    makeWrapper ${nodejs_22}/bin/node $out/bin/airtrail-migrate \
      --add-flags "$appDir/docker/migrate.js" \
      --chdir "$appDir"

    # Admin CLI: list-users / reset-password / grant-admin / revoke-admin.
    makeWrapper ${nodejs_22}/bin/node $out/bin/airtrail-admin \
      --add-flags "$appDir/docker/admin.js" \
      --chdir "$appDir"

    runHook postInstall
  '';

  # No ELF to fix up in the app tree; argon2's prebuilt .node loads as-is.
  dontStrip = true;

  # Expose the two bun-install FODs so CI (ci/renovate-update.sh) can build each
  # in isolation to recompute its outputHash after a version/bun.lock bump.
  passthru = { inherit depsBuild depsProd; };

  meta = with lib; {
    description = "AirTrail — self-hosted personal flight tracker (johanohly/AirTrail)";
    homepage = "https://github.com/johanohly/AirTrail";
    license = licenses.gpl3Only;
    platforms = [ "aarch64-linux" "x86_64-linux" ];
    mainProgram = "airtrail";
    maintainers = [ ];
  };
}
