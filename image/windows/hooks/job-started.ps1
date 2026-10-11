# Windows pre-job policy hook (ACTIONS_RUNNER_HOOK_JOB_STARTED); port of image/pre-job-policy.py.
#
# The runner dot-sources .ps1 hooks, so this file must run its checks unconditionally and report
# the verdict through the exit code. Any unexpected error rejects the job (fail closed).
# Policy values, payload contents and raw untrusted values are never written to the output.
#
# Differences from the Linux hook:
#   - the policy is read from a file written at boot by start-runner.ps1 (GHR_POLICY_PATH, default below);
#   - pull_request is also accepted for public consumers (ADR-0007 scoped exception). The registry
#     validator only emits it for an acknowledged entry, and this hook then accepts only an open,
#     same-repository, non-fork pull request, exactly as for private consumers.
# pull_request_target and workflow_run are never in the allowed event set.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class PolicyRejection : System.Exception {
    PolicyRejection([string]$Message) : base($Message) {}
}

$script:DefaultPolicyPath = 'C:\ghr\policy.json'
$script:AllowedEvents = @('push', 'schedule', 'workflow_dispatch', 'pull_request')
$script:PolicyKeys = @('allowedEvents', 'allowedRefs', 'allowedWorkflows', 'repository', 'visibility')
$script:RepositoryPattern = '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z'
$script:WorkflowPattern = '\A([^/]+/[^/]+)/\.github/workflows/([^/@\s\\]+\.(?i:ya?ml))@(refs/.+)\z'
$script:ControlPattern = '[\x00-\x20\x7f]'

function Assert-Policy {
    param($Condition, [string]$Reason)
    if (-not $Condition) {
        throw [PolicyRejection]::new($Reason)
    }
}

function Test-Dict {
    param($Value)
    return ($Value -is [System.Collections.Generic.Dictionary[string, object]])
}

function Get-Field {
    param($Object, [string]$Name)
    if ((Test-Dict $Object) -and $Object.ContainsKey($Name)) {
        return , $Object[$Name]
    }
    else {
        $null
    }
}

function ConvertTo-StrictValue {
    param([System.Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $map = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                Assert-Policy (-not $map.ContainsKey($property.Name)) 'duplicate JSON key'
                $map[$property.Name] = ConvertTo-StrictValue $property.Value
            }
            return , $map
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $list.Add((ConvertTo-StrictValue $item))
            }
            return , $list
        }
        'String' { $Element.GetString() }
        'Number' {
            $integer = 0L
            if ($Element.TryGetInt64([ref]$integer)) { $integer } else { $Element.GetDouble() }
        }
        'True' { $true }
        'False' { $false }
        default { $null }
    }
}

function ConvertFrom-StrictJson {
    param([string]$Text)
    $document = [System.Text.Json.JsonDocument]::Parse($Text)
    try {
        ConvertTo-StrictValue $document.RootElement
    }
    finally {
        $document.Dispose()
    }
}

function Read-BoundedFile {
    param([string]$Path, [int]$MaxBytes, [string]$MissingReason, [string]$OversizedReason)
    Assert-Policy (-not [string]::IsNullOrEmpty($Path)) $MissingReason
    Assert-Policy (Test-Path -LiteralPath $Path -PathType Leaf) $MissingReason
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new($MaxBytes + 1)
        $total = 0
        while ($total -lt $buffer.Length) {
            $read = $stream.Read($buffer, $total, $buffer.Length - $total)
            if ($read -eq 0) { break }
            $total += $read
        }
    }
    finally {
        $stream.Dispose()
    }
    Assert-Policy ($total -gt 0 -and $total -le $MaxBytes) $OversizedReason
    return [System.Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $total)
}

