[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deploy', 'Test', 'Diagnose', 'Cleanup', 'Validate')]
    [string] $Action,

    [string] $SubscriptionId,

    [string] $ResourceGroupName = 'rg-ghrunners-spike7-swc',

    [ValidateSet('Consumption', 'D4')]
    [string] $Profile = 'Consumption',

    [ValidateRange(1, 45)]
    [int] $TimeoutMinutes = 45,

    [switch] $ConfirmCapacityRecovered,

    [switch] $ConfirmD4ProfileAttempt,

    [string] $EvidencePath
)

$ErrorActionPreference = 'Stop'

$approvedSubscription = 'b47d2942-f5ad-4d3c-b28e-c23e4f83d97e'
$approvedTenant = '30bac921-1547-4b1e-8445-72455da783f1'
$approvedLocation = 'swedencentral'
$approvedResourceGroup = 'rg-ghrunners-spike7-swc'
$ownerTag = @{
    application = 'ghrunners'
    environment = 'spike'
    workload = 'gh-runners'
    owner = 'jonathan-vella'
    costcenter = 'platform-engineering'
    'tech-contact' = 'jonathan-vella'
    'technical-contact' = 'jonathan-vella'
    sla = 'development'
    'backup-policy' = 'none'
    'maint-window' = 'none'
}
$templatePath = Join-Path $PSScriptRoot 'main.bicep'
$jobTemplatePath = Join-Path $PSScriptRoot 'job.bicep'
$maxExecutionWait = [TimeSpan]::FromMinutes([Math]::Min($TimeoutMinutes, 10))
$pollSeconds = 15
$processModule = Import-Module (Join-Path $PSScriptRoot '..\..\tools\spikes\keda-egress\Process.psm1') -Force -PassThru
if (-not $processModule) {
    throw 'Could not load the shared bounded-process helper.'
}
Import-Module (Join-Path $PSScriptRoot 'Comparison.psm1') -Force

