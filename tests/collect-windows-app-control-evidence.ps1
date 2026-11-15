<#
.SYNOPSIS
  Read-only Windows Code Integrity / App Control diagnosis for HIP startup.
.DESCRIPTION
  Captures active policy output and correlated Code Integrity events.
  Does NOT change policies, SAC, registry, EFI, or drivers.
  Raw XML may contain personal paths; review and redact before sharing.
.EXAMPLE
  pwsh -File .\tests\collect-windows-app-control-evidence.ps1 -Hours 12 -OutputDirectory C:\dev\yue2-hip-nightly\qa\codeintegrity
#>
[CmdletBinding()]
param(
    [ValidateRange(1,168)][int]$Hours = 24,
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'qa\codeintegrity'),
    [string]$ImagePattern = 'yue-server\.exe|ggml[-_.a-zA-Z0-9]*\.dll'
)
$ErrorActionPreference = 'Stop'
$dir = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$ciTool = Get-Command 'citool.exe' -ErrorAction SilentlyContinue
$policyLines = New-Object System.Collections.Generic.List[string]
if ($ciTool) {
    $policyText = (& $ciTool.Source -lp 2>&1 | Out-String)
    $policyLines.Add($policyText)
    if ($policyText -match '0x80070005|denied|拒绝') {
        $policyLines.Add('CiTool.exe -lp was denied (needs elevation); read-only fallback inventory follows.')
    }
} else {
    $policyLines.Add('CiTool.exe unavailable on PATH; read-only fallback inventory follows.')
}
# Read-only fallback inventory (works without elevation) so the report never
# depends solely on citool: active policy binaries, policy-load events, SAC state.
try {
    $policyLines.Add('')
    $policyLines.Add('== Active policy binaries (CiPolicies\Active, read-only listing) ==')
    Get-ChildItem -LiteralPath "$env:SystemRoot\System32\CodeIntegrity\CiPolicies\Active" -ErrorAction Stop |
        ForEach-Object { $policyLines.Add(('{0}  {1} bytes  {2}' -f $_.Name, $_.Length, $_.LastWriteTime.ToString('o'))) }
} catch { $policyLines.Add('CiPolicies\Active listing failed: ' + $_.Exception.Message) }
try {
    $policyLines.Add('')
    $policyLines.Add('== Policy-load events 3099/3096 last 7 days (empty = no WDAC policy loads logged) ==')
    $pl = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = @(3099, 3096); StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue)
    foreach ($e in $pl) {
        $pairs = ([regex]::Matches($e.ToXml(), "<Data Name='([^']+)'>([^<]*)</Data>") | ForEach-Object { '{0}={1}' -f $_.Groups[1].Value, $_.Groups[2].Value }) -join ' | '
        $policyLines.Add(('{0} id={1} {2}' -f $e.TimeCreated.ToUniversalTime().ToString('o'), $e.Id, $pairs))
    }
    if (-not $pl) { $policyLines.Add('(no 3099/3096 events in window)') }
} catch { $policyLines.Add('3099/3096 query failed: ' + $_.Exception.Message) }
$policyLines | Set-Content -LiteralPath (Join-Path $dir 'active-policy-list.txt') -Encoding UTF8

# Smart App Control feature state (read-only registry value; 0=off 1=evaluation 2=on).
$sacState = try { (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { 'unreadable: ' + $_.Exception.Message }
('VerifiedAndReputablePolicyState = {0} (0=off, 1=evaluation, 2=on)' -f $sacState) |
    Set-Content -LiteralPath (Join-Path $dir 'sac-state.txt') -Encoding UTF8

$logName = 'Microsoft-Windows-CodeIntegrity/Operational'
# 3076 = audit would-block; 3077 = enforcement block; 3089 = signer
# correlation; 3033 may occur without App Control; 3099 = policy loaded.
$ids = @(3033,3034,3076,3077,3089,3099,3118)
$since = (Get-Date).AddHours(-$Hours)
try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = $logName
        StartTime = $since
        Id = $ids
    } -MaxEvents 5000 -ErrorAction Stop)
} catch {
    throw "Unable to read ${logName}: $($_.Exception.Message). No security policy changed."
}

$targetIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$targetRecords = [System.Collections.Generic.HashSet[long]]::new()
foreach ($event in $events) {
    $xml = $event.ToXml()
    if (([string]$event.Message) -match $ImagePattern -or $xml -match $ImagePattern) {
        [void]$targetRecords.Add([long]$event.RecordId)
        try {
            [xml]$doc = $xml
            $activity = [string]$doc.Event.System.Correlation.ActivityID
            if ($activity) { [void]$targetIds.Add($activity) }
        } catch { }
    }
}
$xmlFolder = Join-Path $dir 'local-raw-xml'
New-Item -ItemType Directory -Force -Path $xmlFolder | Out-Null
$records = @($events | Sort-Object TimeCreated | ForEach-Object {
    $event = $_
    [xml]$doc = $event.ToXml()
    $activity = [string]$doc.Event.System.Correlation.ActivityID
    $direct = $targetRecords.Contains([long]$event.RecordId)
    $correlated = $activity -and $targetIds.Contains($activity) -and $event.Id -in @(3033,3034,3089,3076,3077)
    if ($direct -or $correlated) {
        $file = Join-Path $xmlFolder ("event-$($event.RecordId)-$($event.Id).xml")
        [System.IO.File]::WriteAllText($file, $event.ToXml(), [System.Text.UTF8Encoding]::new($false))
        [pscustomobject]@{
            event_id = [int]$event.Id
            time_utc = $event.TimeCreated.ToUniversalTime().ToString('o')
            activity_id = $activity
            record_id = [long]$event.RecordId
            classification = switch ($event.Id) {
                3076 { 'AUDIT_ONLY' }
                3077 { 'ENFORCED_BLOCK' }
                3033 { 'SIGNING_OR_CIG_ERROR_REQUIRES_CORRELATION' }
                3089 { 'SIGNER_DETAILS_CORRELATED' }
                3099 { 'POLICY_LOADED' }
                default { 'CONTEXT' }
            }
            local_xml_file = [IO.Path]::GetFileName($file)
        }
    }
})
$summary = [pscustomobject]@{
    captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    start_time_utc = $since.ToUniversalTime().ToString('o')
    target_pattern = $ImagePattern
    events_scanned = $events.Count
    matching_or_correlated = $records.Count
    events = $records
    policy_list_file = 'active-policy-list.txt'
    note = '3077 indicates an enforcing policy. The name SAC Evaluation is not sufficient to identify the blocker; compare PolicyId with CiTool. Raw XML is local-only and can include personal paths.'
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'event-summary.json') -Encoding UTF8
Write-Host "Collected $($records.Count) matching/correlated Code Integrity events under $dir."
Write-Host 'READ-ONLY. Review local raw XML and policy list for private paths before sharing.'
if ($records.Count -eq 0) { Write-Warning 'No matching event does not prove the absence of an active execution policy.' }
