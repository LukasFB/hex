#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export VOICE_CONTROL_TEAM_ID=TESTTEAM00
temporary=$(mktemp -d "${TMPDIR:-/tmp}/hex-app-identity.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
bundle="$temporary/Hex.app"
mkdir -p "$bundle/Contents"
plist="$bundle/Contents/Info.plist"
cp "$root/app/Info.plist" "$plist"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = anomaly.hex ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = hex ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" = Hex ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" = Hex ]

expect_rejection() {
  if output=$(sh "$root/scripts/validate-app.sh" "$bundle" Hex.app 2.1.0 20100 2>&1); then
    echo "Unexpectedly accepted an incompatible app." >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -Fq "$1"
}

/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kitlangton.Hex' "$plist"
expect_rejection 'wrong bundle identifier'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kitlangton.voice-control.agent' "$plist"
expect_rejection 'wrong bundle identifier'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ly.anoma.Hex' "$plist"
expect_rejection 'wrong bundle identifier'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.kitlangton.hex2' "$plist"
expect_rejection 'wrong bundle identifier'
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier anomaly.hex' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable voice-control-watch' "$plist"
expect_rejection 'wrong executable name'

# Local apps require a certificate-backed identity; distributed helpers and
# releases additionally require an explicit Developer ID team.
for script in build-service-app.sh release-app.sh; do
  if output=$(env -u VOICE_CONTROL_TEAM_ID sh "$root/scripts/$script" 2>&1); then
    echo "Unexpectedly allowed $script without an explicit signing team." >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -Fq 'Set VOICE_CONTROL_TEAM_ID to the Apple Developer signing team'
done

for script in build-app.sh build-service-app.sh; do
  for identity in 'Developer ID Application: Fixture (WRONGTEAM0)' 'Apple Development: Fixture (TESTTEAM00)'; do
    if output=$(VOICE_CONTROL_CODESIGN_IDENTITY="$identity" sh "$root/scripts/$script" 2>&1); then
      echo "Unexpectedly allowed an incompatible signing identity in $script." >&2
      exit 1
    fi
    printf '%s\n' "$output" | grep -Fq 'Signing identity is not a Developer ID Application identity for team TESTTEAM00'
  done
done

if output=$(env -u HEX_NOTARY_PROFILE sh "$root/scripts/prepare-service-app.sh" 2>&1); then
  echo "Unexpectedly allowed helper notarization without an explicit profile." >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq 'Set HEX_NOTARY_PROFILE to the matching notarization profile'

# Exercise local identity selection without signing anything or using the keychain.
mkdir -p "$temporary/bin"
cat > "$temporary/bin/security" <<'MOCK'
#!/bin/sh
cat "$HEX_SIGNING_FIXTURE"
MOCK
chmod +x "$temporary/bin/security"
(
  PATH="$temporary/bin:$PATH"
  export PATH HEX_SIGNING_FIXTURE="$temporary/identities"
  unset VOICE_CONTROL_TEAM_ID VOICE_CONTROL_CODESIGN_IDENTITY
  . "$root/scripts/macos-signing.sh"
  printf '%s\n' ' 1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TESTTEAM00)"' \
    ' 2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Fixture (TESTTEAM00)"' > "$HEX_SIGNING_FIXTURE"
  [ "$(hex_local_codesign_identity)" = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]
  [ "$(VOICE_CONTROL_CODESIGN_IDENTITY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB hex_local_codesign_identity)" = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB ]
  printf '%s\n' ' 3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Other (OTHERTEAM0)"' >> "$HEX_SIGNING_FIXTURE"
  if hex_local_codesign_identity >/dev/null 2>&1; then
    echo "Ambiguous local identity unexpectedly accepted" >&2; exit 1
  fi
  [ "$(VOICE_CONTROL_TEAM_ID=TESTTEAM00 hex_local_codesign_identity)" = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]
  : > "$HEX_SIGNING_FIXTURE"
  if hex_local_codesign_identity >/dev/null 2>&1; then
    echo "Missing local identity unexpectedly accepted" >&2; exit 1
  fi
)
echo "Rust app identity guards passed."
