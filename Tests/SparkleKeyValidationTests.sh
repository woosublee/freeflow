#!/usr/bin/env bash
set -euo pipefail

PRIVATE_SEED="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
WRONG_PUBLIC_KEY="CnlcVsnQ8m/2VyZD7xL4ovP/ukAJtDJY19aVlfOSoOg="

printf '%s\n' "$PRIVATE_SEED" |
  xcrun swift scripts/validate-sparkle-key.swift "$PUBLIC_KEY"

if printf '%s\n' "$PRIVATE_SEED" |
  xcrun swift scripts/validate-sparkle-key.swift "$WRONG_PUBLIC_KEY" >/dev/null 2>&1; then
  echo "Expected mismatched Sparkle key validation to fail" >&2
  exit 1
fi

if printf '%s\n' "not-base64" |
  xcrun swift scripts/validate-sparkle-key.swift "$PUBLIC_KEY" >/dev/null 2>&1; then
  echo "Expected malformed Sparkle private key validation to fail" >&2
  exit 1
fi

temporary_dir="$(mktemp -d -t quill-sparkle-key-test)"
trap 'rm -rf "$temporary_dir"' EXIT
printf 'signed update fixture\n' > "$temporary_dir/Quill.dmg"
sign_update="$(find .build/artifacts -type f -name sign_update -perm +111 -print -quit)"
test -n "$sign_update"

RELEASE_TAG=v0.0.1 \
VERSION=0.0.1 \
BUILD_NUMBER=1 \
DMG_PATH="$temporary_dir/Quill.dmg" \
APPCAST_PATH="$temporary_dir/appcast.xml" \
SPARKLE_PRIVATE_KEY="$PRIVATE_SEED" \
SPARKLE_PUBLIC_KEY="$PUBLIC_KEY" \
SPARKLE_SIGN_UPDATE="$sign_update" \
  scripts/generate-sparkle-appcast.sh

grep -q 'sparkle:edSignature=' "$temporary_dir/appcast.xml"

printf 'SparkleKeyValidationTests passed\n'
