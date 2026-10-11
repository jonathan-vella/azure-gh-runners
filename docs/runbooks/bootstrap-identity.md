# Runbook: bootstrap platform OIDC identities

This runbook creates (first-time adopters) and then verifies the Azure identities the platform needs: the resource
group, a deploy identity trusted only by the protected `platform-prod` GitHub environment, an optional read-only
what-if identity, and the constrained RBAC delegation. Run it once per deployment, before the first run of
`deploy.yml`. See [adopting.md](../adopting.md) for the surrounding order of steps.

> **Placeholders.** Every `<placeholder>` and every value in the example block below is **illustrative**. Replace
> them with your own. The maintainer's live identifiers appear only in evidence and history documents
> (`docs/adr/*`, `docs/research-*`, `docs/smoke.md`); never copy them into your deployment.

This is not a disaster-recovery provisioning script. An unexpected trust or role grant is a blocker: stop and
investigate before changing anything. Do not deploy the platform here; deployment belongs to the gated
`platform-prod` workflow.

## Target state

| Item | Value |
| --- | --- |
| Subscription / tenant | `<subscription-id>` / `<tenant-id>` |
| Resource group / region | `<resource-group>` / `<region>` (default `rg-ghrunners-prod-swc` / `swedencentral`) |
| Deploy app | `sp-ghrunners-platform-prod` (the name is yours to choose; keep it distinct from the what-if app) |
| Deploy federated credential | one only: `repo:<owner>/<repo>:environment:platform-prod` (see the subject note below) |
| What-if app (optional) | `sp-ghrunners-whatif`, one federated credential for `pull_request`, Reader on the RG only |
| Credential issuer / audience | `https://token.actions.githubusercontent.com` / only `api://AzureADTokenExchange` |
| Deploy RBAC, RG scope only | Contributor, and Role Based Access Control Administrator constrained to AcrPull, AcrPush, Key Vault Secrets User |

Neither app has a password or certificate credential. **Never combine the two federated credentials on one app**:
RBAC belongs to the service principal, not to a credential, so a pull request could otherwise inherit deployment
privileges. The what-if job must not reference a GitHub environment, and the Reader app must never be given
deployment rights. No what-if workflow ships in this repository today; skip the what-if identity unless you add one.

### Federated-credential subject

GitHub can issue OIDC subjects that include immutable owner and repository IDs (for example
`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:platform-prod`). Read the repository's current setting before
creating the credential:

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```

Use the `sub_claim_prefix` it reports when present, otherwise `repo:<owner>/<repo>`. The deploy credential must
match the exact claim a `platform-prod` job presents, so confirm it against a real run rather than inferring it. See
GitHub's [OIDC reference](https://docs.github.com/actions/reference/security/oidc).

## Variables

Set these once per PowerShell 7 session. Everything after this block uses them.

```powershell
$ErrorActionPreference = 'Stop'
$azureCliPython = (Resolve-Path (Join-Path (Split-Path (Get-Command az).Source) '..\python.exe')).Path
function Invoke-Az {
    $output = & $azureCliPython -IBm azure.cli @args
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI command failed; stop bootstrap.' }
    $output
}
function Invoke-Gh {
    $output = & gh @args
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI command failed; stop bootstrap.' }
    $output
}

