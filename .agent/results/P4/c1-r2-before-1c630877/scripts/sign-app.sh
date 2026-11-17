#!/bin/bash
# Sign a staged Jev Voice.app in place — extracted from the Makefile so
# both `app` (in-checkout sign) and `local` (sign the ~/jarvis-local copy)
# share one implementation. The synced Documents checkout stamps
# com.apple.provenance on every file; codesign counts it as detritus, so
# staging outside Documents (`make local`) is the reliable path.
set -euo pipefail

APP="$1"
IDENTITY_NAME="Jev Voice Local Dev"

xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

# A stable self-signed identity keeps macOS TCC grants (Accessibility,
# Screen Recording, Microphone, Camera) across rebuilds — adhoc signatures
# key on cdhash, so every rebuild invalidates permissions and re-prompts.
# We never fall back to `-`: the fix for a missing identity is minting it
# once, not silently signing into a TCC-reset trap.
find_identity() {
    security find-identity -v -p codesigning \
        | sed -n "s/.*\"\($IDENTITY_NAME\)\"/\1/p" | head -1
}

# Mint the identity once: an openssl-generated self-signed cert carrying
# the codeSigning EKU, imported into the login keychain with codesign on
# the item's ACL so builds don't trip a keychain-access prompt. The p12
# and its throwaway password live only inside this function's temp dir.
# The body runs in a subshell so the temp-dir cleanup is a plain EXIT trap
# that can't leak into the rest of the script.
mint_identity() (
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cat > "$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$work/key.pem" -out "$work/cert.pem" \
        -config "$work/openssl.cnf" >/dev/null 2>&1 || return 1
    local pass
    pass=$(openssl rand -hex 16)
    openssl pkcs12 -export -out "$work/id.p12" \
        -inkey "$work/key.pem" -in "$work/cert.pem" \
        -name "$IDENTITY_NAME" -passout "pass:$pass" >/dev/null 2>&1 || return 1
    security import "$work/id.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null || return 1
    [ -n "$(find_identity)" ]
)

IDENTITY=$(find_identity)
if [ -z "$IDENTITY" ]; then
    echo "sign-app: '$IDENTITY_NAME' not in the login keychain — minting it"
    mint_identity && IDENTITY=$(find_identity) || true
fi

if [ -z "$IDENTITY" ]; then
    cat >&2 <<EOF
sign-app: no "$IDENTITY_NAME" codesigning identity, and the scripted mint failed.
Refusing to adhoc-sign — an adhoc signature changes the cdhash every build,
so macOS would revoke every TCC grant (Accessibility, Microphone, Camera,
Screen Recording) on the next relaunch.

Create the identity once in Keychain Access:
  Keychain Access → Certificate Assistant → Create a Certificate…
    Name: $IDENTITY_NAME
    Identity Type: Self-Signed Root
    Certificate Type: Code Signing
then re-run this script.
EOF
    exit 1
fi
SIGN="$IDENTITY"
echo "sign-app: signing with '$SIGN'"

# Embedded runtimes carry foreign signatures (cua-driver's is bound to the
# CuaDriver.app Info.plist, which kills it on exec), and `codesign --deep`
# does not reach loose binaries under Resources — sign each nested Mach-O
# explicitly before sealing the app.
find "$APP/Contents/Resources" -type f | while read -r file; do
    case "$(file -b "$file")" in Mach-O*) codesign --force --sign "$SIGN" "$file" ;; esac
done

/usr/libexec/PlistBuddy -c "Delete :JevCuaDriverSHA256" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :JevCuaDriverSHA256 string $(shasum -a 256 "$APP/Contents/Resources/cua-driver" | cut -d' ' -f1)" "$APP/Contents/Info.plist"
codesign --force --deep --sign "$SIGN" "$APP"

# Verify what we produced. `codesign --verify --deep --strict` can fail
# spuriously inside a synced Documents checkout on com.apple.provenance
# detritus (AGENTS.md). Fail closed here too; use make local to stage and
# verify outside Documents instead of treating a failed seal as success.
if ! codesign --verify --deep --strict "$APP"; then
    cat >&2 <<EOF
sign-app: ERROR — codesign --verify --deep --strict failed for $APP.
Known caveat: inside a synced Documents checkout this trips on
com.apple.provenance detritus — verify on a copy outside Documents.
If the app already sits outside Documents, treat this as a real
signature failure and re-run scripts/sign-app.sh on a fresh stage.
EOF
    exit 1
fi
