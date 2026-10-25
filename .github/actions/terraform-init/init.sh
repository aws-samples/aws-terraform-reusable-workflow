#!/usr/bin/env bash
# Configures HCP Terraform when an organization is set, then runs terraform init.
# Inputs come from environment variables so that no value is interpolated into
# the script.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

if [[ -n "${TF_ORGANIZATION_INPUT:-}" ]]; then
  host="${TF_HOSTNAME_INPUT:-app.terraform.io}"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || fail "tf-hostname must be a hostname, such as app.terraform.io."
  [[ "$TF_ORGANIZATION_INPUT" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "tf-organization contains characters that aren't allowed."
  [[ "${TF_WORKSPACE_INPUT:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "Set tf-workspace when tf-organization is set."
  [[ -n "${TF_TOKEN_INPUT:-}" ]] || fail "Set the tf-token secret when tf-organization is set."
  [[ "$TF_TOKEN_INPUT" != *$'\n'* ]] || fail "The tf-token secret must be a single line."

  # Terraform reads the API token from TF_TOKEN_<hostname>, with periods
  # written as underscores and hyphens as double underscores.
  token_var="TF_TOKEN_$(printf '%s' "$host" | sed -e 's/-/__/g' -e 's/\./_/g')"
  export TF_CLOUD_ORGANIZATION="$TF_ORGANIZATION_INPUT"
  export TF_CLOUD_HOSTNAME="$host"
  export TF_WORKSPACE="$TF_WORKSPACE_INPUT"
  export "$token_var=$TF_TOKEN_INPUT"
  {
    echo "TF_CLOUD_ORGANIZATION=$TF_CLOUD_ORGANIZATION"
    echo "TF_CLOUD_HOSTNAME=$TF_CLOUD_HOSTNAME"
    echo "TF_WORKSPACE=$TF_WORKSPACE"
    echo "$token_var=$TF_TOKEN_INPUT"
  } >>"$GITHUB_ENV"
fi

args=(init -input=false -no-color)
if [[ -f .terraform.lock.hcl ]]; then
  args+=(-lockfile=readonly)
else
  echo "::warning::No .terraform.lock.hcl file found. Commit the dependency lock file so that every run uses the same provider versions."
fi
terraform "${args[@]}"
