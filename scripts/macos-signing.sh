#!/bin/sh

# Sourced by the app and helper packagers. Print only the selected identity so
# callers can capture it without mixing diagnostics into codesign arguments.
hex_codesign_identity() {
  team_id=$1
  identity=${VOICE_CONTROL_CODESIGN_IDENTITY:-}
  if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application:.*($team_id)\)\"/\1/p" | head -1)
  fi
  if [ -z "$identity" ]; then
    echo "No Developer ID signing identity found for team $team_id. Set VOICE_CONTROL_CODESIGN_IDENTITY." >&2
    return 1
  fi
  case "$identity" in
    "Developer ID Application:"*"($team_id)") ;;
    *)
      echo "Signing identity is not a Developer ID Application identity for team $team_id." >&2
      return 1
      ;;
  esac
  printf '%s\n' "$identity"
}

# Submit one artifact and wait. A local notarytool keychain profile wins;
# otherwise CI authenticates with an App Store Connect API key file.
hex_notarize() {
  if [ -n "${HEX_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$HEX_NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" \
      --key "${HEX_NOTARY_KEY:?Set HEX_NOTARY_PROFILE, or HEX_NOTARY_KEY with HEX_NOTARY_KEY_ID and HEX_NOTARY_ISSUER}" \
      --key-id "${HEX_NOTARY_KEY_ID:?Set HEX_NOTARY_KEY_ID to the App Store Connect API key ID}" \
      --issuer "${HEX_NOTARY_ISSUER:?Set HEX_NOTARY_ISSUER to the App Store Connect issuer ID}" \
      --wait
  fi
}

hex_version() {
  printf '%s\n' "${HEX_VERSION:-$(cargo metadata --no-deps --format-version 1 --manifest-path "$1/Cargo.toml" | jq -r '.packages[0].version')}"
}

# CFBundleVersion from X.Y.Z; a staging prerelease (X.Y.Z-dev.N) shares its
# release's number, since Hex's updater compares SemVer, not build numbers.
hex_build_number() {
  printf '%s\n' "${HEX_BUILD_NUMBER:-$(printf '%s\n' "${1%%-*}" | awk -F. '{ print ($1 * 10000) + ($2 * 100) + $3 }')}"
}

# The locally installed app needs a certificate-backed identity across rebuilds.
# Multiple certificates for the same Developer ID are equivalent for its default
# designated requirement; choose a hash so duplicate names cannot confuse codesign.
hex_local_codesign_identity() {
    requested_team=${VOICE_CONTROL_TEAM_ID:-}
    requested_identity=${VOICE_CONTROL_CODESIGN_IDENTITY:-}
    matches=$(security find-identity -v -p codesigning | awk -F '"' \
        -v team="$requested_team" -v wanted="$requested_identity" '
        $2 ~ /^Developer ID Application: .*\([A-Z0-9]+\)$/ {
            split($1, fields, " "); hash = fields[2]; name = $2;
            if (team != "" && substr(name, length(name) - length(team)) != team ")") next;
            if (wanted != "" && wanted != hash && wanted != name) next;
            if (!(name in seen)) { seen[name] = 1; count++; selected = hash; }
        }
        END { if (count == 1) print selected; }')
    if [ -z "$matches" ]; then
        echo "Signing identity is not a Developer ID Application identity for team $requested_team, or selection is ambiguous. Set VOICE_CONTROL_TEAM_ID and optionally VOICE_CONTROL_CODESIGN_IDENTITY. Refusing ad-hoc signing for Hex.app." >&2
        return 1
    fi
    printf '%s\n' "$matches"
}
