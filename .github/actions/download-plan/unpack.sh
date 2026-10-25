#!/usr/bin/env bash
# Decrypts the saved plan bundle, puts the plan at PLAN_FILE and restores the
# dependency lock file that the plan was created with.
set -euo pipefail

if [[ -z "${PLAN_ENCRYPTION_KEY:-}" ]]; then
  echo "::error::Set the plan-encryption-key secret. It must match the key that encrypted the saved plan."
  exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/plan-bundle.XXXXXX")"
gpg --batch --yes --quiet --no-symkey-cache --pinentry-mode loopback \
  --passphrase-fd 3 --decrypt \
  --output "$work/bundle.tgz" "$BUNDLE_FILE" 3<<<"$PLAN_ENCRYPTION_KEY"
tar -xzf "$work/bundle.tgz" -C "$work"
mv "$work/tfplan" "$PLAN_FILE"
if [[ -f "$work/.terraform.lock.hcl" ]]; then
  mv "$work/.terraform.lock.hcl" .terraform.lock.hcl
fi
rm -f "$work/bundle.tgz"
rmdir "$work"