# --- Replace every value in this block ---
$repo          = '<owner>/<repo>'        # your fork, for example 'contoso-ci/azure-gh-runners'
$subscription  = '<subscription-id>'     # GUID of the target subscription
$tenant        = '<tenant-id>'           # GUID of the Entra tenant
$location      = '<region>'              # must match infra/network-config.json (default swedencentral)
$rg            = '<resource-group>'      # must match infra/network-config.json (default rg-ghrunners-prod-swc)
$subjectPrefix = 'repo:<owner>/<repo>'   # or the immutable prefix reported by the GitHub API
$deployAppName = 'sp-ghrunners-platform-prod'
$readerAppName = 'sp-ghrunners-whatif'   # optional
# --- End of block ---
```

Example block, shown only to illustrate the shape (these are not real):

```powershell
# $repo = 'contoso-ci/azure-gh-runners'
# $subscription = '00000000-0000-4000-8000-000000000001'
# $tenant = '00000000-0000-4000-8000-000000000002'
# $rg = 'rg-ghrunners-prod-swc'
# $subjectPrefix = 'repo:contoso-ci/azure-gh-runners'
```

Use an already-authenticated Azure CLI session in the target tenant with authority to create Entra applications and
assign roles on the resource group, and an authenticated `gh` session with repository environment, secret, and
variable administration rights. Do not create client secrets, export tokens, enable command tracing or transcripts,
or read or log `GH_APP_PRIVATE_KEY`. The commands call the Windows MSI Azure CLI's bundled Python directly to
preserve JSON and condition quoting that `az.cmd` can corrupt.

## 1. Create (first-time adopters only)

Skip this section if the resources already exist and continue with section 2.

```powershell
Invoke-Az account set --subscription $subscription
$tags = @{
    application = 'ghrunners'; environment = 'prod'; workload = 'gh-runners'
    owner = '<owner>'; costcenter = '<cost-center>'
    'tech-contact' = '<contact>'; 'technical-contact' = '<contact>'
    sla = 'development'; 'backup-policy' = 'none'; 'maint-window' = 'none'
}
$tagArgs = $tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
Invoke-Az group create --name $rg --location $location --tags @tagArgs -o none

# Deploy identity: one app, one service principal, one federated credential.
$deployApp = Invoke-Az ad app create --display-name $deployAppName -o json | ConvertFrom-Json
Invoke-Az ad sp create --id $deployApp.appId -o none
$fic = @{
    name = 'gh-platform-prod'
    issuer = 'https://token.actions.githubusercontent.com'
    subject = "$subjectPrefix`:environment:platform-prod"
    audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json -Compress
$ficFile = New-TemporaryFile
Set-Content -Path $ficFile -Value $fic
Invoke-Az ad app federated-credential create --id $deployApp.appId --parameters "@$ficFile" -o none
Remove-Item $ficFile

# Contributor at the resource group only. The constrained RBAC Administrator
# assignment is created in section 4, after its condition is computed.
$scope = "/subscriptions/$subscription/resourceGroups/$rg"
$deploySpId = (Invoke-Az ad sp show --id $deployApp.appId -o json | ConvertFrom-Json).id
Invoke-Az role assignment create --assignee-object-id $deploySpId --assignee-principal-type ServicePrincipal `
    --role Contributor --scope $scope -o none
```

Keep the tags in step with `governanceTags` in `infra/network-config.json`. For the optional what-if app, repeat the
app, service principal, and federated-credential steps with `$readerAppName` and a credential named
`gh-pull-request` whose subject is `$subjectPrefix` followed by `:pull_request`, and assign **Reader** at `$scope`
only.

## 2. Verify the subscription, resource group, and tags

```powershell
$scope = "/subscriptions/$subscription/resourceGroups/$rg"
$account = Invoke-Az account show --subscription $subscription -o json | ConvertFrom-Json
if ($account.id -ne $subscription -or $account.tenantId -ne $tenant) { throw 'Subscription/tenant mismatch.' }
$group = Invoke-Az group show --subscription $subscription --name $rg -o json | ConvertFrom-Json
if ($group.id -ne $scope -or $group.location -ne $location) { throw 'RG mismatch.' }
$governanceTags = (Get-Content infra/network-config.json -Raw | ConvertFrom-Json).governanceTags
foreach ($tag in $governanceTags.PSObject.Properties) {
    if ($group.tags.($tag.Name) -cne $tag.Value) { throw "Governance tag mismatch: $($tag.Name)" }
}
```

## 3. Verify the identities and federated credentials

FICs are managed through Entra (`az ad app federated-credential`), not Bicep. Require exactly one credential per
app and stop on any additional subject, issuer, audience, or app credential.

```powershell
$identities = @(
    @{ name = $deployAppName; fic = 'gh-platform-prod'; subject = "$subjectPrefix`:environment:platform-prod" }
    # Optional what-if identity; remove this entry if you did not create it.
    @{ name = $readerAppName; fic = 'gh-pull-request'; subject = "$subjectPrefix`:pull_request" }
)
foreach ($identity in $identities) {
    $apps = @(Invoke-Az ad app list --display-name $identity.name -o json | ConvertFrom-Json |
        Where-Object displayName -ceq $identity.name)
    if ($apps.Count -ne 1) { throw "Expected exactly one app named $($identity.name)." }
    $app = $apps[0]
    $sp = Invoke-Az ad sp show --id $app.appId -o json | ConvertFrom-Json
    if (@($app.passwordCredentials).Count -ne 0 -or @($app.keyCredentials).Count -ne 0) {
        throw 'App has a password or certificate credential.'
    }
    $fics = @(Invoke-Az ad app federated-credential list --id $app.appId -o json | ConvertFrom-Json)
    if ($fics.Count -ne 1 -or $fics[0].name -cne $identity.fic -or
        $fics[0].subject -cne $identity.subject -or
        $fics[0].issuer -cne 'https://token.actions.githubusercontent.com' -or
        @($fics[0].audiences).Count -ne 1 -or
        $fics[0].audiences[0] -cne 'api://AzureADTokenExchange') { throw 'FIC mismatch.' }
    $identity.client = $app.appId
    $identity.sp = $sp.id
}
$deployClient = $identities[0].client
$deploySp = $identities[0].sp
```

## 4. Reconcile the constrained RG delegation

The deploy identity may delegate only AcrPull (`7f951dda-4ed3-4680-a7ca-43fe172d538d`), AcrPush
(`8311e382-0749-4cb8-b61a-304f252e45ec`), and Key Vault Secrets User (`4633458b-17de-408a-b874-0445c86b69e6`). These
are Azure built-in role IDs, the same in every tenant. Owner, Contributor, and RBAC Administrator cannot be
delegated by this identity.

Microsoft's [constrain-roles example](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples#example-constrain-roles)
requires two AND-connected clauses: write uses `@Request`, delete uses `@Resource`. A write-only clause leaves
delete unconstrained. The condition version is `2.0`.

```powershell
$roles = '7f951dda-4ed3-4680-a7ca-43fe172d538d, 8311e382-0749-4cb8-b61a-304f252e45ec, 4633458b-17de-408a-b874-0445c86b69e6'
$write = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles}))"
$delete = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles}))"
$condition = "$write AND $delete"