function Get-GitPath {
    if ($IsWindows) {
        $candidate = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
}

function Test-GitBranchRef {
    param([string]$Ref)
    & (Get-GitPath) check-ref-format $Ref *> $null
    return ($LASTEXITCODE -eq 0)
}

function Assert-BranchRef {
    param($Value)
    Assert-Policy (($Value -is [string]) -and $Value.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) 'invalid branch ref'
    Assert-Policy (Test-GitBranchRef $Value) 'invalid branch ref'
    return $Value
}

function Get-WorkflowParts {
    param($Value)
    Assert-Policy (($Value -is [string]) -and -not [regex]::IsMatch($Value, $script:ControlPattern)) 'invalid workflow ref'
    $match = [regex]::Match($Value, $script:WorkflowPattern)
    Assert-Policy $match.Success 'invalid workflow ref'
    return @($match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
}

function Assert-Allowlist {
    param($Values)
    Assert-Policy (($Values -is [System.Collections.Generic.List[object]]) -and $Values.Count -gt 0) 'invalid policy allowlist'
    foreach ($value in $Values) {
        Assert-Policy (($value -is [string]) -and $value.Length -gt 0) 'invalid policy allowlist'
    }
    $unique = [System.Collections.Generic.HashSet[string]]::new([string[]]$Values, [System.StringComparer]::Ordinal)
    Assert-Policy ($unique.Count -eq $Values.Count) 'duplicate policy allowlist entry'
}

function Get-JobContext {
    $context = @{}
    foreach ($key in 'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_WORKFLOW_REF') {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        Assert-Policy ((-not [string]::IsNullOrEmpty($value)) -and -not [regex]::IsMatch($value, $script:ControlPattern)) 'missing or invalid job context'
        $context[$key] = $value
    }
    return $context
}

function Test-SameText {
    param($Left, $Right)
    return (($Left -is [string]) -and ($Right -is [string]) -and [string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-WorkflowKey {
    param([string]$Repository, [string]$File, [string]$Ref)
    return ($Repository.ToLowerInvariant(), $File, $Ref) -join "`0"
}

function Invoke-PolicyCheck {
    $policyPath = $env:GHR_POLICY_PATH
    if ([string]::IsNullOrEmpty($policyPath)) {
        $policyPath = $script:DefaultPolicyPath
    }
    $raw = Read-BoundedFile $policyPath 65536 'missing or oversized consumer policy' 'missing or oversized consumer policy'
    $policy = ConvertFrom-StrictJson $raw
    Assert-Policy ((Test-Dict $policy) -and $policy.Count -eq $script:PolicyKeys.Count) 'invalid consumer policy fields'
    foreach ($key in $script:PolicyKeys) {
        Assert-Policy $policy.ContainsKey($key) 'invalid consumer policy fields'
    }

    $repo = $policy['repository']
    Assert-Policy (($repo -is [string]) -and [regex]::IsMatch($repo, $script:RepositoryPattern)) 'invalid policy repository'
    $visibility = $policy['visibility']
    Assert-Policy (($visibility -is [string]) -and ($visibility -ceq 'public' -or $visibility -ceq 'private')) 'invalid policy visibility'
    foreach ($key in 'allowedEvents', 'allowedRefs', 'allowedWorkflows') {
        Assert-Allowlist $policy[$key]
    }
    foreach ($candidate in $policy['allowedEvents']) {
        Assert-Policy ($script:AllowedEvents -ccontains $candidate) 'policy violates event floor'
    }
    $refs = $policy['allowedRefs']
    foreach ($ref in $refs) {
        [void](Assert-BranchRef $ref)
    }
    # The registry validator verifies this sole public ref against GitHub's default branch.
    Assert-Policy (($visibility -cne 'public') -or $refs.Count -eq 1) 'public policy requires one default ref'
    $workflows = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($workflow in $policy['allowedWorkflows']) {
        $parts = Get-WorkflowParts $workflow
        Assert-Policy ((Test-SameText $parts[0] $repo) -and ($refs -ccontains $parts[2])) 'policy workflow outside repository or refs'
        [void](Assert-BranchRef $parts[2])
        [void]$workflows.Add((Get-WorkflowKey $parts[0] $parts[1] $parts[2]))
    }

    $context = Get-JobContext
    Assert-Policy (Test-SameText $context['GITHUB_REPOSITORY'] $repo) 'repository outside policy'
    $eventName = $context['GITHUB_EVENT_NAME']
    Assert-Policy ($policy['allowedEvents'] -ccontains $eventName) 'event outside policy'
    $jobRef = $context['GITHUB_REF']
    $jobWorkflow = Get-WorkflowParts $context['GITHUB_WORKFLOW_REF']
    $workflowFile = $jobWorkflow[1]
    $workflowRef = $jobWorkflow[2]
    Assert-Policy (Test-SameText $jobWorkflow[0] $repo) 'workflow repository outside policy'

    if ($eventName -ceq 'pull_request') {
        # Fork-ness is taken from the event payload, never inferred from GITHUB_REF.
        $payloadText = Read-BoundedFile $env:GITHUB_EVENT_PATH 1048576 'missing pull request payload' 'oversized pull request payload'
        $payload = ConvertFrom-StrictJson $payloadText
        Assert-Policy (Test-Dict $payload) 'invalid pull request payload'
        $pr = Get-Field $payload 'pull_request'
        Assert-Policy ((Test-Dict $pr) -and ((Get-Field $pr 'state') -ceq 'open')) 'pull request is not open'
        $number = Get-Field $payload 'number'
        $prNumber = Get-Field $pr 'number'
        Assert-Policy (($number -is [long]) -and $number -gt 0 -and ($prNumber -is [long]) -and $prNumber -eq $number) 'invalid pull request number'
        $expectedRef = 'refs/pull/{0}/merge' -f $number
        Assert-Policy (($jobRef -ceq $expectedRef) -and ($workflowRef -ceq $expectedRef)) 'pull request job or workflow is not its merge ref'
        $base = Get-Field $pr 'base'
        $head = Get-Field $pr 'head'
        $expectedPrivate = ($visibility -ceq 'private')
        foreach ($repository in @((Get-Field $payload 'repository'), (Get-Field $base 'repo'), (Get-Field $head 'repo'))) {
            $isPrivate = Get-Field $repository 'private'
            $isFork = Get-Field $repository 'fork'
            Assert-Policy ((Test-Dict $repository) -and (Test-SameText (Get-Field $repository 'full_name') $repo) -and
                ($isPrivate -is [bool]) -and ($isPrivate -eq $expectedPrivate) -and
                ($isFork -is [bool]) -and ($isFork -eq $false)) 'pull request repository mismatch or fork'
        }
        $baseName = Get-Field $base 'ref'
        $headName = Get-Field $head 'ref'
        Assert-Policy (($baseName -is [string]) -and ($headName -is [string])) 'missing pull request branches'
        $baseRef = Assert-BranchRef ('refs/heads/' + $baseName)
        [void](Assert-BranchRef ('refs/heads/' + $headName))
        Assert-Policy (($env:GITHUB_BASE_REF -ceq $baseName) -and ($env:GITHUB_HEAD_REF -ceq $headName)) 'pull request branch context mismatch'
        Assert-Policy ($refs -ccontains $baseRef) 'pull request base outside policy'
        # PR workflows run from the merge ref, not from the allowlisted base branch ref.
        $authorized = Get-WorkflowKey $repo $workflowFile $baseRef
    }
    else {
        Assert-Policy ($refs -ccontains $jobRef) 'job ref outside policy'
        Assert-Policy ($workflowRef -ceq $jobRef) 'workflow ref differs from job ref'
        $authorized = Get-WorkflowKey $repo $workflowFile $workflowRef
    }
    Assert-Policy ($workflows.Contains($authorized)) 'workflow outside policy'
}

try {
    Invoke-PolicyCheck
}
catch [PolicyRejection] {
    [Console]::Error.WriteLine("::error::Consumer policy rejected job: $($_.Exception.Message).")
    exit 1
}
catch {
    [Console]::Error.WriteLine('::error::Consumer policy rejected job: invalid policy or event metadata.')
    exit 1
}
Write-Output 'Consumer policy accepted job.'
exit 0
