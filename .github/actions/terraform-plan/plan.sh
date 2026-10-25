#!/usr/bin/env bash
# Runs terraform plan, saves the plan to PLAN_FILE and its text to PLAN_TEXT,
# and writes the -detailed-exitcode result to the step outputs:
# 0 = no changes, 1 = error, 2 = changes.
set -uo pipefail

args=(plan -input=false -no-color -detailed-exitcode -out="$PLAN_FILE"
  -var-file="envs/${ENVIRONMENT}/terraform.tfvars"
  -var="region=${AWS_REGION_INPUT}"
  -var="environment=${ENVIRONMENT}")
if [[ "$DEPLOY" != "true" ]]; then
  args+=(-destroy)
fi
if [[ -n "${SECRET_TFVARS_FILE:-}" ]]; then
  args+=(-var-file="$SECRET_TFVARS_FILE")
fi

terraform "${args[@]}" 2>&1 | tee "$PLAN_TEXT"
code=${PIPESTATUS[0]}
echo "exitcode=$code" >>"$GITHUB_OUTPUT"
[[ $code -ne 1 ]]
