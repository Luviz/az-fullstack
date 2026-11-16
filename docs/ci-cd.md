# CI/CD: GitHub Actions and the managed identity

GitHub Actions deploys the backend (Azure Functions) and the frontend (Static Web App) by logging in to Azure as a dedicated user-assigned managed identity, `id-cicd-azfullstack-dev-6j8oq`. The login uses OpenID Connect (OIDC), so no Azure credentials are stored in GitHub. Terraform creates the identity and its permissions; Terraform itself is **not** run by GitHub Actions and is applied manually from a workstation.

## Overview

```
GitHub Actions job (environment: production)
  │  1. requests an OIDC token from GitHub
  ▼
Microsoft Entra ID
  │  2. checks the token against the identity's federated credential
  │     (issuer + subject + audience must match exactly)
  ▼
id-cicd-azfullstack-dev-6j8oq  ──  3. short-lived Azure token
  │
  ├─ Website Contributor ──────────────► func-azfullstack-dev-6j8oq  (backend deploy)
  └─ SWA Deployment Token Reader ──────► stapp-azfullstack-dev-6j8oq (reads deploy token)
```

## Workflows

| Workflow | File | Runs when | Deploys? |
|---|---|---|---|
| Backend | `.github/workflows/backend.yml` | Changes under `backend/**` (push or PR to `main`), or manual | On push to `main` only |
| Frontend | `.github/workflows/frontend.yml` | Changes under `frontend/**` (push or PR to `main`), or manual | On push to `main` only |
| Terraform | `.github/workflows/terraform.yml` | Manual only (`workflow_dispatch`) | Never: runs `fmt -check` and `validate` only, without Azure access |

Each workflow also runs when its own `.yml` file changes. Build and lint jobs run on PRs without Azure access. Only the `deploy` jobs log in to Azure, and they run in the GitHub environment `production`.

### Backend deploy steps

1. Download the zipped package from the build job (production dependencies only).
2. `azure/login@v2`: OIDC login as the CI/CD identity.
3. **Open the deploy endpoint:** add an access restriction on the Function App's deploy endpoint (Kudu, the `scm` site) that allows this runner's public IP only. The rule is named `gh-run-<run_id>`. The step waits until the endpoint stops returning `403`.
4. `Azure/functions-action@v1` with `sku: flexconsumption` deploys `backend.zip` through Kudu `/api/publish`.
5. **Close the deploy endpoint:** remove the rule again. This step runs even if the deploy fails (`if: always()`).

### Frontend deploy steps

1. Download the built `dist` folder from the build job.
2. `azure/login@v2`: OIDC login as the CI/CD identity.
3. `az staticwebapp secrets list` fetches the Static Web App deployment token at runtime and masks it in the logs.
4. `Azure/static-web-apps-deploy@v1` uploads `dist`, using that token.

The SWA deploy action only accepts a deployment token, not an Azure login. Fetching the token with the managed identity means the token is never stored in GitHub.

## The managed identity

Defined in `terraform/main.tf` as `module "cicd_identity"`. It's used **only** for CI/CD and is separate from the Function App's runtime identity (`id-func-…`).

| Property | Value |
|---|---|
| Name | `id-cicd-azfullstack-dev-6j8oq` |
| Resource group | `rg-azfullstack-dev` |
| Client ID | `b80cd80f-e2a4-4cf5-bac0-015c29a51808` (`terraform output -raw cicd_client_id`) |

### Federated credential (who may log in)

| Field | Value |
|---|---|
| Name | `github-production` |
| Issuer | `https://token.actions.githubusercontent.com` |
| Audience | `api://AzureADTokenExchange` |
| Subject | `repo:Luviz@4950894/az-fullstack@1460072766:environment:production` |

Only jobs in the `production` environment of this repository can log in. PR jobs, jobs without that environment, and other repositories are rejected.

**Why the subject has numbers in it:** the repo has GitHub's *immutable subject* setting turned on (`use_immutable_subject: true`). GitHub then adds the owner ID (`4950894`) and the repo ID (`1460072766`) to the names. If the repo is renamed, or someone recreates a repo with the same name, the IDs no longer match and the login is refused. To check the prefix GitHub uses:

```sh
gh api repos/Luviz/az-fullstack/actions/oidc/customization/sub --jq .sub_claim_prefix
```

The prefix is set with the Terraform variable `github_oidc_subject_prefix`, and the environment name with `github_environment` (default `production`).

### Permissions (least privilege)

