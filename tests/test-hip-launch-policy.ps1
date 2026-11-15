# No GPU / model required. Explicit regression against vacuous PASSes
# when Windows app-control policy prevents an executable from launching.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hip-launch-policy.ps1')

function Assert-Blocked($test, $session, $expected) {
    $actual = Get-HipExternalLaunchBlock -Session $session
    if ($expected -and [string]::IsNullOrWhiteSpace($actual)) {
        throw "${test}: expected external execution block; got none"
    }
    if (-not $expected -and -not [string]::IsNullOrWhiteSpace($actual)) {
        throw "${test}: incorrectly classified real loader/engine failure as policy block: $actual"
    }
    Write-Host "[PASS] $test"
}
function Session([bool]$healthy,[bool]$exited,[int]$exitCode,[string]$log) {
    return [pscustomobject]@{
        Healthy = $healthy
        Process = [pscustomobject]@{ HasExited = $exited; ExitCode = $exitCode }
        Log = $log
    }
}

Assert-Blocked 'Code Integrity-associated exit 4551' (Session $false $true 4551 '') $true
Assert-Blocked 'explicit WDAC log message' (Session $false $true 1 'Code Integrity blocked by security policy') $true
Assert-Blocked 'Smart App Control log message' (Session $false $true 1 'Smart App Control prevented this file') $true
Assert-Blocked 'healthy base ignores stale policy log' (Session $true $false 0 'Smart App Control') $false
Assert-Blocked 'running process is not a confirmed block' (Session $false $false 0 'Code Integrity') $false
Assert-Blocked 'genuine missing DLL exit 126 is not SAC' (Session $false $true 126 'The specified module could not be found') $false
Assert-Blocked 'genuine unknown ROCm device rejection' (Session $false $true 1 'unknown device ROCm9') $false
Assert-Blocked 'rocBLAS missing kernel (real engine error)' (Session $false $true 1 'rocBLAS error for GPU arch gfx1100') $false
Assert-Blocked 'ordinary failed startup is not policy block' (Session $false $true 1 '') $false

# Harness policy: isolated negative outcomes must never be PASS until an
# intact engine has become healthy. The policy logic itself is audited
# without installing ROCm or launching a real process.
$harness = Get-Content -Raw (Join-Path $PSScriptRoot 'test-hip-windows.ps1')
foreach ($required in @(
    'if ($mainPrerequisiteStatus -ne',
    'Get-HipExternalLaunchBlock -Session $neg',
    'Get-HipExternalLaunchBlock -Session $wrongDevice',
    'intact engine prerequisite is'
)) {
    if (-not $harness.Contains($required)) { throw "Harness prerequisite/block guard missing: $required" }
}
Write-Host '[PASS] negative harness prerequisite and block guards are present'
exit 0