# First time only: create the constrained assignment.
$existing = @(Invoke-Az role assignment list --subscription $subscription --scope $scope -o json | ConvertFrom-Json |
    Where-Object { $_.principalId -eq $deploySp -and $_.roleDefinitionName -eq 'Role Based Access Control Administrator' })
if ($existing.Count -eq 0) {
    Invoke-Az role assignment create --assignee-object-id $deploySp --assignee-principal-type ServicePrincipal `
        --role 'Role Based Access Control Administrator' --scope $scope `
        --condition $condition --condition-version 2.0 -o none
}

# Verify the exact grants, then the condition.
foreach ($identity in $identities) {
    $grants = @(Invoke-Az role assignment list --subscription $subscription --scope $scope `
        --assignee-object-id $identity.sp --include-inherited --include-groups -o json | ConvertFrom-Json)
    $expectedRoles = if ($identity.sp -eq $deploySp) {
        @('Contributor', 'Role Based Access Control Administrator')
    } else { @('Reader') }
    if ($grants.Count -ne $expectedRoles.Count) { throw 'Unexpected role grant count.' }
    foreach ($role in $expectedRoles) {
        $matches = @($grants | Where-Object {
            $_.roleDefinitionName -eq $role -and $_.scope -eq $scope -and $_.principalId -eq $identity.sp
        })
        if ($matches.Count -ne 1) { throw "Unexpected or inherited grant: $role" }
    }
}
$grants = @(Invoke-Az role assignment list --subscription $subscription --scope $scope -o json | ConvertFrom-Json)
$admin = @($grants | Where-Object {
    $_.principalId -eq $deploySp -and $_.roleDefinitionName -eq 'Role Based Access Control Administrator'
})
if ($admin.Count -ne 1 -or $admin[0].conditionVersion -ne '2.0' -or
    ($admin[0].condition -cne $write -and $admin[0].condition -cne $condition)) {
    throw 'Unexpected delegation condition; stop and review.'
}
if ($admin[0].condition -cne $condition) {
    # Only the legacy write-only condition is upgraded; any other drift stops above.
    $admin[0].condition = $condition
    $admin[0].conditionVersion = '2.0'
    $json = $admin[0] | ConvertTo-Json -Depth 10 -Compress
    Invoke-Az role assignment update --role-assignment $json --only-show-errors -o none
}
$readback = @(Invoke-Az role assignment list --subscription $subscription --scope $scope -o json |
    ConvertFrom-Json | Where-Object id -eq $admin[0].id)
if ($readback.Count -ne 1 -or $readback[0].condition -cne $condition -or
    $readback[0].conditionVersion -ne '2.0') { throw 'Delegation readback mismatch.' }
$readback[0] | Select-Object id, scope, conditionVersion, condition
```

This readback is the exact persisted condition, not a live authorization test. Do not probe permissions by creating
or deleting role assignments. The allowlist limits roles, not recipient principals; the deploy identity remains
privileged and must stay behind the protected environment.

## 5. Create the GitHub environment and set the identity IDs

Create the `platform-prod` environment in your repository (Settings → Environments) with **deployment branches
limited to `main`**. A required human reviewer is optional; the merge process in `AGENTS.md` relies on the branch
restriction. Then verify it and set the identifiers:

```powershell
$environment = Invoke-Gh api "repos/$repo/environments/platform-prod" | ConvertFrom-Json
if ($environment.deployment_branch_policy.custom_branch_policies -ne $true) {
    throw 'Environment must use custom branch policies.'
}
$policy = Invoke-Gh api "repos/$repo/environments/platform-prod/deployment-branch-policies" | ConvertFrom-Json
if ($policy.total_count -ne 1 -or $policy.branch_policies[0].name -cne 'main' -or
    $policy.branch_policies[0].type -cne 'branch') { throw 'Environment branch policy mismatch.' }

$secretIds = @{
    AZURE_CLIENT_ID = $deployClient
    AZURE_TENANT_ID = $tenant
    AZURE_SUBSCRIPTION_ID = $subscription
}
foreach ($name in $secretIds.Keys) {
    $secretIds[$name] | gh secret set $name --repo $repo --env platform-prod
    if ($LASTEXITCODE -ne 0) { throw "Secret upload failed: $name" }
}
```

Client, tenant, and subscription IDs are **non-sensitive identifiers**, not credentials. The deploy workflow reads
them from environment secrets to keep the protected workflow contract. Only if you add a what-if workflow, store the
**Reader** client ID in a repository variable `AZURE_WHATIF_CLIENT_ID`; never put the deploy client ID there, and
never store an Entra client password. The GitHub App private key is an actual secret and is set by the
[GitHub App runbook](github-app.md).

GitHub secrets are write-only: confirm only that the names exist, and do not print values to work around this.

```powershell
$secrets = Invoke-Gh api "repos/$repo/environments/platform-prod/secrets" | ConvertFrom-Json
foreach ($name in $secretIds.Keys) {
    if ($name -cnotin @($secrets.secrets.name)) { throw "Missing environment secret: $name" }
}
```

## Login bindings used by workflows

Only the Azure login job gets `id-token: write` (plus `contents: read`), and `azure/login` is pinned by full commit
SHA.

| Input | Deploy (`environment: platform-prod`) | PR what-if (optional, no environment) |
| --- | --- | --- |
| `client-id` | `${{ secrets.AZURE_CLIENT_ID }}` | `${{ vars.AZURE_WHATIF_CLIENT_ID }}` |
| `tenant-id` | `${{ secrets.AZURE_TENANT_ID }}` | `${{ vars.AZURE_TENANT_ID }}` |
| `subscription-id` | `${{ secrets.AZURE_SUBSCRIPTION_ID }}` | `${{ vars.AZURE_SUBSCRIPTION_ID }}` |

This bootstrap introduces no workflow. A successful token exchange is proven only by a real `deploy.yml` run.