function Get-RemainingActionSeconds {
    $remaining = [int][Math]::Floor(($script:actionDeadline - [DateTimeOffset]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) {
        throw 'The bounded Azure action time budget expired.'
    }
    return [Math]::Min($remaining, 2700)
}

function Get-SanitizedAzureCliCode {
    param(
        [AllowEmptyString()][string] $Diagnostics
    )

    $knownCodes = @(
        'AKSCapacityHeavyUsage',
        'ManagedEnvironmentCapacityHeavyUsageError',
        'ManagedEnvironmentNotReadyForAppCreation',
        'AuthorizationFailed',
        'ResourceNotFound',
        'DeploymentNotFound',
        'DeploymentFailed',
        'InvalidTemplate',
        'InvalidTemplateDeployment',
        'Conflict',
        'TooManyRequests',
        'OperationNotAllowed',
        'ForbiddenByFirewall',
        'ForbiddenByRbac',
        'KeyVaultSecretRefIdentityError'
    )
    $codes = [System.Collections.Generic.List[string]]::new()
    try {
        $structured = ConvertFrom-Json -InputObject $Diagnostics -ErrorAction Stop
        $pending = [System.Collections.Generic.Queue[object]]::new()
        $pending.Enqueue($structured)
        while ($pending.Count) {
            $node = $pending.Dequeue()
            if ($node.code) { $codes.Add([string]$node.code) }
            foreach ($child in @($node.error, $node.innererror) + @($node.details)) {
                if ($null -ne $child) { $pending.Enqueue($child) }
            }
        }
    } catch {
        # Accept only exact readback codes or the CLI's explicit error-code prefix.
        foreach ($code in $knownCodes) {
            if ($Diagnostics.Trim() -ceq $code -or
                $Diagnostics -cmatch "(?m)^ERROR:\s*\($([regex]::Escape($code))\)") {
                $codes.Add($code)
            }
        }
    }
    foreach ($code in $knownCodes) {
        if ($codes.Contains($code)) { return $code }
    }
    return 'unclassified'
}

function Get-SafeCliFailure {
    param([string] $Diagnostics)

    $code = Get-SanitizedAzureCliCode -Diagnostics $Diagnostics
    $category = switch -Regex ($code) {
        '^(AuthorizationFailed|ForbiddenByRbac)$' { 'Authentication'; break }
        '^InvalidTemplate' { 'Validation'; break }
        '^unclassified$' { 'Unclassified'; break }
        default { 'Arm'; break }
    }
    if ($code -ceq 'unclassified') {
        $category = switch -Regex ($Diagnostics) {
            'BCP\d{3}\b|Bicep compilation failed' { 'Bicep'; break }
            'No such file or directory|FileNotFoundError|could not find file|Unable to load parameters' { 'LocalFile'; break }
            'az login|AADSTS\d+|AuthenticationFailed|ExpiredAuthenticationToken' { 'Authentication'; break }
            'unrecognized arguments:|the following arguments are required:|invalid choice:' { 'CliArguments'; break }
            default { 'Unclassified'; break }
        }
    }
    $correlationId = $null
    try {
        $structured = ConvertFrom-Json -InputObject $Diagnostics -ErrorAction Stop
        if ([string]$structured.correlationId -cmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') {
            $correlationId = [string]$structured.correlationId
        }
    } catch {
        # Non-JSON CLI diagnostics are classified only into fixed categories/codes.
    }
    return [pscustomobject]@{ Category = $category; Code = $code; CorrelationId = $correlationId }
}

function Invoke-AzProcess {
    param(
        [Parameter(Mandatory)][string[]] $Arguments
    )

    try {
        $cli = Get-BoundedAzureCli
        $result = Invoke-BoundedProcess -FileName $cli.fileName `
            -Arguments (@($cli.prefix) + $Arguments + @('--only-show-errors')) `
            -TimeoutSeconds (Get-RemainingActionSeconds)
    } catch {
        if ($_.Exception.Message -match 'exceeded its \d+-second limit') {
            throw 'Bounded Azure CLI operation timed out and was terminated; ARM may still be active, so inspect its state before retrying.'
        }
        throw 'Bounded Azure CLI operation failed; process diagnostics were suppressed.'
    }

    $failure = Get-SafeCliFailure -Diagnostics ([string]$result.stderr + "`n" + [string]$result.stdout)
    return [pscustomobject]@{
        ExitCode = [int]$result.exitCode
        StdOut = [string]$result.stdout
        ErrorCode = if ($result.exitCode -ne 0) {
            $failure.Code
        } else { $null }
        ErrorCategory = if ($result.exitCode -ne 0) { $failure.Category } else { $null }
        CorrelationId = $failure.CorrelationId
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = Invoke-AzProcess -Arguments (@($Arguments) + @('--output', 'json'))
    if ($result.ExitCode -ne 0) {
        throw "Azure CLI command failed (code=$($result.ErrorCode)); output was suppressed."
    }
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        return $null
    }
    try {
        return ($result.StdOut | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw 'Azure CLI returned invalid JSON; output was suppressed.'
    }
}

function Invoke-AzBounded {
    param(
        [Parameter(Mandatory)][string[]] $Arguments
    )

    return (Invoke-AzProcess -Arguments (@($Arguments) + @('--output', 'none'))).ExitCode
}

function Invoke-InfrastructureDeployment {
    param([Parameter(Mandatory)][string] $ParameterFile)

    $result = Invoke-AzProcess -Arguments @(
        'deployment', 'group', 'create', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup, '--name', 'issue7-spike',
        '--template-file', $templatePath, '--parameters', "@$ParameterFile", '--output', 'none'
    )
    if ($result.ExitCode -eq 0) { return }

    $readbackCode = 'Unavailable'
    try {
        $readback = Invoke-AzProcess -Arguments @(
            'deployment', 'group', 'show', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--name', 'issue7-spike',
            '--query', 'properties.error.code', '--output', 'tsv'
        )
        $readbackCode = if ($readback.ExitCode -eq 0) {
            Get-SanitizedAzureCliCode -Diagnostics $readback.StdOut
        } else { $readback.ErrorCode }
    } catch {
        $readbackCode = 'Unavailable'
    }
    throw "Issue-7 infrastructure deployment failed at stage=resource-group-deployment; originalExit=$($result.ExitCode); category=$($result.ErrorCategory); originalCode=$($result.ErrorCode); correlationId=$($result.CorrelationId); readbackCode=$readbackCode. Output was suppressed; explicit cleanup is required."
}

function Get-SpikeDeploymentState {
    $group = Get-OptionalTaggedResourceGroup
    if (-not $group) { return 'ResourceGroupAbsent' }
    $deployments = Get-SpikeJsonArray @(
        'deployment', 'group', 'list', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup,
        '--query', '[].{name:name,state:properties.provisioningState}'
    )
    if ($deployments.Count -eq 0) {
        $resources = Get-SpikeJsonArray @(
            'resource', 'list', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--query', '[].id'
        )
        if ($resources.Count -ne 0) {
            throw 'Deployment is positively absent but the owned resource group is not empty; refusing deletion.'
        }
        return 'DeploymentAbsentOwnedGroupEmpty'
    }
    foreach ($deployment in $deployments) {
        if ($deployment.state -cnotin @('Succeeded', 'Failed', 'Canceled')) {
            return 'NonTerminal'
        }
    }
    return 'Terminal'
}

function Get-SpikeJsonArray {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = Invoke-AzProcess -Arguments (@($Arguments) + @('--output', 'json'))
    if ($result.ExitCode -ne 0) {
        throw "Spike inventory read failed (code=$($result.ErrorCode)); refusing deletion."
    }
    try {
        $items = ConvertFrom-Json -InputObject $result.StdOut -NoEnumerate -ErrorAction Stop
    } catch {
        throw 'Spike inventory read returned invalid JSON; refusing deletion.'
    }
    if ($items -isnot [array]) {
        throw 'Spike inventory read did not return an explicit array; refusing deletion.'
    }
    return ,$items
}

function Get-ResourceGroupExists {
    $result = Invoke-AzProcess -Arguments @(
        'group', 'exists', '--subscription', $approvedSubscription,
        '--name', $approvedResourceGroup, '--output', 'tsv'
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not determine exact spike resource-group existence (code=$($result.ErrorCode)); refusing to continue."
    }
    switch ($result.StdOut.Trim()) {
        'true' { return $true }
        'false' { return $false }
        default { throw 'Resource-group existence readback was ambiguous; refusing to continue.' }
    }
}

function Assert-ApprovedScope {
    if ($SubscriptionId -cne $approvedSubscription) {
        throw 'Pass the exact approved shared subscription ID.'
    }
    if ($ResourceGroupName -cne $approvedResourceGroup) {
        throw 'This script is restricted to the exact issue-7 resource group.'
    }

    $account = Invoke-AzJson @('account', 'show', '--subscription', $approvedSubscription)
    if ($account.id -cne $approvedSubscription -or $account.tenantId -cne $approvedTenant -or
        $account.name -cne 'shared') {
        throw 'Azure CLI account does not match the approved subscription and tenant.'
    }
}

function Get-TaggedResourceGroup {
    $group = Invoke-AzJson @('group', 'show', '--subscription', $approvedSubscription, '--name', $approvedResourceGroup)
    if (-not $group -or $group.id -cne "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup" -or
        $group.location -cne $approvedLocation) {
        throw 'The spike resource group is missing or has an unexpected scope/location.'
    }
    foreach ($key in $ownerTag.Keys) {
        if ($group.tags.$key -cne $ownerTag[$key]) {
            throw "Spike resource group ownership tag mismatch: $key"
        }
    }
    return $group
}

function Get-OptionalTaggedResourceGroup {
    if (-not (Get-ResourceGroupExists)) {
        return $null
    }
    return Get-TaggedResourceGroup
}

function Assert-ProfileAuthorization {
    if ($Profile -ceq 'D4') {
        if (-not $ConfirmD4ProfileAttempt) {
            throw 'The D4 alternative-profile attempt requires -ConfirmD4ProfileAttempt; this does not assert regional capacity recovery.'
        }
        return
    }
    if (-not $ConfirmCapacityRecovered) {
        throw 'The Consumption deployment or job run requires explicit confirmation of capacity recovery.'
    }
}

function Assert-EnvironmentProfile {
    param(
        [Parameter(Mandatory)][object] $EnvironmentState,
        [Parameter(Mandatory)][ValidateSet('Consumption', 'D4')][string] $ExpectedProfile
    )

    if (-not $EnvironmentState.properties) {
        throw 'Managed-environment readback is missing resource properties.'
    }
    $properties = $EnvironmentState.properties
    if ($properties.provisioningState -cne 'Succeeded') {
        throw 'Managed-environment provisioning has not succeeded.'
    }
    if ($properties.zoneRedundant -cne $false) {
        throw 'Managed-environment readback must confirm zoneRedundant=false.'
    }
    $profiles = @($properties.workloadProfiles)
    $expectedNames = if ($ExpectedProfile -ceq 'D4') {
        @('Consumption', 'D4')
    } else {
        @('Consumption')
    }
    $actualNames = @($profiles | ForEach-Object { [string]$_.name } | Sort-Object)
    if ($profiles.Count -ne $expectedNames.Count -or
        ($actualNames -join ',') -cne (($expectedNames | Sort-Object) -join ',')) {
        throw 'Managed environment must expose exactly the expected workload profiles.'
    }

    if ($ExpectedProfile -ceq 'D4') {
        $expectedType = 'D4'
        $expectedMinimum = 0
        $expectedMaximum = 3
        $pinnedProfiles = @($profiles | Where-Object {
            @($_.zones | Where-Object { $null -ne $_ }).Count -gt 0
        })
        if (@($properties.zones | Where-Object { $null -ne $_ }).Count -gt 0 -or $pinnedProfiles.Count -gt 0) {
            throw 'D4 environment and profile must not pin availability zones.'
        }
    } else {
        $expectedType = 'Consumption'
        $expectedMinimum = 0
        $expectedMaximum = 1
    }

    $profile = @($profiles | Where-Object { $_.name -ceq $ExpectedProfile })[0]
    if ($null -eq $profile.minimumCount -or $null -eq $profile.maximumCount -or
        $profile.name -cne $ExpectedProfile -or $profile.workloadProfileType -cne $expectedType -or
        [int]$profile.minimumCount -ne $expectedMinimum -or
        [int]$profile.maximumCount -ne $expectedMaximum) {
        throw "Managed-environment profile readback did not match the exact $ExpectedProfile profile contract."
    }
    if ($ExpectedProfile -ceq 'D4') {
        $consumptionProfile = @($profiles | Where-Object { $_.name -ceq 'Consumption' })[0]
        if ([int]$consumptionProfile.minimumCount -ne 0 -or [int]$consumptionProfile.maximumCount -ne 1) {
            throw 'D4 environment readback did not preserve the Consumption profile defaults.'
        }
    }
    return $profile
}

function Set-PrivateParametersFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Secret
    )

    $null = New-Item -ItemType File -Path $Path -ErrorAction Stop
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $access = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $currentUser,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($access)
    Set-Acl -LiteralPath $Path -AclObject $acl

    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            runSuffix = @{ value = $script:runSuffix }
            workloadProfileName = @{ value = $Profile }
            probeSecret = @{ value = $Secret }
            probeDigest = @{ value = $script:secretDigest }
        }
    }
    $json = $parameters | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-ResourceGroupResource {
    param([Parameter(Mandatory)][string] $Name)

    $resources = Invoke-AzJson @('resource', 'list', '--subscription', $approvedSubscription, '--resource-group', $approvedResourceGroup)
    $matches = @($resources | Where-Object { $_.name -ceq $Name })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one owned resource named $Name."
    }
    return $matches[0]
}

