#!/usr/bin/env bash
# Checks that pkgs/valheim-server/default.nix pins the latest Valheim
# dedicated server build and updates it if it does not.
#
#   1. Ask Steam for the latest manifest of the server depot.
#   2. Compare it with the manifestId in the package.
#   3. If they differ, download the depot, read the version off the freshly
#      built server and write both back into the package.
#
# Nothing is written when the package is already up to date. The package file
# is restored if any step fails, so a failed run never leaves a half-updated
# tree behind.
#
# Usage: scripts/update-valheim-server.sh

set -euo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
repo=$PWD

APP_ID=896660
DEPOT_ID=896661
BRANCH=public
PKG_FILE=pkgs/valheim-server/default.nix

# The depot hash is only known after downloading ~2 GiB from Steam. Writing a
# placeholder makes Nix report the real hash when the build fails.
PLACEHOLDER_HASH=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

# Only used to boot the server long enough to read its version.
PROBE_PORT=24600
PROBE_TIMEOUT=120

die() {
  echo "error: $*" >&2
  exit 1
}

# Prints the value of a string attribute of the package, e.g. `attr manifestId`.
attr() {
  sed -n "s/^[[:space:]]*$1 = \"\\([^\"]*\\)\";$/\\1/p" "$PKG_FILE" | head -n1
}

# Steam does not expose the manifest list over HTTP, so ask the Steam client.
latest_manifest() {
  nix shell --impure --expr '
    let
      flake = builtins.getFlake (toString ./.);
      nixpkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        config.allowUnfree = true;
      };
    in
    nixpkgs.steamcmd
  ' -c steamcmd +login anonymous "+app_info_print $APP_ID" +quit 2>/dev/null |
    LC_ALL=C awk -v depot_key="\"$DEPOT_ID\"" -v branch_key="\"$BRANCH\"" '
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      BEGIN { state = "depot"; depth = 0; bdepth = 0 }
      {
        t = trim($0)

        # Step over the depots before the one we are after.
        if (state == "depot") {
          if (t == depot_key) { state = "block"; depth = 0 }
          next
        }

        # Walk the depot block, looking for the branch we are after.
        if (state == "block") {
          if (t == "{") { depth++; next }
          if (t == "}") { if (depth == 0) state = "done"; else depth--; next }
          if (t == branch_key) { state = "branch"; bdepth = 0 }
          next
        }

        # Inside the branch block, the first gid is the manifest id.
        if (state == "branch") {
          if (t == "{") { bdepth++; next }
          if (t == "}") { if (bdepth == 0) state = "done"; else bdepth--; next }
          if (bdepth == 1 && t ~ /^"gid"/) {
            sub(/^"gid"[ \t]+/, "", t)
            gsub(/[ \t"]/, "", t)
            print t
            exit
          }
          next
        }
      }
    '
}

build() {
  NIXPKGS_ALLOW_UNFREE=1 nix build --impure -L "$@" .#valheim-server
}

# Downloads the depot and derives its hash from the mismatch Nix reports.
resolve_hash() {
  local output hash
  if output=$(build 2>&1); then
    return 0
  fi
  hash=$(LC_ALL=C sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\)$/\1/p' <<<"$output" | head -n1)
  [ -n "$hash" ] || {
    echo "$output" >&2
    die "could not determine the hash of depot $DEPOT_ID"
  }
  set_attr hash "$hash"
  build >/dev/null
}

# The version is only reported by the server itself, so boot it and read it
# off the log.
detect_version() {
  local tmp log line raw=""
  tmp=$(mktemp -d)
  log="$tmp/server.log"
  # Create it up front so that reading it below cannot race with the server.
  touch "$log"

  HOME="$tmp" setsid "$repo/result/bin/valheim-server" \
    -nographics -batchmode -name version-probe \
    -port "$PROBE_PORT" -password probe-password \
    -savedir "$tmp/saves" >"$log" 2>&1 &
  local pid=$!

  local waited=0
  while [ "$waited" -lt "$PROBE_TIMEOUT" ]; do
    # Parsed by hand: the log is written by a game server and is not guaranteed
    # to be valid text in the current locale.
    while IFS= read -r line; do
      case $line in
        *"Valheim version: "*)
          raw=${line#*Valheim version: }
          raw=${raw%% *}
          break
          ;;
      esac
    done <"$log"

    [ -n "$raw" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
    waited=$((waited + 2))
  done

  kill -- -"$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [ -z "$raw" ]; then
    tail -n 20 "$log" >&2
    die "the server did not report its version"
  fi
  rm -rf "$tmp"

  # Valheim prefixes the version with the branch it was built from, e.g. l-1.0.16.
  echo "${raw#[a-z]-}"
}

set_attr() {
  # `|` as the delimiter, hashes contain `/`.
  sed -i "s|^\\([[:space:]]*$1 = \\)\"[^\"]*\";|\\1\"$2\";|" "$PKG_FILE"
}

backup=$(mktemp)
cp "$PKG_FILE" "$backup"
cleanup() {
  if [ "$?" -ne 0 ]; then
    cp "$backup" "$PKG_FILE"
    echo "restored $PKG_FILE" >&2
  fi
  rm -f "$backup"
}
trap cleanup EXIT

current_manifest=$(attr manifestId)
current_version=$(attr version)
[ -n "$current_manifest" ] && [ -n "$current_version" ] ||
  die "could not read manifestId and version from $PKG_FILE"

echo "valheim-server $current_version (manifest $current_manifest)"

echo "querying Steam for the latest $BRANCH build of depot $DEPOT_ID ..."
latest=$(latest_manifest)
[ -n "$latest" ] || die "Steam did not report a $BRANCH manifest for depot $DEPOT_ID"
echo "latest manifest is $latest"

if [ "$latest" = "$current_manifest" ]; then
  echo "up to date, nothing to do"
  exit 0
fi

set_attr manifestId "$latest"
set_attr hash "$PLACEHOLDER_HASH"
echo "downloading the depot, this takes a while ..."
resolve_hash
version=$(detect_version)

set_attr version "$version"
echo "updated $PKG_FILE: $current_version -> $version (manifest $latest)"
# Not part of the update, so it must not be able to undo it.
git --no-pager diff -- "$PKG_FILE" || true
