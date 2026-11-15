# Pure classification helpers for Windows HIP engine launch tests.
# A process failing to execute under Windows policy does not demonstrate
# that a missing ROCm DLL or kernel was correctly rejected by the engine.
# Policy events need corroboration from Windows Code Integrity event XML.
function Get-HipExternalLaunchBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session)

    if ($Session.Healthy -or $null -eq $Session.Process -or -not $Session.Process.HasExited) {
        return $null
    }
    $log = [string]$Session.Log
    $exitCode = [int]$Session.Process.ExitCode

    # 4551 observed with Code Integrity event IDs 3077/3033/3118 on the
    # RX 7900 XTX host. It suggests an external execution block, NOT proof
    # that Smart App Control Evaluation mode (rather than another WDAC
    # policy) is the enforcing policy. Capture the event XML separately.
    if ($exitCode -eq 4551) {
        return "Windows execution-policy block suspected (exit 4551); check Code Integrity event XML/policy ID"
    }
    if ($log -match '(?i)Smart App Control|App Control for Business|Code Integrity|Device Guard|WDAC|blocked by (an? )?(application control|security|execution) policy|blocked by your (administrator|organization)') {
        return 'Windows execution-policy block suspected from process log; check Code Integrity event XML/policy ID'
    }
    # Exit 126/ERROR_MOD_NOT_FOUND alone can be a genuinely missing DLL:
    # never treat a generic loader or nonzero exit code as a policy block.
    return $null
}
