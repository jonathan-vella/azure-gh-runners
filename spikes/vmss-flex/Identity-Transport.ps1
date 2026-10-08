param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-SpikeFicBody {
    param([hashtable]$Body, [hashtable]$State)
    if ($Body.Count -ne 4 -or
        @($Body.Keys | Where-Object { $_ -notin @('name', 'issuer', 'audiences', 'subject') }).Count -ne 0 -or
        $Body.name -cne "spike60-$($State.runId)-$($State.runOrdinal)" -or
        $Body.issuer -cne 'https://token.actions.githubusercontent.com' -or
        $Body.audiences -isnot [array] -or $Body.audiences.Count -ne 1 -or
        $Body.audiences[0] -cne 'api://AzureADTokenExchange' -or
        $Body.subject -cne 'repo:jonathan-vella@25802147/azure-gh-runners@1408821667:environment:spike-vmss') {
        throw 'Only the exact approved GA environment federation body is permitted.'
    }
}

# Code-first preparation: enabling requires a reviewed source change, not an environment flag.
$executionEnabled = $false
if (-not $executionEnabled) { throw 'Issue 81 authenticated transport is disabled pending exact-head execution direction.' }

Import-Module (Join-Path $PSScriptRoot '../../tools/spikes/keda-egress/Process.psm1') -Force
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
$subscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$scope = "/subscriptions/$subscription/resourceGroups/rg-ghrunners-spike-vmss-swc"
$payload = $request.payload
$cli = Get-BoundedAzureCli
$arguments = @()
$github = $false
$bodyPath = $null
$seconds = 30
function Assert-ObjectId([string]$Value) {
    if ($Value -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' -or $Value -in @(
        '24ebb9cc-0e3b-4956-a333-5665a060f2c7', '4495f30e-3a65-4e94-8d4a-d13dcbe10204',
        '5ee406c4-2cac-4c4a-a900-f9bb6f95b6d0', '70a73ebc-1a9a-4b56-9157-52ec84658ea5',
        '1536c7e0-d4f4-4979-a0b9-702a8fda4f87', '5432b0f4-2bc8-42b6-9c12-1018c9937d9a'
    )) { throw 'Unexpected or production identity ID; no request.' }
}
switch ($request.operation) {
    'account' { $arguments = @('account', 'show', '--subscription', $subscription, '-o', 'json') }
    'group-exists' { $arguments = @('group', 'exists', '--subscription', $subscription, '--name', 'rg-ghrunners-spike-vmss-swc', '-o', 'json') }
    'group-read' { $arguments = @('group', 'show', '--subscription', $subscription, '--name', 'rg-ghrunners-spike-vmss-swc', '-o', 'json') }
    'apps' {
        if ($payload.name -cnotmatch '^sp-ghrunners-spike60-[a-f0-9]{32}-[12]$') { throw 'Unexpected app name.' }
        $filter = [uri]::EscapeDataString("displayName eq '$($payload.name)'")
        $arguments = @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications?`$filter=$filter")
    }
    'sps' {
        Assert-ObjectId $payload.clientId
        $filter = [uri]::EscapeDataString("appId eq '$($payload.clientId)'")
        $arguments = @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter")
    }
    'fics' {
        Assert-ObjectId $payload.application
        $arguments = @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/applications/$($payload.application)/federatedIdentityCredentials")
    }
    'assignments' {
        Assert-ObjectId $payload.servicePrincipal
        $arguments = @('role', 'assignment', 'list', '--subscription', $subscription, '--all',
            '--assignee-object-id', $payload.servicePrincipal, '--include-inherited', '--include-groups', '-o', 'json')
    }
    'environments' {
        $github = $true
        $arguments = @('api', '--paginate', '--slurp', 'repos/jonathan-vella/azure-gh-runners/environments?per_page=100')
    }
    'policies' {
        $github = $true
        $arguments = @('api', '--paginate', '--slurp', 'repos/jonathan-vella/azure-gh-runners/environments/spike-vmss/deployment-branch-policies?per_page=100')
    }
    'request' {
        $state = Get-Content -LiteralPath $payload.statePath -Raw | ConvertFrom-Json -AsHashtable
        $run = $state.runs[-1]
        if ($state.runId -cnotmatch '^[a-f0-9]{32}$' -or $state.head -cnotmatch '^[a-f0-9]{40}$' -or
            $state.runOrdinal -notin @(1, 2) -or $run.ordinal -ne $state.runOrdinal) { throw 'Invalid durable original envelope.' }
        $reserved = if ($payload.method -eq 'DELETE') { $run.cleanup[$payload.step] } else { $run.steps[$payload.step] }
        if ($reserved -cne 'reserved') { throw 'Durable reservation required before any mutation.' }
        $url = [uri]$payload.url
        $allowedGraph = $url.Host -ceq 'graph.microsoft.com' -and
            $url.AbsolutePath -cmatch '^/v1\.0/(applications|servicePrincipals)(/[a-f0-9-]{36}(/federatedIdentityCredentials(/[a-f0-9-]{36})?)?)?$'
        $allowedAzure = $url.Host -ceq 'management.azure.com' -and ($url.AbsolutePath -ceq $scope -or
            $url.AbsolutePath -cmatch "^$([regex]::Escape($scope))/providers/Microsoft.Authorization/roleAssignments/[a-f0-9-]{36}$")
        $allowedGithub = $url.Host -ceq 'api.github.com' -and $url.AbsolutePath -in @(
            '/repos/jonathan-vella/azure-gh-runners/environments/spike-vmss',
            '/repos/jonathan-vella/azure-gh-runners/environments/spike-vmss/deployment-branch-policies'
        )
        if ($url.Scheme -cne 'https' -or $url.UserInfo -or
            -not ($allowedGraph -or $allowedAzure -or $allowedGithub) -or
            $payload.method -notin @('PUT', 'POST', 'DELETE')) { throw 'Unexpected mutation target/method.' }
        if ($allowedGraph) {
            $parts = $url.AbsolutePath.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
            if ($payload.method -ceq 'POST' -and $parts.Count -eq 4 -and
                $parts[3] -ceq 'federatedIdentityCredentials') {
                Assert-SpikeFicBody $payload.body $state
            }
            if ($parts.Count -ge 3) {
                $expectedId = if ($parts[1] -ceq 'applications') { $run.ids.application } else { $run.ids.servicePrincipal }
                if ($parts[2] -cne $expectedId) { throw 'Only captured identity object IDs may be mutated.' }
            }
            if ($parts.Count -eq 5 -and $parts[4] -cne $run.ids.federation) { throw 'Only captured FIC may be deleted.' }
            if ($payload.method -eq 'POST' -and $parts.Count -eq 2) {
                $expectedName = "sp-ghrunners-spike60-$($state.runId)-$($state.runOrdinal)"
                if ($payload.body.displayName -cne $expectedName) { throw 'Only unique envelope/ordinal identity names may be created.' }
                if ($parts[1] -ceq 'servicePrincipals' -and $payload.body.appId -cne $run.ids.client) { throw 'Captured app/client linkage required.' }
            }
        }
        if ($allowedAzure -and $url.AbsolutePath.Contains('/roleAssignments/') -and $payload.method -eq 'PUT') {
            $properties = $payload.body.properties
            if ($properties.principalId -cne $run.ids.servicePrincipal -or
                $properties.principalType -cne 'ServicePrincipal' -or
                $properties.roleDefinitionId -cne "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635") {
                throw 'Only captured temporary SP Owner at exact spike RG is permitted.'
            }
        }
        foreach ($id in [regex]::Matches($url.AbsolutePath, '[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}')) {
            if ($id.Value -cne $subscription) { Assert-ObjectId $id.Value }
        }
        $github = $allowedGithub
        $arguments = if ($github) { @('api', '--method', $payload.method, $url.PathAndQuery.TrimStart('/')) }
            else { @('rest', '--method', $payload.method, '--url', $url.AbsoluteUri) }
        if ($allowedAzure -and $url.AbsolutePath -ceq $scope -and $payload.method -ceq 'DELETE') {
            $seconds = 900
            $arguments = @('group', 'delete', '--subscription', $subscription,
                '--name', 'rg-ghrunners-spike-vmss-swc', '--yes', '-o', 'none')
        }
        if ($payload.ContainsKey('body')) {
            $bodyPath = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($bodyPath, ($payload.body | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
            $arguments += if ($github) { @('--input', $bodyPath) } else { @('--body', "@$bodyPath") }
        }
    }
    default { throw 'Unknown bounded identity transport operation.' }
}
try {
    if ($github) {
        $file = Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
        $result = Invoke-BoundedProcess -FileName $file -Arguments $arguments -TimeoutSeconds 30
    } else {
        $result = Invoke-BoundedProcess -FileName $cli.fileName -Arguments @($cli.prefix + $arguments + @('--only-show-errors')) -TimeoutSeconds $seconds
    }
    if ($result.exitCode -ne 0) { throw 'Bounded identity request failed; output suppressed; absence is unverified.' }
    $value = if ([string]::IsNullOrWhiteSpace($result.stdout)) { @{} } else {
        try { ConvertFrom-Json $result.stdout -AsHashtable -ErrorAction Stop }
        catch { throw 'Invalid identity metadata; provider output suppressed.' }
    }
    if ($value -is [hashtable] -and $value.ContainsKey('@odata.nextLink')) {
        throw 'Identity inventory pagination requires reconciliation; refusing incomplete inventory.'
    }
    $value | ConvertTo-Json -Depth 20 -Compress
} finally {
    if ($bodyPath -and (Test-Path -LiteralPath $bodyPath)) { Remove-Item -LiteralPath $bodyPath }
}
