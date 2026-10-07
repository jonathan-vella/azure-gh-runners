[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deploy', 'Test', 'Cleanup', 'Validate')]
    [string] $Action,

    [string] $SubscriptionId,

    [string] $ResourceGroupName = 'rg-ghrunners-spike7-swc',

    [ValidateRange(1, 45)]
    [int] $TimeoutMinutes = 45,

    [switch] $ConfirmCapacityRecovered
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
Import-Module (Join-Path $PSScriptRoot 'Comparison.psm1') -Force

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = & az @Arguments --only-show-errors --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI command failed; no command output was emitted.'
    }
    if (-not $result) {
        return $null
    }
    return ($result -join "`n" | ConvertFrom-Json)
}

function Invoke-AzBounded {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 2700)][int] $TimeoutSeconds = ($TimeoutMinutes * 60)
    )

    $azCommand = Get-Command az -CommandType Application -ErrorAction Stop
    $pythonPath = (Resolve-Path (Join-Path (Split-Path $azCommand.Source) '..\python.exe')).Path
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-IBm', 'azure.cli') + $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Could not start the bounded Azure CLI deployment process.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timeoutMilliseconds = $TimeoutSeconds * 1000
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Azure CLI exceeded the configured deployment timeout. The ARM deployment may still be active; do not retry until its state is checked.'
    }
    $null = $stdoutTask.GetAwaiter().GetResult()
    $null = $stderrTask.GetAwaiter().GetResult()
    return $process.ExitCode
}

