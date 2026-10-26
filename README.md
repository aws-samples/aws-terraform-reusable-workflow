# Terraform Reusable Workflow

This repository provides a GitHub Actions reusable workflow that plans and applies Terraform configurations in one or more AWS accounts.

For each environment, the workflow:

1. **Plans.** On every pull request and push, it checks formatting, validates, optionally runs `terraform test`, and runs `terraform plan` with a read-only IAM role. On pull requests, it posts the plan as a comment.
2. **Saves the plan.** On the apply branch (`main` by default), it encrypts the saved plan and the dependency lock file, and uploads them as a workflow artifact that expires after one day.
3. **Applies the reviewed plan.** The apply job runs in a GitHub environment, so you can require an approval first. It assumes the apply IAM role and applies the saved plan. If the state changed after the plan was created, Terraform refuses the plan and nothing is applied.

It supports the Amazon S3 backend with GitHub OIDC (the default), and HCP Terraform or Terraform Enterprise in remote, agent, or local execution mode.

<!-- TOC -->

- [Terraform Reusable Workflow](#terraform-reusable-workflow)
  - [Requirements](#requirements)
  - [Option 1: S3 backend with GitHub OIDC](#option-1-s3-backend-with-github-oidc)
    - [AWS IAM](#aws-iam)
    - [GitHub repository](#github-repository)
    - [Deploy workflow](#deploy-workflow)
    - [Destroy workflow](#destroy-workflow)
  - [Option 2: HCP Terraform or Terraform Enterprise](#option-2-hcp-terraform-or-terraform-enterprise)
  - [Sensitive variables](#sensitive-variables)
  - [Private modules on GitHub](#private-modules-on-github)
  - [Inputs](#inputs)
  - [Secrets](#secrets)
  - [Security considerations](#security-considerations)
  - [Migrating from v1](#migrating-from-v1)
  - [Security](#security)
  - [License](#license)

<!-- /TOC -->

## Requirements

- Terraform 1.10 or later. Saved plans with the `cloud` block need 1.6, and ephemeral variables need 1.10.
- A root module in the repository root with:
  - `envs/<environment>/terraform.tfvars` for each environment. The file can be empty.
  - Optionally, `envs/<environment>/backend.tfbackend` for each environment. When it exists, `terraform init` reads it with `-backend-config`. See [Option 1](#option-1-s3-backend-with-github-oidc).
  - `region` and `environment` variables. The workflow sets them from the `aws-region` and `environment` inputs.
  - The dependency lock file (`.terraform.lock.hcl`) committed. When it's present, `terraform init` runs with `-lockfile=readonly`.
- A [GitHub environment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) for each environment, named like the `environment` input (for example, `dev`, `test`, `prod`). For production, add required reviewers and a deployment branch rule that allows only the apply branch.
- A `PLAN_ENCRYPTION_KEY` repository secret that holds a random passphrase:

  ```bash
  openssl rand -base64 32 | gh secret set PLAN_ENCRYPTION_KEY
  ```

- GitHub-hosted runners, or self-hosted runners at version 2.336.0 or later. The workflow loads its composite actions with the `$/` self-repository syntax, which isn't available on GitHub Enterprise Server.

## Option 1: S3 backend with GitHub OIDC

Each environment usually deploys to its own AWS account, so keep each environment's state in a bucket in that account. Declare a partial `s3` backend in the root module, with only the settings that every environment shares:

```hcl
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
```

Then add an `envs/<environment>/backend.tfbackend` file for each environment. The plan and apply jobs pass it to `terraform init` with `-backend-config`, so both jobs use the same state:

```hcl
bucket     = "amzn-s3-demo-bucket-dev"
key        = "my-app/terraform.tfstate"
region     = "us-east-1"
kms_key_id = "alias/terraform-state"
```

With `use_lockfile`, Terraform locks the state with a lock file in the bucket. If every environment shares one bucket, you can put the whole configuration in the `backend` block instead and leave out the `.tfbackend` files, but give each environment its own `key`. A configuration that sets `key` in the `backend` block shares one state across all environments.

For local runs, pass the same file: `terraform init -backend-config=envs/dev/backend.tfbackend`.

### AWS IAM

In each AWS account:

1. Create the [GitHub OIDC identity provider](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws) for `https://token.actions.githubusercontent.com` with the audience `sts.amazonaws.com`.
2. Create a **plan role**. Its permissions should be read-only for the resources, plus access to the state:
   - `s3:ListBucket` on the bucket, `s3:GetObject` on the state key, and `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on `<key>.tflock`. A plan takes the state lock.
   - `kms:Decrypt`, plus `kms:Encrypt` and `kms:GenerateDataKey` for the lock file, on the state key's KMS key.

   The plan job doesn't run in a GitHub environment, so its OIDC subject names the branch or the pull request. Trust both:

   ```json
   "Condition": {
     "StringEquals": {
       "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
       "token.actions.githubusercontent.com:sub": [
         "repo:my-org/my-repo:pull_request",
         "repo:my-org/my-repo:ref:refs/heads/main"
       ]
     }
   }
   ```

3. Create an **apply role** with the permissions to manage the resources and write the state. The apply job runs in the GitHub environment, so trust only that environment on the apply branch:

   ```json
   "Condition": {
     "StringEquals": {
       "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
       "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:environment:prod",
       "token.actions.githubusercontent.com:ref": "refs/heads/main"
     }
   }
   ```

Run IAM Access Analyzer [policy validation](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-policy-validation.html) on both trust policies.

### GitHub repository

- Repository variable `TF_VERSION`, for example `1.17.0`.
- Repository secrets `<ENV>_AWS_PLAN_ROLE_ARN` and `<ENV>_AWS_APPLY_ROLE_ARN` for each environment. Use repository secrets: a caller job can't pass environment secrets to a reusable workflow. The apply role's trust policy is what limits it to the protected environment.
- Repository secret `PLAN_ENCRYPTION_KEY`.

### Deploy workflow

Replace `<commit-sha>` with the full commit SHA of the release you use, and keep the version in the comment so that Dependabot can update both:

```yaml
name: Deploy

permissions:
  contents: read # Required for actions/checkout
  id-token: write # Required to request the GitHub OIDC token
  pull-requests: write # Required to comment on pull requests
  deployments: write # Required to deactivate deployments after a destroy

on:
  workflow_dispatch:
  pull_request:
    paths:
      - "**.tf*"
      - "envs/**"
      - ".terraform.lock.hcl"
      - ".github/workflows/deploy.yml"
  push:
    branches:
      - main
    paths:
      - "**.tf*"
      - "envs/**"
      - ".terraform.lock.hcl"
      - ".github/workflows/deploy.yml"

jobs:
  deploy-dev:
    name: Dev
    uses: aws-samples/aws-terraform-reusable-workflow/.github/workflows/terraform-reusable.yml@<commit-sha> # v2.0.0
    with:
      deploy: true
      tf-version: ${{ vars.TF_VERSION }}
      aws-region: us-east-1
      environment: dev
    secrets:
      terraform-execution-iam-plan-role-arn: ${{ secrets.DEV_AWS_PLAN_ROLE_ARN }}
      terraform-execution-iam-apply-role-arn: ${{ secrets.DEV_AWS_APPLY_ROLE_ARN }}
      plan-encryption-key: ${{ secrets.PLAN_ENCRYPTION_KEY }}

  deploy-prod:
    name: Prod
    needs: deploy-dev
    uses: aws-samples/aws-terraform-reusable-workflow/.github/workflows/terraform-reusable.yml@<commit-sha> # v2.0.0
    with:
      deploy: true
      tf-version: ${{ vars.TF_VERSION }}
      aws-region: us-east-2
      environment: prod
    secrets:
      terraform-execution-iam-plan-role-arn: ${{ secrets.PROD_AWS_PLAN_ROLE_ARN }}
      terraform-execution-iam-apply-role-arn: ${{ secrets.PROD_AWS_APPLY_ROLE_ARN }}
      plan-encryption-key: ${{ secrets.PLAN_ENCRYPTION_KEY }}
```

The caller must grant all four permissions. GitHub refuses to start a reusable workflow whose jobs request more permissions than the caller grants.

### Destroy workflow

Set `deploy: false` to plan and apply a destroy. Destroy in the reverse order of deployment:

```yaml
name: Destroy

permissions:
  contents: read
  id-token: write
  pull-requests: write
  deployments: write

on:
  workflow_dispatch:

jobs:
  destroy-prod:
    name: Prod
    uses: aws-samples/aws-terraform-reusable-workflow/.github/workflows/terraform-reusable.yml@<commit-sha> # v2.0.0
    with:
      deploy: false
      tf-version: ${{ vars.TF_VERSION }}
      aws-region: us-east-2
      environment: prod
    secrets:
      terraform-execution-iam-plan-role-arn: ${{ secrets.PROD_AWS_PLAN_ROLE_ARN }}
      terraform-execution-iam-apply-role-arn: ${{ secrets.PROD_AWS_APPLY_ROLE_ARN }}
      plan-encryption-key: ${{ secrets.PLAN_ENCRYPTION_KEY }}

  destroy-dev:
    name: Dev
    needs: destroy-prod
    uses: aws-samples/aws-terraform-reusable-workflow/.github/workflows/terraform-reusable.yml@<commit-sha> # v2.0.0
    with:
      deploy: false
      tf-version: ${{ vars.TF_VERSION }}
      aws-region: us-east-1
      environment: dev
    secrets:
      terraform-execution-iam-plan-role-arn: ${{ secrets.DEV_AWS_PLAN_ROLE_ARN }}
      terraform-execution-iam-apply-role-arn: ${{ secrets.DEV_AWS_APPLY_ROLE_ARN }}
      plan-encryption-key: ${{ secrets.PLAN_ENCRYPTION_KEY }}
```

After a successful destroy, the workflow marks the environment's GitHub deployments inactive.

## Option 2: HCP Terraform or Terraform Enterprise

Use a `cloud` block with no arguments in the root module. The workflow sets the organization, hostname, and workspace:

```hcl
terraform {
  cloud {}
}
```

1. Create a CLI-driven workspace for each environment.
2. Set the `tf-organization` and `tf-workspace` inputs, and `tf-hostname` for Terraform Enterprise. Pass a team API token that can run plans and applies in the workspaces as the `tf-token` secret.
3. Choose how runs execute:
   - **Remote or agent execution:** configure [dynamic provider credentials](https://developer.hashicorp.com/terraform/cloud-docs/dynamic-provider-credentials/aws-configuration) in each workspace (`TFC_AWS_PROVIDER_AUTH`, `TFC_AWS_PLAN_ROLE_ARN`, `TFC_AWS_APPLY_ROLE_ARN`). Don't pass the role ARN secrets. The plan job creates a saved cloud plan, and the apply job applies that run.
   - **Local execution:** HCP Terraform stores the state, and the runner signs in to AWS. Pass the role ARN secrets as in Option 1.

```yaml
    with:
      deploy: true
      tf-version: ${{ vars.TF_VERSION }}
      aws-region: us-east-1
      environment: dev
      tf-organization: ${{ vars.TF_ORGANIZATION }}
      tf-workspace: my-app-dev
    secrets:
      tf-token: ${{ secrets.TF_TOKEN }}
      plan-encryption-key: ${{ secrets.PLAN_ENCRYPTION_KEY }}
```

In remote execution mode, set sensitive values as sensitive workspace variables instead of using `secret-tfvars`.

## Sensitive variables

Store sensitive variable values as the contents of a `.tfvars` file in the `secret-tfvars` secret:

```hcl
db_password = "example-password"
```

The workflow writes the secret to a file outside the working directory, readable only by the runner user, and passes it with `-var-file` to the plan and the apply.

Declare these variables with `ephemeral = true` and use them only in write-only arguments (such as `password_wo`) or ephemeral contexts. Terraform then keeps them out of the saved plan and the state, and requires them again at apply, which the workflow handles. A variable that isn't ephemeral is stored in the saved plan and, wherever a resource uses it, in the state.

## Private modules on GitHub

Set `enable-github-modules: true` and pass a token that can read the module repositories as the `github-token` secret. The workflow configures Git to use the token for `https://github.com/` URLs. The workflow's `GITHUB_TOKEN` can read only the calling repository, so use a GitHub App installation token or a fine-grained personal access token with read-only `contents` access to the module repositories.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `deploy` | Yes | | `true` plans and applies the configuration. `false` plans and applies a destroy. |
| `tf-version` | Yes | | Terraform version |
| `aws-region` | Yes | | AWS Region, passed as `var.region` |
| `environment` | Yes | | GitHub environment, `envs/<environment>/terraform.tfvars` file, and `var.environment` |
| `apply-branch` | No | `main` | Branch whose pushes and manual runs apply the plan |
| `tf-organization` | No | | HCP Terraform or Terraform Enterprise organization |
| `tf-hostname` | No | `app.terraform.io` | HCP Terraform or Terraform Enterprise hostname |
| `tf-workspace` | No | | HCP Terraform or Terraform Enterprise workspace |
| `setup-python` | No | `false` | Install Python, for providers or modules that need it |
| `python-version` | No | `3.13` | Python version |
| `enable-github-modules` | No | `false` | Configure Git to download private modules with `github-token` |
| `pr-comment` | No | `true` | Post the plan as a pull request comment |
| `run-terraform-test` | No | `false` | Run `terraform test` with the plan role before the plan |
| `role-duration-seconds` | No | `3600` | Session duration for the assumed IAM roles |
| `ref` | No | | Deprecated and ignored |
| `local-execution-mode` | No | `false` | Deprecated and ignored |

## Secrets

| Name | Description |
|---|---|
| `terraform-execution-iam-plan-role-arn` | IAM role for the plan job |
| `terraform-execution-iam-apply-role-arn` | IAM role for the apply job |
| `plan-encryption-key` | Passphrase that encrypts the saved plan. Required when a run on the apply branch has changes. |
| `secret-tfvars` | Contents of a `.tfvars` file with sensitive variable values |
| `tf-token` | HCP Terraform or Terraform Enterprise API token |
| `github-token` | Token that can read private module repositories |
| `extra-args` | Removed. The workflow fails if it's set. |

## Security considerations

- **Pull request comments.** Terraform redacts values marked `sensitive`, but the comment shows every other value in the plan. In a public repository, anyone can read it. Set `pr-comment: false` if the plan shows values that shouldn't be public.
- **Saved plan artifact.** Anyone who can read the repository can download workflow artifacts. The workflow encrypts the saved plan with GnuPG (AES-256, with an integrity check) before uploading it, and the artifact expires after one day.
- **Pinned actions.** Every action is pinned to a full commit SHA. Pin this workflow the same way in your callers.
- **Least privilege.** Each job requests only the GitHub permissions it needs. The plan role has read-only access to resources, and the apply role's trust policy accepts only jobs that run in the protected environment on the apply branch.
- **No values in scripts.** Inputs and secrets reach the scripts as environment variables. The workflow never expands them inside the script text, which prevents script injection.

## Migrating from v1

- Replace `extra-args` with `secret-tfvars`. Convert each `-var="name=value"` to a `name = "value"` line.
- Add the `plan-encryption-key` secret.
- Remove the `ref` and `local-execution-mode` inputs. They're ignored.
- For HCP Terraform, `tf-organization`, `tf-hostname`, and `tf-workspace` are now optional, and `tf-hostname` also sets the token variable, so Terraform Enterprise works without editing the workflow.
- Formatting and validation failures now fail the plan job.
- The apply job applies the saved plan instead of planning again, and it no longer passes `-var-file` or `-var` options. Variable values come from the saved plan.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