| Role | Scope | Why |
|---|---|---|
| Website Contributor (built-in) | `func-azfullstack-dev-6j8oq` only | Deploy code, and add or remove the temporary IP rule on the deploy endpoint |
| SWA Deployment Token Reader (custom, defined in Terraform) | `stapp-azfullstack-dev-6j8oq` only | `Microsoft.Web/staticSites/read` and `Microsoft.Web/staticSites/listSecrets/action`, needed to fetch the deploy token |

The identity has no access at resource group or subscription level, and no access to storage, App Insights or anything else.

**Known gap:** Website Contributor allows more than deploying inside the Function App (for example changing app settings, restarting or deleting the app). A custom role limited to the exact deploy and access-restriction actions would be tighter. It needs testing against a real Flex Consumption deploy before it replaces the built-in role.

## Network access on the Function App

Set in `terraform/main.tf` on `module "func"`:

| Setting | Value | Effect |
|---|---|---|
| `public_network_access_enabled` | `true` | The app is publicly reachable, which the Static Web App's linked `/api` backend needs |
| `site_config.scm_ip_restriction_default_action` | `Deny` | The deploy endpoint (Kudu/`scm`) blocks every IP by default |
| `site_config.scm_use_main_ip_restriction` | `false` | The deploy endpoint has its own rules, separate from the app's |

The AVM web-site module defaults `public_network_access_enabled` to `false`. While it was `false`, deploys failed with `Ip Forbidden (403)`.

GitHub-hosted runners have no fixed IP, so the backend job temporarily allows its own IP, as described under "Backend deploy steps".

## GitHub configuration

All values are **variables** on the `production` environment, not secrets. None of them are credentials. Only the deploy jobs can read them, because only those jobs run in `production`.

| Variable | Value | Source |
|---|---|---|
| `AZURE_CLIENT_ID` | `b80cd80f-e2a4-4cf5-bac0-015c29a51808` | `terraform output -raw cicd_client_id` |
| `AZURE_TENANT_ID` | `8a704dd9-896d-4f97-bca1-1b8720c76951` | `terraform.tfvars` |
| `AZURE_SUBSCRIPTION_ID` | `37c9effe-ba3f-4b42-aaa7-afdcfeafa9b2` | `terraform.tfvars` |
| `AZURE_RESOURCE_GROUP` | `rg-azfullstack-dev` | `terraform output -raw resource_group_name` |
| `AZURE_FUNCTIONAPP_NAME` | `func-azfullstack-dev-6j8oq` | `terraform output -raw function_app_name` |
| `AZURE_STATIC_WEB_APP_NAME` | `stapp-azfullstack-dev-6j8oq` | `terraform output -raw static_web_app_name` |

There are no secrets. To set or update a variable:

```sh
gh variable set AZURE_CLIENT_ID --env production --body "$(terraform -chdir=terraform output -raw cicd_client_id)"
gh variable list --env production
```

## Terraform

Terraform runs manually from a workstation with local state; GitHub Actions never applies it.

```sh
cd terraform
terraform plan -out=tfplan
terraform apply tfplan
```

Every plan also shows in-place updates to `telemetry` resources. These come from the Azure Verified Modules and don't change real infrastructure.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `AADSTS700213: No matching federated identity record found for presented assertion subject '…'` | The subject GitHub sent doesn't match the federated credential | Compare the subject in the error with `github_oidc_subject_prefix` and `github_environment`, update, and run `terraform apply`. Also check that the job has `environment: production` |
| `Ip Forbidden (CODE: 403)` during the Function App deploy | The deploy endpoint blocks the runner's IP | Check that public network access is enabled and that the "Allow runner IP" step succeeded. Leftover `gh-run-*` rules can be deleted safely |
| `AuthorizationFailed` on `az staticwebapp secrets list` | The identity lacks the custom SWA role | Run `terraform apply` and check the `swa_deploy` role assignment |
| Login fails with a missing `id-token` permission | The job lacks `permissions: id-token: write` | Add it to the deploy job |

Check what's live in Azure:

```sh
az identity federated-credential list -g rg-azfullstack-dev --identity-name id-cicd-azfullstack-dev-6j8oq -o table
az role assignment list --all --query "[?principalId=='$(az identity show -g rg-azfullstack-dev -n id-cicd-azfullstack-dev-6j8oq --query principalId -o tsv)'].{role:roleDefinitionName,scope:scope}" -o table
az functionapp config access-restriction show -g rg-azfullstack-dev -n func-azfullstack-dev-6j8oq
```