function Set-KeyVaultBypass {
    param(
        [Parameter(Mandatory)][string] $VaultId,
        [Parameter(Mandatory)][ValidateSet('None', 'AzureServices')][string] $Bypass
    )

    $result = Invoke-AzProcess -Arguments @(
        'resource', 'update', '--subscription', $approvedSubscription, '--ids', $VaultId,
        '--set', "properties.networkAcls.bypass=$Bypass", '--output', 'none'
    )
    if ($result.ExitCode -ne 0) {
        throw "Azure rejected the requested trusted-services bypass setting: $Bypass."
    }
    $vault = Invoke-AzJson @('resource', 'show', '--subscription', $approvedSubscription, '--ids', $VaultId)
    if ($vault.properties.publicNetworkAccess -cne 'Disabled' -or
        $vault.properties.networkAcls.defaultAction -cne 'Deny' -or
        $vault.properties.networkAcls.bypass -cne $Bypass) {
        throw "Key Vault policy readback did not match bypass=$Bypass with public access disabled."
    }
}

function New-FreshDiagnosticJob {
    param(
        [Parameter(Mandatory)][string] $Bypass,
        [Parameter(Mandatory)][string] $EnvironmentId,
        [Parameter(Mandatory)][string] $IdentityId,
        [Parameter(Mandatory)][string] $KeyVaultSecretUrl,
        [Parameter(Mandatory)][string] $ProbeDigest
    )

    $mode = if ($Bypass -ceq 'None') { 'none' } else { 'svc' }
    $jobName = "caj-ghr7-$script:runSuffix-$mode-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $deploymentName = "issue7-$mode-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $script:legEvidence.JobName = $jobName
    $script:legEvidence.DeploymentName = $deploymentName
    $exitCode = Invoke-AzBounded @(
        'deployment', 'group', 'create', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup, '--name', $deploymentName,
        '--template-file', $jobTemplatePath,
        '--parameters', "jobName=$jobName", "location=$approvedLocation",
        "environmentResourceId=$EnvironmentId", "identityResourceId=$IdentityId",
        "keyVaultSecretUrl=$KeyVaultSecretUrl", "workloadProfileName=$Profile",
        "probeDigest=$ProbeDigest"
    )
    if ($exitCode -ne 0) {
        $operations = @(Invoke-AzJson @(
            'deployment', 'operation', 'group', 'list', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--name', $deploymentName
        ))
        $failed = @($operations | Where-Object { $_.properties.provisioningState -ceq 'Failed' })
        $resourceFailures = [System.Collections.Generic.List[object]]::new()
        foreach ($operation in $failed) {
            $targetId = [string]$operation.properties.targetResource.id
            $deploymentPrefix = "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup/providers/Microsoft.Resources/deployments/"
            if ($targetId.StartsWith($deploymentPrefix, [StringComparison]::Ordinal) -and
                $targetId.Substring($deploymentPrefix.Length) -cmatch '^job-[a-z0-9]{13}$') {
                # The pinned AVM job is a child ARM deployment; inspect its resource error, not its wrapper.
                $childName = $targetId.Substring($deploymentPrefix.Length)
                $childOperations = @(Invoke-AzJson @(
                    'deployment', 'operation', 'group', 'list', '--subscription', $approvedSubscription,
                    '--resource-group', $approvedResourceGroup, '--name', $childName
                ))
                $childFailures = @($childOperations | Where-Object { $_.properties.provisioningState -ceq 'Failed' })
                if ($childFailures.Count) {
                    foreach ($childFailure in $childFailures) { $resourceFailures.Add($childFailure) }
                } else { $resourceFailures.Add($operation) }
            } else { $resourceFailures.Add($operation) }
        }
        $jobId = "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup/providers/Microsoft.App/jobs/$jobName"
        $expectedDenial = $resourceFailures.Count -gt 0
        $failureCodes = [System.Collections.Generic.List[string]]::new()
        foreach ($operation in $resourceFailures) {
            $message = $operation.properties.statusMessage
            if ($message -is [string]) {
                try { $message = $message | ConvertFrom-Json -ErrorAction Stop }
                catch { $message = $null }
            }
            if ($message.error) {
                $failureCodes.Add((Get-SpikeSanitizedErrorCode -ErrorDetail $message.error))
            }
            if ($operation.properties.targetResource.id -cne $jobId -or -not $message.error -or
                -not (Test-SpikeKeyVaultNetworkDenial -ErrorDetail $message.error)) {
                $expectedDenial = $false
            }
        }
        if ($expectedDenial) {
            $script:legEvidence.Status = 'Failed'
            $script:legEvidence.Code = 'ForbiddenByFirewall'
            return $null
        }
        $script:legEvidence.Code = if ($failureCodes.Count) {
            ($failureCodes | Select-Object -Unique) -join ','
        } else { 'UnclassifiedDeploymentFailure' }
        throw 'Fresh diagnostic job deployment failed outside the documented Key Vault network-denial allowlist.'
    }
    $jobState = Invoke-AzJson @(
        'containerapp', 'job', 'show', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup, '--name', $jobName
    )
    if ($jobState.properties.provisioningState -cne 'Succeeded' -or
        $jobState.properties.workloadProfileName -cne $Profile) {
        $script:legEvidence.Code = 'WorkloadProfileReadbackMismatch'
        throw 'Fresh diagnostic job did not read back on the selected workload profile.'
    }
    $script:legEvidence.JobWorkloadProfileName = [string]$jobState.properties.workloadProfileName
    return $jobName
}

