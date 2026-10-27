#!/usr/bin/env bash
# Bundles the saved plan with the dependency lock file and encrypts the bundle
# with the plan-encryption-key secret. The saved plan can contain variable
# values, and workflow artifacts can be downloaded by anyone who can read the
# repository.
set -euo pipefail

if [[ -z "${PLAN_ENCRYPTION_KEY:-}" ]]; then
  echo "::error::Set the plan-encryption-key secret. The apply job needs the encrypted saved plan."
  exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/plan-bundle.XXXXXX")"
files=(tfplan)
cp "$PLAN_FILE" "$work/tfplan"
# A configuration that uses only built-in providers has no lock file.
if [[ -f .terraform.lock.hcl ]]; then
  cp .terraform.lock.hcl "$work/.terraform.lock.hcl"
  files+=(.terraform.lock.hcl)
fi
tar -czf "$work/bundle.tgz" -C "$work" "${files[@]}"
gpg --batch --yes --quiet --no-symkey-cache --pinentry-mode loopback \
  --passphrase-fd 3 --symmetric --cipher-algo AES256 \
  --output "$BUNDLE_FILE" "$work/bundle.tgz" 3<<<"$PLAN_ENCRYPTION_KEY"
rm -f "$work/bundle.tgz" "$work/tfplan" "$work/.terraform.lock.hcl"
rmdir "$work"