function Get-RemainingTestSeconds {
    $remaining = [int][Math]::Floor(($script:testDeadline - [DateTimeOffset]::UtcNow).TotalSeconds)
    if ($remaining -lt 1) {
        throw 'The bounded comparison time budget expired.'
    }
    return $remaining
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

function Assert-CapacityGate {
    if (-not $ConfirmCapacityRecovered) {
        throw 'No deployment or job run is allowed until capacity recovery is explicitly confirmed.'
    }
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

    $null = & az resource update --subscription $approvedSubscription --ids $VaultId `
        --set "properties.networkAcls.bypass=$Bypass" --only-show-errors --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
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
    $exitCode = Invoke-AzBounded @(
        'deployment', 'group', 'create', '--subscription', $approvedSubscription,
        '--resource-group', $approvedResourceGroup, '--name', $deploymentName,
        '--template-file', $jobTemplatePath,
        '--parameters', "jobName=$jobName", "location=$approvedLocation",
        "environmentResourceId=$EnvironmentId", "identityResourceId=$IdentityId",
        "keyVaultSecretUrl=$KeyVaultSecretUrl", "probeDigest=$ProbeDigest",
        '--only-show-errors', '--output', 'none'
    ) -TimeoutSeconds (Get-RemainingTestSeconds)
    if ($exitCode -ne 0) {
        $deploymentState = & az deployment group show --subscription $approvedSubscription `
            --resource-group $approvedResourceGroup --name $deploymentName `
            --query 'properties.error.code' --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $deploymentState -match '^[A-Za-z0-9._-]+$') {
            throw "Fresh diagnostic job deployment failed with Azure error code: $deploymentState."
        }
        throw 'Fresh diagnostic job deployment failed; no deployment output was emitted.'
    }
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

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        if ($script:testDeadline -and [DateTimeOffset]::UtcNow -ge $script:testDeadline) {
            throw 'The bounded comparison time budget expired while awaiting the ACA execution.'
        }
        Start-Sleep -Seconds $pollSeconds
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
Assert-ApprovedScope

switch ($Action) {
    'Deploy' {
        Assert-CapacityGate
        if ($env:OS -ne 'Windows_NT') {
            throw 'Secure temporary parameter files require Windows ACLs; run this script on Windows.'
        }
        $exists = & az group exists --subscription $approvedSubscription --name $approvedResourceGroup --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or $exists -cne 'false') {
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
            $deploymentExitCode = Invoke-AzBounded @(
                'deployment', 'group', 'create', '--subscription', $approvedSubscription,
                '--resource-group', $approvedResourceGroup, '--name', 'issue7-spike',
                '--template-file', $templatePath, '--parameters', "@$parameterFile",
                '--only-show-errors', '--output', 'none'
            )
            if ($deploymentExitCode -ne 0) {
                $deploymentState = & az deployment group show --subscription $approvedSubscription `
                    --resource-group $approvedResourceGroup --name 'issue7-spike' `
                    --query 'properties.error.code' --output tsv 2>$null
                if ($LASTEXITCODE -eq 0 -and $deploymentState -match '^[A-Za-z0-9._-]+$') {
                    throw "Deployment failed with Azure error code: $deploymentState. The owned resource group was retained for explicit cleanup."
                }
                throw 'Deployment failed. The owned resource group was retained for explicit cleanup.'
            }
        } finally {
            [Array]::Clear($secretBytes, 0, $secretBytes.Length)
            $secret = $null
            if (Test-Path -LiteralPath $parameterFile) {
                Remove-Item -LiteralPath $parameterFile -Force
            }
        }
        Write-Output 'Deployment completed; secret material and deployment output were not printed.'
    }

    'Test' {
        Assert-CapacityGate
        $script:testDeadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
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
        if ($vaultName -notmatch '^kvghr7[a-f0-9]{8}$' -or
            $environmentName -notmatch '^cae-ghr7-[a-f0-9]{8}$' -or
            $identityName -notmatch '^mi-ghr7-[a-f0-9]{8}$' -or
            $probeDigest -notmatch '^[a-f0-9]{64}$') {
            throw 'Deployment outputs do not match the issue-7 resource naming contract.'
        }

        $vault = Get-ResourceGroupResource -Name $vaultName
        $environment = Get-ResourceGroupResource -Name $environmentName
        $identity = Get-ResourceGroupResource -Name $identityName
        $vaultState = Invoke-AzJson @(
            'resource', 'show', '--subscription', $approvedSubscription, '--ids', $vault.id
        )
        if ($vaultState.properties.publicNetworkAccess -cne 'Disabled' -or
            $vaultState.properties.networkAcls.defaultAction -cne 'Deny' -or
            $vaultState.properties.networkAcls.bypass -cne 'None') {
            throw 'Key Vault must remain public-disabled, default-deny, and bypass=None before the comparison.'
        }

        $comparison = Invoke-SpikeBypassComparison `
            -SetBypass {
                param($bypass)
                Set-KeyVaultBypass -VaultId $vault.id -Bypass $bypass
            } `
            -RunCase {
                param($bypass)
                $jobName = New-FreshDiagnosticJob -Bypass $bypass `
                    -EnvironmentId $environment.id -IdentityId $identity.id `
                    -KeyVaultSecretUrl "$($vaultState.properties.vaultUri)secrets/probe" `
                    -ProbeDigest $probeDigest
                Invoke-JobAndWait -JobName $jobName
            }
        Write-Output "Comparison summary: None=$($comparison.None); AzureServices=$($comparison.AzureServices)."
    }

    'Cleanup' {
        [void](Get-TaggedResourceGroup)
        $null = & az group delete --subscription $approvedSubscription --name $approvedResourceGroup `
            --yes --no-wait --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure did not accept deletion of the explicitly owned issue-7 resource group.'
        }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Seconds $pollSeconds
            $exists = & az group exists --subscription $approvedSubscription --name $approvedResourceGroup --output tsv 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not verify issue-7 resource-group cleanup.'
            }
            if ($exists -ceq 'false') {
                Write-Output 'The explicitly owned issue-7 resource group is absent.'
                return
            }
        } while ($timer.Elapsed -lt [TimeSpan]::FromMinutes($TimeoutMinutes))
        throw 'Issue-7 resource-group deletion exceeded the bounded cleanup wait.'
    }
}
