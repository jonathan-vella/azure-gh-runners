# Bootstrap platform OIDC identities

Issue [#4](https://github.com/jonathan-vella/azure-gh-runners/issues/4).
The owner approved subscription `shared` instead of the original `apex-shared` name.
The approved RG, two apps/SPs, federated credentials, and role assignments already exist.
Run the following PowerShell 7 blocks in order to verify them, reconcile the delegation
condition, and set GitHub identity IDs. Reruns reuse immutable IDs, update the same
assignment, and overwrite the same GitHub settings; they never create duplicate resources.

This is not a disaster-recovery provisioning script. A missing resource or unexpected
trust/role grant is a blocker: stop and obtain approval before recreating anything,
changing the allowlist, relaxing security, or merging. Do not deploy the platform here;
deployment belongs to the gated `platform-prod` workflow.

## Approved inventory and trust boundaries

| Setting | Value |
| --- | --- |
| Subscription | `shared` / `b47d2942-f5ad-4d3c-b28e-c23e4f83d97e` |
| Tenant | `30bac921-1547-4b1e-8445-72455da783f1` |
| RG / region | `rg-ghrunners-prod-swc` / `swedencentral` |
| Deploy app | `sp-ghrunners-platform-prod` |
| Deploy client ID | `5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0` |
| Deploy app object ID | `4495f30e-3a65-4e94-8d4a-d13dcbe10204` |
| Deploy SP object ID | `24ebb9cc-0e3b-4956-a333-5665a060f2c7` |
| Deploy FIC | `gh-platform-prod` / `repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod` |
| What-if app | `sp-ghrunners-whatif` |
| What-if client ID | `5432b0f4-2bc8-42b6-9c12-1018c9937d9a` |
| What-if app object ID | `1536c7e0-d4f4-4979-a0b9-702a8fda4f87` |
| What-if SP object ID | `70a73ebc-1a9a-4b56-9157-52ec84658ea5` |
| What-if FIC | `gh-pull-request` / `repo:jonathan-vella@25802147/azure-gh-runners@1408821667:pull_request` |
| Both FIC issuers | `https://token.actions.githubusercontent.com` |
| Both FIC audiences | Only `api://AzureADTokenExchange` |

## Current repository OIDC subject configuration

On 2026-10-07, the GitHub repository API returned `use_default: true`,
`use_immutable_subject: true`, and the prefix
`repo:jonathan-vella@25802147/azure-gh-runners@1408821667`. GitHub's
[OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) documents that immutable subject
claims include immutable owner and repository IDs. During issue #6, a `workflow_dispatch` on `main` presented the
exact subject `repo:jonathan-vella@25802147/azure-gh-runners@1408821667:ref:refs/heads/main`.

On 2026-10-07, Entra readback confirmed the two stored production FIC subjects shown in the inventory match the
repository's immutable subject prefix. GitHub's [OIDC reference](https://docs.github.com/en/actions/reference/security/oidc)
documents that immutable subject claims include immutable owner and repository IDs. The #6 `workflow_dispatch`
produced the observed `:ref:refs/heads/main` suffix; the environment and `pull_request` values above are Entra
readbacks, not proof of successful workflow token exchange. End-to-end production deploy and PR what-if OIDC
verification remains pending under their owning issues. Do not infer other suffixes by substituting them for the
observed ref suffix, and do not change production identities as part of issue #6.

Deploy has Contributor and constrained Role Based Access Control Administrator at the
RG only. What-if has Reader at the RG only. Both apps have no password or certificate
credentials. **Never combine these FICs on one app**: RBAC belongs to the SP, not to a
FIC, so a PR could otherwise inherit deployment privileges.

The PR what-if job must not reference a GitHub environment. Environment and event
context affect the OIDC subject; verify the exact current claim against the FIC rather
than inferring its suffix. Do not create a `whatif` environment or give the Reader app
deployment rights. Reader intentionally cannot deploy or manage assignments; if a
future what-if implementation requires additional permissions, stop for a separate
review rather than escalating automatically.

## Prerequisites and fixed scope

Use an already-authenticated Azure CLI session in the approved tenant, with authority
to read Entra metadata and update this RG's existing role assignment condition.
Use an already-authenticated `gh` CLI session with repository environment/secret/variable
administration rights and permission to read repository OIDC customization. Do not
create client secrets, export tokens, enable command tracing/transcripts, or read/log
`GH_APP_PRIVATE_KEY`.

These commands target the Windows MSI Azure CLI's bundled Python directly to preserve
JSON and condition quoting that `az.cmd` can corrupt. They do not install a runtime.

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
$repo = 'jonathan-vella/azure-gh-runners'
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$tenant = '30bac921-1547-4b1e-8445-72455da783f1'
$rg = 'rg-ghrunners-prod-swc'
$scope = "/subscriptions/$subscription/resourceGroups/$rg"
$deployClient = '5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0'
$readerClient = '5432b0f4-2bc8-42b6-9c12-1018c9937d9a'
$deploySp = '24ebb9cc-0e3b-4956-a333-5665a060f2c7'
$readerSp = '70a73ebc-1a9a-4b56-9157-52ec84658ea5'
$account = Invoke-Az account show --subscription $subscription -o json | ConvertFrom-Json
if ($account.id -ne $subscription -or $account.tenantId -ne $tenant -or $account.name -ne 'shared') {
    throw 'Subscription/tenant mismatch.'
}
$group = Invoke-Az group show --subscription $subscription --name $rg -o json | ConvertFrom-Json
if ($group.id -ne $scope -or $group.location -ne 'swedencentral') { throw 'RG mismatch.' }
$tags = @{
    application = 'ghrunners'; environment = 'prod'; workload = 'gh-runners'
    owner = 'jonathan-vella'; costcenter = 'platform-engineering'
    'tech-contact' = 'jonathan-vella'; 'technical-contact' = 'jonathan-vella'
    sla = 'development'; 'backup-policy' = 'none'; 'maint-window' = 'none'
}
foreach ($key in $tags.Keys) {
    if ($group.tags.$key -cne $tags[$key]) { throw "Governance tag mismatch: $key" }
}
```

## Verify the two exact federated credentials

FICs are managed through Entra/Graph (`az ad app federated-credential`), not Bicep.
The following are approved stored values, not proof that they still match GitHub's
current immutable subject claims. No production FIC mutation is authorized here.
Require exactly one FIC per app and stop on any additional subject, issuer, audience,
or credential; a mismatch is a blocker for the owning production issues, not permission
to alter a production FIC in this runbook.

```powershell
$identities = @(
    @{
        client = $deployClient; sp = $deploySp; name = 'sp-ghrunners-platform-prod'
        appObject = '4495f30e-3a65-4e94-8d4a-d13dcbe10204'
        fic = 'gh-platform-prod'
        subject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:platform-prod'
    },
    @{
        client = $readerClient; sp = $readerSp; name = 'sp-ghrunners-whatif'
        appObject = '1536c7e0-d4f4-4979-a0b9-702a8fda4f87'
        fic = 'gh-pull-request'
        subject = 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:pull_request'
    }
)
foreach ($identity in $identities) {
    $app = Invoke-Az ad app show --id $identity.client -o json | ConvertFrom-Json
    $sp = Invoke-Az ad sp show --id $identity.sp -o json | ConvertFrom-Json
    if ($app.appId -ne $identity.client -or $app.id -ne $identity.appObject -or
        $app.displayName -cne $identity.name -or $sp.appId -ne $identity.client -or
        $sp.id -ne $identity.sp -or @($app.passwordCredentials).Count -ne 0 -or
        @($app.keyCredentials).Count -ne 0) { throw 'App/SP or credential mismatch.' }
    $fics = @(Invoke-Az ad app federated-credential list --id $identity.client -o json | ConvertFrom-Json)
    if ($fics.Count -ne 1 -or $fics[0].name -cne $identity.fic -or
        $fics[0].subject -cne $identity.subject -or
        $fics[0].issuer -cne 'https://token.actions.githubusercontent.com' -or
        @($fics[0].audiences).Count -ne 1 -or
        $fics[0].audiences[0] -cne 'api://AzureADTokenExchange') { throw 'FIC mismatch.' }
}
```

## Reconcile the constrained RG delegation

The only delegated roles are AcrPull (`7f951dda-4ed3-4680-a7ca-43fe172d538d`),
AcrPush (`8311e382-0749-4cb8-b61a-304f252e45ec`), and Key Vault Secrets User
(`4633458b-17de-408a-b874-0445c86b69e6`). Owner, Contributor, and RBAC Administrator
cannot be delegated by this identity. The existing Contributor grant is unchanged.

Microsoft's [constrain-roles example](https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-examples#example-constrain-roles)
requires two AND-connected clauses: write uses `@Request`, delete uses `@Resource`.
A write-only clause leaves delete unconstrained. The condition version is `2.0`.
The code below accepts only the approved legacy write-only condition or the final
condition; unexpected drift blocks a rerun instead of silently relaxing a stricter policy.

```powershell
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
$roles = '7f951dda-4ed3-4680-a7ca-43fe172d538d, 8311e382-0749-4cb8-b61a-304f252e45ec, 4633458b-17de-408a-b874-0445c86b69e6'
$write = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles}))"
$delete = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles}))"
$condition = "$write AND $delete"
$grants = @(Invoke-Az role assignment list --subscription $subscription --scope $scope -o json | ConvertFrom-Json)
$admin = @($grants | Where-Object {
    $_.principalId -eq $deploySp -and $_.roleDefinitionName -eq 'Role Based Access Control Administrator'
})
if ($admin.Count -ne 1 -or $admin[0].conditionVersion -ne '2.0' -or
    ($admin[0].condition -cne $write -and $admin[0].condition -cne $condition)) {
    throw 'Unexpected delegation condition; obtain review.'
}
if ($admin[0].condition -cne $condition) {
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

This readback is the exact persisted condition, not a live OIDC authorization test.
Do not probe permissions by creating or deleting role assignments. The allowlist
limits roles, not recipient principals; the deploy identity remains privileged and
must stay behind the protected environment.

## Verify the environment and set the identity IDs

`platform-prod` already requires reviewer `jonathan-vella` and allows only branch
`main`. Preserve its protection settings and existing `GH_APP_*` secrets; this
runbook does not create or relax an environment.

Client, tenant, and subscription IDs are **non-sensitive identifiers**, not credentials.
Deployment uses environment secrets to keep the established protected workflow contract.
PR validation uses repository variables because it has no environment; only its Reader
client ID is exposed there. Never put the deploy client ID in `AZURE_WHATIF_CLIENT_ID`,
and never store an Entra client password. GitHub App private keys are actual secrets.

```powershell
$environment = Invoke-Gh api "repos/$repo/environments/platform-prod" | ConvertFrom-Json
$reviewRules = @($environment.protection_rules | Where-Object type -eq 'required_reviewers')
if ($reviewRules.Count -ne 1 -or @($reviewRules[0].reviewers).Count -ne 1 -or
    $reviewRules[0].reviewers[0].reviewer.login -cne 'jonathan-vella' -or
    $environment.deployment_branch_policy.protected_branches -ne $false -or
    $environment.deployment_branch_policy.custom_branch_policies -ne $true) {
    throw 'Environment protection mismatch.'
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
$variableIds = @{
    AZURE_WHATIF_CLIENT_ID = $readerClient
    AZURE_TENANT_ID = $tenant
    AZURE_SUBSCRIPTION_ID = $subscription
}
foreach ($name in $variableIds.Keys) {
    Invoke-Gh variable set $name --repo $repo --body $variableIds[$name]
    $actual = Invoke-Gh variable get $name --repo $repo
    if ($actual -cne $variableIds[$name]) { throw "Variable readback mismatch: $name" }
}
$secrets = Invoke-Gh api "repos/$repo/environments/platform-prod/secrets" | ConvertFrom-Json
foreach ($name in $secretIds.Keys) {
    if ($name -cnotin @($secrets.secrets.name)) { throw "Missing environment secret: $name" }
}
Invoke-Gh secret list --repo $repo --env platform-prod
Invoke-Gh variable list --repo $repo
```

GitHub secrets are write-only: successful uploads of the fixed values and secret-name
metadata verify configuration, but plaintext values cannot be read back. Do not claim
that a secret-list response proves its value, or print values to work around this.

When implementing the workflows in issues #26/#27, give only the Azure login job
`id-token: write` (plus `contents: read`) and pin `azure/login` by full commit SHA.
The login inputs must use the following bindings:

| Input | PR what-if (no environment) | Deploy (`environment: platform-prod`) |
| --- | --- | --- |
| `client-id` | `${{ vars.AZURE_WHATIF_CLIENT_ID }}` | `${{ secrets.AZURE_CLIENT_ID }}` |
| `tenant-id` | `${{ vars.AZURE_TENANT_ID }}` | `${{ secrets.AZURE_TENANT_ID }}` |
| `subscription-id` | `${{ vars.AZURE_SUBSCRIPTION_ID }}` | `${{ secrets.AZURE_SUBSCRIPTION_ID }}` |

No OIDC workflow is introduced by this bootstrap. An end-to-end token exchange
and what-if/deployment test remain part of #26/#27, not evidence from a local CLI
session authenticated as the operator.
