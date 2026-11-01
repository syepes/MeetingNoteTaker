#!/bin/bash
# Only used by the trusted tag build, on an ephemeral GitHub-hosted runner.
set -euo pipefail
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${MACOS_CERTIFICATE_BASE64:?}"
: "${MACOS_CERTIFICATE_PASSWORD:?}"
: "${MACOS_SIGNING_IDENTITY:?}"
: "${NOTARY_KEY_BASE64:?}"
: "${NOTARY_KEY_ID:?}"
: "${NOTARY_ISSUER_ID:?}"
if [[ "$MACOS_SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then
  echo 'MACOS_SIGNING_IDENTITY must be a Developer ID Application identity.' >&2
  exit 1
fi
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] &&
  [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF_TYPE:-}" = tag ] || {
  echo 'Signing import is restricted to tag pushes on GitHub-hosted runners.' >&2; exit 1;
}
umask 077
KEYCHAIN_PATH="$RUNNER_TEMP/meetingnotetaker-signing.keychain-db"
CERTIFICATE_PATH="$RUNNER_TEMP/meetingnotetaker-certificate.p12"
NOTARY_KEY_PATH="$RUNNER_TEMP/meetingnotetaker-notary.p8"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
trap 'rm -f "$CERTIFICATE_PATH" "$NOTARY_KEY_PATH"' EXIT
printf '%s' "$MACOS_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
printf '%s' "$NOTARY_KEY_BASE64" | base64 --decode > "$NOTARY_KEY_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$MACOS_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN_PATH" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
# This script only runs on disposable hosted runners, never on a developer Mac.
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
xcrun notarytool store-credentials meetingnotetaker-ci --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --keychain "$KEYCHAIN_PATH"
{
  printf 'SIGNING_IDENTITY=%s\n' "$MACOS_SIGNING_IDENTITY"
  printf 'NOTARY_PROFILE=meetingnotetaker-ci\n'
  printf 'NOTARY_KEYCHAIN=%s\n' "$KEYCHAIN_PATH"
} >> "$GITHUB_ENV"
