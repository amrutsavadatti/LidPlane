#!/bin/bash
# One-time developer setup.
#
# An ad-hoc signature makes the designated requirement the binary's own cdhash,
# so every rebuild looks like a different app to TCC and the Screen Recording
# grant stops matching — which is why the permission prompt kept reappearing on
# every lid movement. Signing with a stable certificate fixes it permanently.
# A self-signed one is enough; no Apple Developer Program involved.
#
# This is for building locally. Anyone installing a released, notarized build
# never needs any of it.
#
# Creating the certificate is the one step that cannot be scripted. Generating
# it with openssl and importing it leaves the private key without a codesign
# ACL, so codesign blocks on a keychain authorization dialog that no script can
# answer. Certificate Assistant creates the key in place, so a single
# "Always Allow" on the first build is all it takes.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY_NAME="${1:-LidPlane Dev}"
IDENTITY_FILE=".signing-identity"
BUNDLE_ID="local.amrut.LidPlane"

# Deliberately not `find-identity -v`. The -v flag lists only identities with a
# trusted chain, and a self-signed root is never trusted — but codesign signs
# with it perfectly well. Using -v here would loop forever telling the user to
# create a certificate they already have.
have_identity() {
    security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"
}

printf '== LidPlane developer setup ==\n\n'

while ! have_identity; do
    cat <<EOF
No valid code-signing identity named "$IDENTITY_NAME" was found.

Create one in Keychain Access — it takes about twenty seconds:

  1. Menu: Keychain Access > Certificate Assistant > Create a Certificate…
  2. Name:            $IDENTITY_NAME
     Identity Type:   Self Signed Root
     Certificate Type: Code Signing
  3. Click Create, then Done.

EOF
    open -a "Keychain Access" 2>/dev/null || true
    read -r -p 'Press Return once the certificate exists (or Ctrl-C to stop)… ' _
    printf '\n'
    if ! have_identity; then
        printf 'Still not visible as a valid signing identity.\n'
        read -r -p 'Try again? [y/N] ' answer
        case "$answer" in [yY]*) continue ;; *) exit 1 ;; esac
    fi
done

printf 'Using signing identity: %s\n' "$IDENTITY_NAME"
printf '%s\n' "$IDENTITY_NAME" > "$IDENTITY_FILE"
printf 'Recorded in %s — build.sh picks it up automatically.\n\n' "$IDENTITY_FILE"

printf 'Rebuilding with the stable identity…\n'
printf 'If macOS asks permission to use the signing key, choose "Always Allow"\n'
printf 'so later builds are silent.\n\n'
bash build.sh >/dev/null

REQUIREMENT="$(codesign -d --requirements - build/LidPlane.app 2>&1 | grep designated || true)"
printf 'Designated requirement is now:\n  %s\n\n' "${REQUIREMENT#*designated => }"

if printf '%s' "$REQUIREMENT" | grep -q cdhash; then
    printf 'Still keyed to the binary hash, so the grant will not survive rebuilds.\n'
    printf 'The signature did not take. Check that the certificate is trusted for\n'
    printf 'code signing in Keychain Access.\n'
    exit 1
fi

printf 'Stable across rebuilds.\n\n'
printf 'Clearing the stale Screen Recording grant so you approve this signature once…\n'
killall LidPlane 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true

cat <<EOF

Done. Now:

  open build/LidPlane.app

Click the menu-bar icon, switch the effect on, and approve the prompt. From
here the grant survives every rebuild.
EOF