function Invoke-JobAndWait {
    param([Parameter(Mandatory)][string] $JobName)

    $started = Invoke-AzJson @(
        'containerapp', 'job', 'start', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup, '--name', $JobName
    )
    $executionName = $started.name
    if (-not $executionName) {
        throw 'ACA did not return a job execution name.'
    }
    $script:legEvidence.ExecutionName = $executionName

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if ($script:testDeadline -and [DateTimeOffset]::UtcNow -ge $script:testDeadline) {
            throw 'The bounded comparison time budget expired while awaiting the ACA execution.'
        }
        Start-Sleep -Seconds ([Math]::Min($pollSeconds, (Get-RemainingActionSeconds)))
        $execution = Invoke-AzJson @(
            'containerapp', 'job', 'execution', 'show', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--name', $JobName,
            '--job-execution-name', $executionName
        )
        $status = [string]$execution.properties.status
        if ($status -in @('Succeeded', 'Failed')) {
            return $status
        }
        if ($status -ceq 'Stopped') {
            throw 'The ACA execution was stopped before producing a comparison result.'
        }
    } while ($timer.Elapsed -lt $maxExecutionWait)

    throw 'Job execution exceeded the bounded wait; no container logs or values were emitted.'
}

function Invoke-DiagnosticCase {
    param(
        [string] $Bypass, [string] $EnvironmentId, [string] $IdentityId,
        [string] $KeyVaultSecretUrl, [string] $ProbeDigest
    )

    $script:legEvidence = [pscustomobject]@{
        Status = 'OperationalError'; Stage = 'job-provisioning'; Code = $null
        JobName = $null; ExecutionName = $null; DeploymentName = $null
        EnvironmentProvisioningState = [string]$script:profileReadback.EnvironmentProvisioningState
        WorkloadProfileName = [string]$script:profileReadback.WorkloadProfileName
        WorkloadProfileType = [string]$script:profileReadback.WorkloadProfileType
        MinimumCount = [int]$script:profileReadback.MinimumCount
        MaximumCount = [int]$script:profileReadback.MaximumCount
        ZoneRedundant = $script:profileReadback.ZoneRedundant
        JobWorkloadProfileName = $null
    }
    try {
        $jobName = New-FreshDiagnosticJob -Bypass $Bypass -EnvironmentId $EnvironmentId `
            -IdentityId $IdentityId -KeyVaultSecretUrl $KeyVaultSecretUrl -ProbeDigest $ProbeDigest
        if ($jobName) {
            $script:legEvidence.Stage = 'execution'
            $script:legEvidence.Status = Invoke-JobAndWait -JobName $jobName
        }
        return $script:legEvidence
    } catch {
        if (-not $script:legEvidence.Code) {
            $script:legEvidence.Code = $_.Exception.GetType().Name
        }
        $_.Exception.Data['Evidence'] = $script:legEvidence
        throw
    }
}

if ($Action -eq 'Validate') {
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw 'Spike Bicep template is missing.'
    }
    Write-Output 'Local artifact path check passed.'
    return
}

if (-not $SubscriptionId) {
    throw 'An explicit --subscription ID is required for every Azure operation.'
}
$script:actionDeadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
Assert-ApprovedScope

switch ($Action) {
    'Deploy' {
        Assert-ProfileAuthorization
        if ($env:OS -ne 'Windows_NT') {
            throw 'Secure temporary parameter files require Windows ACLs; run this script on Windows.'
        }
        if (Get-ResourceGroupExists) {
            throw 'The exact spike resource group must be absent before deployment; no existing group was changed.'
        }

        $created = Invoke-AzJson @(
            'group', 'create', '--subscription', $approvedSubscription,
            '--name', $approvedResourceGroup, '--location', $approvedLocation,
            '--tags', 'application=ghrunners', 'environment=spike', 'workload=gh-runners',
            'owner=jonathan-vella', 'costcenter=platform-engineering',
            'tech-contact=jonathan-vella', 'technical-contact=jonathan-vella',
            'sla=development', 'backup-policy=none', 'maint-window=none'
        )
        if ($created.id -cne "/subscriptions/$approvedSubscription/resourceGroups/$approvedResourceGroup") {
            throw 'Azure did not create the exact approved issue-7 resource group.'
        }
        [void](Get-TaggedResourceGroup)

        $script:runSuffix = ([Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(4))).ToLowerInvariant()
        $secretBytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        $secret = [Convert]::ToBase64String($secretBytes)
        $script:secretDigest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($secret))).ToLowerInvariant()
        $parameterFile = Join-Path ([System.IO.Path]::GetTempPath()) "issue7-$([guid]::NewGuid().ToString('N')).parameters.json"
        try {
            Set-PrivateParametersFile -Path $parameterFile -Secret $secret
            Invoke-InfrastructureDeployment -ParameterFile $parameterFile
        } finally {
            [Array]::Clear($secretBytes, 0, $secretBytes.Length)
            $secret = $null
            if (Test-Path -LiteralPath $parameterFile) {
                Remove-Item -LiteralPath $parameterFile -Force
            }
        }
        if ($Profile -ceq 'D4') {
            Write-Output 'Managed-environment deployment completed with the requested D4 profile (minimumCount=0, maximumCount=3, zoneRedundant=false); this does not establish D4 node allocation or job execution.'
        } else {
            Write-Output 'Managed-environment deployment completed with the requested Consumption profile; secret material and deployment output were not printed.'
        }
    }

    'Test' {
        Assert-ProfileAuthorization
        if (-not $EvidencePath) {
            throw 'Test requires an explicit -EvidencePath for sanitized per-leg JSON evidence.'
        }
        $evidenceFile = [System.IO.Path]::GetFullPath($EvidencePath)
        $records = [System.Collections.Generic.List[object]]::new()
        $script:testDeadline = $script:actionDeadline
        [void](Get-TaggedResourceGroup)
        $deployment = Invoke-AzJson @(
            'deployment', 'group', 'show', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--name', 'issue7-spike'
        )
        if ($deployment.properties.provisioningState -cne 'Succeeded') {
            throw 'The tagged issue-7 deployment is not in Succeeded state.'
        }
        $outputs = $deployment.properties.outputs
        $vaultName = [string]$outputs.keyVaultName.value
        $script:runSuffix = $vaultName.Substring(6)
        $environmentName = [string]$outputs.containerAppsEnvironmentName.value
        $identityName = [string]$outputs.testIdentityName.value
        $probeDigest = [string]$outputs.probeDigest.value
        $deployedProfileName = [string]$outputs.workloadProfileName.value
        if ($vaultName -notmatch '^kvghr7[a-f0-9]{8}$' -or
            $environmentName -notmatch '^cae-ghr7-[a-f0-9]{8}$' -or
            $identityName -notmatch '^mi-ghr7-[a-f0-9]{8}$' -or
            $probeDigest -notmatch '^[a-f0-9]{64}$' -or
            $deployedProfileName -cne $Profile) {
            throw 'Deployment outputs do not match the issue-7 resource naming contract.'
        }

        $vault = Get-ResourceGroupResource -Name $vaultName
        $environment = Get-ResourceGroupResource -Name $environmentName
        $identity = Get-ResourceGroupResource -Name $identityName
        $environmentState = Invoke-AzJson @(
            'containerapp', 'env', 'show', '--subscription', $approvedSubscription,
            '--resource-group', $approvedResourceGroup, '--name', $environmentName
        )
        $actualProfile = Assert-EnvironmentProfile -EnvironmentState $environmentState -ExpectedProfile $Profile
        $script:profileReadback = [pscustomobject]@{
            EnvironmentProvisioningState = [string]$environmentState.properties.provisioningState
            WorkloadProfileName = [string]$actualProfile.name
            WorkloadProfileType = [string]$actualProfile.workloadProfileType
            MinimumCount = [int]$actualProfile.minimumCount
            MaximumCount = [int]$actualProfile.maximumCount
            ZoneRedundant = $environmentState.properties.zoneRedundant
        }
        $zonePinningReadback = if ($Profile -ceq 'D4') { 'none' } else { 'not-applicable' }
        Write-Output "Environment profile readback: name=$($script:profileReadback.WorkloadProfileName); type=$($script:profileReadback.WorkloadProfileType); minimumCount=$($script:profileReadback.MinimumCount); maximumCount=$($script:profileReadback.MaximumCount); zoneRedundant=$($script:profileReadback.ZoneRedundant); zonePinning=$zonePinningReadback."

        $vaultState = Invoke-AzJson @(
            'resource', 'show', '--subscription', $approvedSubscription, '--ids', $vault.id
        )
        if ($vaultState.properties.publicNetworkAccess -cne 'Disabled' -or
            $vaultState.properties.networkAcls.defaultAction -cne 'Deny' -or
            $vaultState.properties.networkAcls.bypass -cne 'None') {
            throw 'Key Vault must remain public-disabled, default-deny, and bypass=None before the comparison.'
        }

        $evidenceStream = [System.IO.File]::Open(
            $evidenceFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write
        )
        $evidenceStream.Dispose()
        $comparison = Invoke-SpikeBypassComparison `
            -SetBypass {
                param($bypass)
                Set-KeyVaultBypass -VaultId $vault.id -Bypass $bypass
            } `
            -RunCase {
                param($bypass)
                Invoke-DiagnosticCase -Bypass $bypass `
                    -EnvironmentId $environment.id -IdentityId $identity.id `
                    -KeyVaultSecretUrl "$($vaultState.properties.vaultUri)secrets/probe" `
                    -ProbeDigest $probeDigest
            } `
            -RecordResult {
                param($bypass, $result)
                Write-SpikeComparisonEvidence -Path $evidenceFile -Records $records -Bypass $bypass -Result $result
            }
        Write-Output "Comparison summary: None=$($comparison.None); AzureServices=$($comparison.AzureServices)."
    }

    'Diagnose' {
        Write-Output "Issue-7 deployment diagnostic state: $(Get-SpikeDeploymentState)."
    }

    'Cleanup' {
        $group = Get-OptionalTaggedResourceGroup
        if (-not $group) {
            Write-Output 'The explicitly scoped issue-7 resource group is already absent; cleanup is complete.'
            return
        }
        do {
            $state = Get-SpikeDeploymentState
            if ($state -ceq 'ResourceGroupAbsent') {
                Write-Output 'The explicitly scoped issue-7 resource group is already absent; cleanup is complete.'
                return
            }
            if ($state -cne 'NonTerminal') { break }
            Start-Sleep -Seconds ([Math]::Min($pollSeconds, (Get-RemainingActionSeconds)))
        } while ($true)
        # A timed-out client does not establish that ARM has stopped.
        $deleteResult = Invoke-AzProcess -Arguments @(
            'group', 'delete', '--subscription', $approvedSubscription, '--name', $approvedResourceGroup,
            '--yes', '--no-wait', '--output', 'none'
        )
        if ($deleteResult.ExitCode -ne 0) {
            throw 'Azure did not accept deletion of the explicitly owned issue-7 resource group.'
        }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Seconds ([Math]::Min($pollSeconds, (Get-RemainingActionSeconds)))
            if (-not (Get-ResourceGroupExists)) {
                Write-Output 'The explicitly owned issue-7 resource group is absent.'
                return
            }
        } while ($timer.Elapsed -lt [TimeSpan]::FromMinutes($TimeoutMinutes))
        throw 'Issue-7 resource-group deletion exceeded the bounded cleanup wait.'
    }
}
