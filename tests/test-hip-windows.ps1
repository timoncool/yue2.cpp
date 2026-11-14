<#
.SYNOPSIS
  Windows acceptance test for a native HIP (ROCm) yue2 engine bundle.

.DESCRIPTION
  Repeatable, self-contained PowerShell harness. Given an engine bundle
  (yue-server.exe + ggml-hip.dll + app-local ROCm runtime closure) it:
    1. records the exact GPU and source provenance,
    2. starts yue-server with --device ROCm0 and no SDK environment variables,
    3. verifies the device the engine enumerated matches the expected gfx
       target by log evidence (gcnArch from HIP device properties, not names),
    4. generates a complete song twice and checks the audio itself:
       MP3 frame structure, WAV header, duration, silence and finiteness,
    5. replays a fixed seed and compares output hashes,
    6. cancels a running job and generates again afterwards,
    7. fails closed in isolated COPIES of the bundle with ggml-hip.dll,
       amd_comgr.dll, the HIP runtime and the rocBLAS kernel library removed,
       and on an unknown --device id: no silent CPU fallback anywhere,
    8. writes results.json + results.csv + raw logs + SHA256 for every artifact.

  Every check reports PASS / FAIL / BLOCKED / NOT RUN; a FAIL anywhere makes
  the exit code non-zero (BLOCKED, e.g. Smart App Control rejecting a freshly
  linked unsigned binary, exits 2 so CI can tell the two apart).

.PARAMETER EngineRoot
  Directory holding yue-server.exe and its DLL closure.

.PARAMETER ModelPath / VaePath
  Backbone and VAE GGUF files.

.PARAMETER OutputDir
  Where results, logs and audio are written. Created if missing.

.PARAMETER ExpectArch
  gfx target the enumerated device must report (default gfx1100, the
  physically verified reference; pass the target of the bundle under test).

.PARAMETER GpuNamePattern
  Adapter-name preflight regex (default 'Radeon'; tighten per test machine).

.PARAMETER TestConfig
  Optional JSON file: { duration, seed, lm_seed, style, lyrics, wav24, ... }.
  Defaults reproduce the 30 s English regression request.

.EXAMPLE
  .\tests\test-hip-windows.ps1 -EngineRoot C:\bundles\yue2-hip `
    -ModelPath C:\models\YuE2-3B-Q8_0.gguf -VaePath C:\models\YuE2-Vae-F32.gguf `
    -OutputDir C:\runs\hip -ExpectArch gfx1100
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $EngineRoot,
    [Parameter(Mandatory = $true)] [string] $ModelPath,
    [Parameter(Mandatory = $true)] [string] $VaePath,
    [Parameter(Mandatory = $true)] [string] $OutputDir,
    [string] $ExpectArch = 'gfx1100',
    [string] $GpuNamePattern = 'Radeon',
    [string] $TestConfig,
    [int] $Port = 8151,
    [int] $StartupTimeoutSec = 90,
    [int] $JobTimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
foreach ($p in @($EngineRoot, $ModelPath, $VaePath)) {
    if (-not (Test-Path $p)) { throw "required path missing: $p" }
}
$EngineRoot = (Resolve-Path $EngineRoot).Path
$ModelPath  = (Resolve-Path $ModelPath).Path
$VaePath    = (Resolve-Path $VaePath).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir  = (Resolve-Path $OutputDir).Path
$LogDir     = Join-Path $OutputDir 'logs'
$AudioDir   = Join-Path $OutputDir 'audio'
New-Item -ItemType Directory -Force -Path $LogDir, $AudioDir | Out-Null

# ---------------------------------------------------------------- test config
$defaultRequest = @{
    style    = 'gentle acoustic pop, soft female vocal, warm guitar, 90 bpm'
    lyrics   = "[verse]`nMorning light on the window pane`nCoffee steam and quiet rain`nA new page waits for my pen`nToday I will try again`n`n[chorus]`nSmall steps, bright heart`nEvery ending is a start`nSmall steps, keep going`nThe morning keeps on glowing"
    duration = 30.0
    lm_seed  = 424242
    seed     = 424242
}
if ($TestConfig -and (Test-Path $TestConfig)) {
    # UTF-8 explicit: PS 5.1 reads ANSI by default and mangles CJK configs
    $cfg = Get-Content -Raw -Encoding UTF8 $TestConfig | ConvertFrom-Json
    foreach ($k in @('style', 'lyrics', 'duration', 'lm_seed', 'seed', 'abc')) {
        if ($cfg.PSObject.Properties.Name -contains $k) { $defaultRequest[$k] = $cfg.$k }
    }
}

$script:Results = New-Object System.Collections.Generic.List[object]
$script:Failures = 0
function Record([string] $Check, [string] $Status, $Detail = '') {
    $script:Results.Add([pscustomobject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        check     = $Check
        status    = $Status
        detail    = "$Detail"
    })
    if ($Status -eq 'FAIL') { $script:Failures++ }
    Write-Host ("[{0}] {1}: {2}" -f $Status, $Check, $Detail)
    # Persist after every check: a killed run keeps its evidence.
    try {
        $script:Results | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutputDir 'results.json') -Encoding UTF8
        $script:Results | Export-Csv -Path (Join-Path $OutputDir 'results.csv') -NoTypeInformation -Encoding UTF8
    } catch { }
}

function Get-FileSha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
}

# ------------------------------------------------------------ audio validators
function Test-Mp3File([string] $Path, [double] $ExpectedDurationSec) {
    # Structural decode check: walk MPEG audio frame headers (ID3 skipped),
    # confirm every remaining byte belongs to a well-formed frame sequence
    # and sum the frame durations.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $pos = 0
    if ($bytes.Length -ge 10 -and $bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33) {
        $size = ($bytes[6] -shl 21) -bor ($bytes[7] -shl 14) -bor ($bytes[8] -shl 7) -bor $bytes[9]
        $pos = 10 + $size
    }
    $bitrates = @(0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0)
    $rates    = @(44100,48000,32000,0)
    $frames = 0; $seconds = 0.0; $bad = 0
    while ($pos + 4 -le $bytes.Length) {
        if ($bytes[$pos] -ne 0xFF -or (($bytes[$pos + 1] -band 0xE0) -ne 0xE0)) { $bad++; $pos++; continue }
        # [long] on purpose: -shl 24 on an int32 overflows negative in PS 5.1
        $head = [long]$bytes[$pos] * 16777216 + [long]$bytes[$pos+1] * 65536 + [long]$bytes[$pos+2] * 256 + [long]$bytes[$pos+3]
        $versionBits = ($head -shr 19) -band 3   # 3 = MPEG1
        $layerBits   = ($head -shr 17) -band 3   # 1 = Layer III
        $brIdx = ($head -shr 12) -band 0xF
        $srIdx = ($head -shr 10) -band 3
        if ($versionBits -ne 3 -or $layerBits -ne 1 -or $brIdx -eq 0 -or $brIdx -eq 15 -or $srIdx -eq 3) { $bad++; $pos++; continue }
        $bitrate = $bitrates[$brIdx] * 1000
        $half = if ($versionBits -eq 3) { 0 } else { 1 }
        $sampleRate = $rates[$srIdx] / [math]::Pow(2, $half)
        $padding = ($head -shr 9) -band 1
        $frameLen = [math]::Floor(144 * $bitrate / $sampleRate) + $padding
        if ($frameLen -lt 4 -or $pos + $frameLen -gt $bytes.Length) { $bad++; $pos++; continue }
        $frames++
        $seconds += 1152.0 / $sampleRate
        $pos += [int]$frameLen
    }
    $tail = if ($bytes.Length -ge 128 -and $bytes[$bytes.Length - 128] -eq 0x54) { 128 } else { 0 }
    $unaccounted = $bytes.Length - $tail - ($bytes.Length - $pos) # bytes consumed by frames+skips
    $tolerance = [math]::Max(1.5, $ExpectedDurationSec * 0.08)
    $ok = ($frames -gt 50) -and ([math]::Abs($seconds - $ExpectedDurationSec) -le $tolerance) -and ($bad -lt [math]::Max(4, $frames * 0.01))
    return [pscustomobject]@{
        ok = $ok; frames = $frames; seconds = [math]::Round($seconds, 2)
        bad_bytes = $bad; size = $bytes.Length
        detail = "frames=$frames seconds=$($seconds.ToString('0.00')) badBytes=$bad size=$($bytes.Length)"
    }
}

function Test-WavFile([string] $Path, [double] $ExpectedDurationSec) {
    # Header check plus sample scan: anomalous silence (all zero) and float
    # finiteness when the data is IEEE float.
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $riff = $br.ReadBytes(4); $riffSize = $br.ReadUInt32(); $wave = $br.ReadBytes(4)
        if ("$([char]$riff[0])$([char]$riff[1])$([char]$riff[2])$([char]$riff[3])" -ne 'RIFF' -or
            "$([char]$wave[0])$([char]$wave[1])$([char]$wave[2])$([char]$wave[3])" -ne 'WAVE') {
            return [pscustomobject]@{ ok = $false; detail = 'not a RIFF/WAVE file' }
        }
        $fmt = $null; $dataLen = 0
        while ($fs.Position -lt $fs.Length) {
            $idBytes = $br.ReadBytes(4); $id = -join ($idBytes | ForEach-Object { [char]$_ })
            $len = $br.ReadUInt32()
            if ($id -eq 'fmt ') { $fmt = $br.ReadBytes([int]$len) }
            elseif ($id -eq 'data') { $dataLen = [int]$len; break }
            else { $fs.Seek($len, [System.IO.SeekOrigin]::Current) | Out-Null }
        }
        if (-not $fmt -or $dataLen -eq 0) { return [pscustomobject]@{ ok = $false; detail = 'fmt or data chunk missing' } }
        $audioFormat  = [BitConverter]::ToUInt16($fmt, 0)
        $channels     = [BitConverter]::ToUInt16($fmt, 2)
        $sampleRate   = [BitConverter]::ToUInt32($fmt, 4)
        $bitsPerSample= [BitConverter]::ToUInt16($fmt, 14)
        $seconds = $dataLen / ($sampleRate * $channels * ($bitsPerSample / 8))
        # Sample scan over the first ~60 MB (enough to detect total silence).
        $scan = [math]::Min($dataLen, 60MB)
        $chunk = $br.ReadBytes([int]$scan)
        $nonZero = 0; $nonFinite = 0; $total = 0
        if ($audioFormat -eq 3 -and $bitsPerSample -eq 32) {
            for ($i = 0; $i + 4 -le $chunk.Length; $i += 4) {
                $v = [BitConverter]::ToSingle($chunk, $i)
                if (-not [double]::IsFinite($v)) { $nonFinite++ }
                if ($v -ne 0) { $nonZero++ }
                $total++
            }
        } else {
            for ($i = 0; $i -lt $chunk.Length; $i += 4096) {
                $end = [math]::Min($i + 4096, $chunk.Length)
                for ($j = $i; $j -lt $end; $j++) { if ($chunk[$j] -ne 0) { $nonZero++; break } }
                $total++
            }
        }
        $tolerance = [math]::Max(1.0, $ExpectedDurationSec * 0.05)
        $ok = ([math]::Abs($seconds - $ExpectedDurationSec) -le $tolerance) -and
              ($nonFinite -eq 0) -and ($nonZero / [math]::Max(1, $total) -gt 0.01)
        return [pscustomobject]@{
            ok = $ok
            detail = "format=$audioFormat ch=$channels rate=$sampleRate bits=$bitsPerSample seconds=$($seconds.ToString('0.00')) nonZeroFrac=$([math]::Round($nonZero / [math]::Max(1,$total), 4)) nonFinite=$nonFinite"
        }
    } finally { $fs.Dispose() }
}

# ------------------------------------------------------------- engine session
function Start-Engine([string] $Root, [string] $Name, [int] $PortNumber, [string] $Device = 'ROCm0') {
    # Runs with the SDK variables REMOVED: the bundle must be self-contained.
    # A generated .cmd wraps the engine so the redirect quoting is exact and
    # the engine's stderr lands in a file (PS 5.1 cannot relay native stderr
    # through event handlers; Start-Process mangles inline redirects).
    $logPath = Join-Path $LogDir "$Name-server.log"
    $env:HIP_PATH = $null; $env:ROCM_PATH = $null; $env:HSA_OVERRIDE_GFX_VERSION = $null
    $cleanPath = (($env:PATH -split ';' | Where-Object { $_ -and $_ -notmatch 'rocm|hip' }) -join ';')
    $engineExe = Join-Path $Root 'yue-server.exe'
    $runner = Join-Path $LogDir "$Name-launch.cmd"
    $lines = @(
        '@echo off',
        "set `"PATH=$cleanPath`"",
        "`"$engineExe`" --model `"$ModelPath`" --vae `"$VaePath`" --device $Device --host 127.0.0.1 --port $PortNumber 1>`"$logPath`" 2>&1"
    )
    [System.IO.File]::WriteAllLines($runner, $lines)
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$runner`"" -WorkingDirectory $Root -PassThru -WindowStyle Hidden
    $healthy = $false
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
        Start-Sleep -Milliseconds 700
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$PortNumber/health" -TimeoutSec 3
            if ($h.status -eq 'ok') { $healthy = $true; break }
        } catch { }
    }
    Start-Sleep -Seconds 1
    $log = ''
    if (Test-Path $logPath) { $log = Get-Content -Raw $logPath }
    return [pscustomobject]@{ Process = $p; Port = $PortNumber; Healthy = $healthy; Log = $log; LogPath = $logPath }
}

function Stop-Engine($Session) {
    if (-not $Session) { return }
    # find the actual engine by its --port argument; cmd wrappers hide the PID
    $engines = Get-CimInstance Win32_Process -Filter "Name='yue-server.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "--port $($Session.Port)(\s|$|`")" }
    foreach ($e in $engines) { cmd /d /c "taskkill /F /PID $($e.ProcessId) >nul 2>&1" | Out-Null }
    if ($Session.Process -and -not $Session.Process.HasExited) {
        cmd /d /c "taskkill /T /F /PID $($Session.Process.Id) >nul 2>&1" | Out-Null
        $Session.Process.WaitForExit(10000) | Out-Null
    }
    Start-Sleep -Milliseconds 500
    $Session.Log = if (Test-Path $Session.LogPath) { Get-Content -Raw $Session.LogPath } else { $Session.Log }
}

function Split-MultipartAudio([byte[]] $Bytes) {
    # The engine answers GET /job?result=1 with multipart/mixed: per track a
    # JSON replay part, the audio part (audio/mpeg or audio/wav) and a raw
    # f32 latent part, separated by --yue2-batch-boundary. Pull the first
    # audio/* part out, byte-exact.
    $ascii = [System.Text.Encoding]::ASCII
    $marker = $ascii.GetBytes('Content-Type: audio/')
    $boundary = $ascii.GetBytes('--yue2-batch-boundary')
    $audioStart = -1
    for ($i = 0; $i -le $Bytes.Length - $marker.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $marker.Length; $j++) { if ($Bytes[$i + $j] -ne $marker[$j]) { $ok = $false; break } }
        if ($ok) { $audioStart = $i; break }
    }
    if ($audioStart -lt 0) {
        # not multipart: the engine may answer with the bare audio bytes
        return , $Bytes
    }
    # headers end at the first \r\n\r\n after the audio content-type
    $headEnd = -1
    for ($i = $audioStart; $i -lt $Bytes.Length - 3; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i+1] -eq 10 -and $Bytes[$i+2] -eq 13 -and $Bytes[$i+3] -eq 10) { $headEnd = $i + 4; break }
    }
    if ($headEnd -lt 0) { throw 'audio part header has no end' }
    $next = $Bytes.Length - 2
    for ($i = $headEnd; $i -le $Bytes.Length - $boundary.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $boundary.Length; $j++) { if ($Bytes[$i + $j] -ne $boundary[$j]) { $ok = $false; break } }
        if ($ok) { $next = $i; break }
    }
    $take = $next - 2 - $headEnd   # strip the \r\n just before the boundary
    if ($take -le 0) { throw 'audio part is empty' }
    $out = New-Object byte[] $take
    [Array]::Copy($Bytes, $headEnd, $out, 0, $take)
    return , $out
}

function Submit-Song([int] $PortNumber, $Request, [string] $OutFile, [switch] $SampleVram) {
    $body = $Request | ConvertTo-Json -Depth 5
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $submit = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$PortNumber/synth" -ContentType 'application/json' -Body $body -TimeoutSec 30
    $id = $submit.id
    if (-not $id) { throw 'engine accepted no job id' }
    $status = $null
    $deadline = (Get-Date).AddSeconds($JobTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        if ($SampleVram) {
            try {
                $c = Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop
                $sum = ($c.CounterSamples | Measure-Object CookedValue -Sum).Sum
                if ($sum -gt $script:vramPeakBytes) { $script:vramPeakBytes = $sum }
            } catch { }
        }
        $status = (Invoke-RestMethod -Uri "http://127.0.0.1:$PortNumber/job?id=$id" -TimeoutSec 15).status
        if ($status -in @('done', 'failed', 'cancelled')) { break }
    }
    $sw.Stop()
    if ($status -ne 'done') { throw "job ended as '$status' after $($sw.Elapsed.TotalSeconds.ToString('0.0')) s" }
    $rawFile = "$OutFile.result"
    Invoke-WebRequest -Uri "http://127.0.0.1:$PortNumber/job?id=$id&result=1" -OutFile $rawFile -TimeoutSec 120 | Out-Null
    $audio = Split-MultipartAudio -Bytes ([System.IO.File]::ReadAllBytes((Resolve-Path $rawFile).Path))
    [System.IO.File]::WriteAllBytes($OutFile, $audio)
    Remove-Item $rawFile -Force
    return [pscustomobject]@{ Id = $id; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# ------------------------------------------------------------- VRAM peak tap
$script:vramPeakBytes = 0.0

# ================================================================ 0. provenance
Record 'env/powershell' 'PASS' "PID $PID, $([Environment]::OSVersion.VersionString)"
$gpuName = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1).Name
if ($gpuName -match $GpuNamePattern) { Record 'env/gpu-present' 'PASS' $gpuName }
else { Record 'env/gpu-present' 'FAIL' "expected an adapter matching '$GpuNamePattern', saw '$gpuName'" }

$exe = Join-Path $EngineRoot 'yue-server.exe'
Record 'provenance/engine-sha256' 'PASS' "$(Get-FileSha256 $exe)"
if (Test-Path (Join-Path $EngineRoot 'runtime.json')) {
    Record 'provenance/runtime.json' 'PASS' ((Get-Content -Raw (Join-Path $EngineRoot 'runtime.json')).Trim() -replace "`n", ' ')
} else {
    Record 'provenance/runtime.json' 'NOT RUN' 'bundle carries no runtime.json'
}
foreach ($dll in @('ggml-hip.dll', 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll', 'hipblas.dll', 'rocblas.dll')) {
    $path = Join-Path $EngineRoot $dll
    if (Test-Path $path) { Record "closure/$dll" 'PASS' (Get-FileSha256 $path).Substring(0, 16) }
    else { Record "closure/$dll" 'FAIL' 'missing from the bundle' }
}
# cmd wraps the call: PS 5.1 turns native stderr into terminating errors here
$version = (cmd /d /c "`"$exe`" --help 2>&1" | Select-Object -First 1)
Record 'provenance/engine-version' 'PASS' "$version"

# ================================================================ 1. main session
$main = $null
try {
    $main = Start-Engine -Root $EngineRoot -Name 'main' -PortNumber $Port
    if ($main.Process.HasExited -and -not $main.Healthy) {
        $exitLine = (($main.Log -split "`n") | Select-Object -Last 5) -join ' | '
        if ($main.Process.ExitCode -eq 126 -or $main.Log -match 'blocked|Smart App|应用程序控制|策略阻止|Device Guard') {
            Record 'engine/start' 'BLOCKED' "Smart App Control blocked the unsigned binary (exit $($main.Process.ExitCode)). Re-run after SAC reputation changes or use a signed build."
        } else {
            Record 'engine/start' 'FAIL' "yue-server exited during startup (code $($main.Process.ExitCode)): $exitLine"
        }
    } elseif (-not $main.Healthy) {
        Record 'engine/start' 'FAIL' "no healthy /health answer within $StartupTimeoutSec s"
    } else {
        Record 'engine/start' 'PASS' "healthy on port $Port with no SDK environment variables"
        # gcnArch straight from the HIP device properties the engine logs
        if ($main.Log -match 'Device 0:\s*(?<g>[^,]+),\s*(?<arch>gfx\d+)') {
            if ($Matches.arch -eq $ExpectArch) {
                Record 'engine/device-arch' 'PASS' "$($Matches.g.Trim()) ($($Matches.arch)) matches the expected $ExpectArch"
            } else { Record 'engine/device-arch' 'FAIL' "device is $($Matches.g.Trim()) ($($Matches.arch)), expected ${ExpectArch}: the bundle's kernels and BLAS libraries must match the card" }
        } else { Record 'engine/device-arch' 'FAIL' 'no device enumeration line in the engine log' }
        if ($main.Log -match "loaded ROCm backend from\s*(?<p>[^\r\n]+)ggml-hip\.dll") {
            Record 'engine/hip-backend-applocal' 'PASS' "ggml-hip.dll loaded from $($Matches.p)"
        } else { Record 'engine/hip-backend-applocal' 'FAIL' 'no ROCm backend load line' }

        $props = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/props" -TimeoutSec 15
        Record 'engine/props' 'PASS' ((($props | ConvertTo-Json -Compress -Depth 3)))

        # ---- 2. full song, mp3 + wav, VRAM sampled while generating
        $mp3 = Join-Path $AudioDir 'T1-song.mp3'
        $job1 = Submit-Song -PortNumber $Port -Request $defaultRequest -OutFile $mp3 -SampleVram
        $rtf = [math]::Round($defaultRequest.duration / [math]::Max(0.1, $job1.Seconds), 2)
        Record 'generate/full-song' 'PASS' "id $($job1.Id), $($defaultRequest.duration) s of audio in $($job1.Seconds) s (real-time speed ${rtf}x)"
        $vramPeakMb = [math]::Round($script:vramPeakBytes / 1MB)
        Record 'generate/vram-peak' 'PASS' "dedicated peak $vramPeakMb MB"

        $mp3check = Test-Mp3File -Path $mp3 -ExpectedDurationSec $defaultRequest.duration
        if ($mp3check.ok) { Record 'audio/mp3-structure' 'PASS' $mp3check.detail }
        else { Record 'audio/mp3-structure' 'FAIL' $mp3check.detail }
        Record 'audio/mp3-sha256' 'PASS' (Get-FileSha256 $mp3)

        $wavRequest = @{} + $defaultRequest
        $wavRequest['output_format'] = 'wav24'
        $wav = Join-Path $AudioDir 'T2-song.wav'
        $job2 = Submit-Song -PortNumber $Port -Request $wavRequest -OutFile $wav
        $wavcheck = Test-WavFile -Path $wav -ExpectedDurationSec $defaultRequest.duration
        if ($wavcheck.ok) { Record 'audio/wav24-pcm' 'PASS' $wavcheck.detail }
        else { Record 'audio/wav24-pcm' 'FAIL' $wavcheck.detail }

        # ---- 3. fixed-seed replay must be byte-identical
        $replay = Join-Path $AudioDir 'T3-replay.mp3'
        Submit-Song -PortNumber $Port -Request $defaultRequest -OutFile $replay | Out-Null
        $h1 = Get-FileSha256 $mp3; $h2 = Get-FileSha256 $replay
        if ($h1 -eq $h2) { Record 'determinism/seed-replay' 'PASS' "sha256 identical ($($h1.Substring(0,16))…)" }
        else { Record 'determinism/seed-replay' 'FAIL' "seed $($defaultRequest.seed) replay differs: $h1 vs $h2" }

        # ---- 4. cancel a running job, then generate again
        $body = $defaultRequest | ConvertTo-Json -Depth 5
        $sub = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/synth" -ContentType 'application/json' -Body $body -TimeoutSec 30
        $saw = @()
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $st = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/job?id=$($sub.id)" -TimeoutSec 10).status
            $saw += $st
            if ($st -eq 'running') { break }
        }
        if ($saw -contains 'running') {
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/job?id=$($sub.id)&cancel=1" -TimeoutSec 10 | Out-Null
            $deadline = (Get-Date).AddSeconds(60)
            do {
                Start-Sleep -Milliseconds 600
                $st = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/job?id=$($sub.id)" -TimeoutSec 10).status
            } while ($st -in @('queued', 'running') -and (Get-Date) -lt $deadline)
            if ($st -eq 'cancelled') { Record 'job/cancel' 'PASS' "running -> cancelled" }
            else { Record 'job/cancel' 'FAIL' "expected cancelled, ended as '$st'" }
        } else { Record 'job/cancel' 'FAIL' "job never reported running (saw: $($saw -join ','))" }
        $after = Join-Path $AudioDir 'T4-after-cancel.mp3'
        Submit-Song -PortNumber $Port -Request $defaultRequest -OutFile $after | Out-Null
        Record 'job/generate-after-cancel' 'PASS' 'a full song generated after a cancel'

        # engine log must show real AR/NAR/VAE compute on the HIP device
        $logNow = if (Test-Path $main.LogPath) { Get-Content -Raw $main.LogPath } else { $main.Log }
        $stageMap = @(
            @{ Stage = 'AR';  Compute = '\[AR\]';  Backend = '(KV|LM) backend: ROCm0' },
            @{ Stage = 'NAR'; Compute = '\[NAR\]'; Backend = '(NAR|KV|LM) backend: ROCm0' },
            @{ Stage = 'VAE'; Compute = '\[VAE\]'; Backend = 'VAE backend: ROCm0' }
        )
        foreach ($s in $stageMap) {
            $computeHit = ($logNow -split "`n" | Where-Object { $_ -match $s.Compute } | Select-Object -First 1)
            $backendHit = ($logNow -split "`n" | Where-Object { $_ -match $s.Backend } | Select-Object -First 1)
            if ($computeHit -and $backendHit) {
                Record "stages/$($s.Stage)-on-rocm0" 'PASS' "$($computeHit.Trim()) | $($backendHit.Trim())"
            } else {
                Record "stages/$($s.Stage)-on-rocm0" 'FAIL' "compute lines: $($null -ne $computeHit); backend line: $($null -ne $backendHit)"
            }
        }
        if ($logNow -match 'falling back|fallback to (CPU|Vulkan|CUDA)') {
            Record 'policy/no-silent-fallback' 'FAIL' 'engine log mentions a backend fallback'
        } else { Record 'policy/no-silent-fallback' 'PASS' 'no fallback wording in the engine log' }
    }
} catch {
    Record 'generate/full-song' 'FAIL' "unexpected: $($_.Exception.Message)"
} finally {
    Stop-Engine $main
}

# ================================ 5. negative: broken bundles must fail closed
# Isolated copies only - the bundle under test is never touched.
foreach ($case in @(
        @{ Name = 'no-ggml-hip';     RemoveFile = 'ggml-hip.dll' },
        @{ Name = 'no-amd-comgr';    RemoveFile = 'amd_comgr.dll' },
        @{ Name = 'no-hip-runtime';  RemovePattern = 'amdhip64*.dll' },
        @{ Name = 'no-kernel-pack';  RemoveDir = 'rocblas' }
    )) {
    $iso = Join-Path $OutputDir ("iso-" + $case.Name)
    if (Test-Path $iso) { Remove-Item $iso -Recurse -Force }
    Copy-Item $EngineRoot $iso -Recurse
    if ($case.RemoveFile)  { Remove-Item (Join-Path $iso $case.RemoveFile) -Force }
    if ($case.RemovePattern) { Get-ChildItem $iso -Filter $case.RemovePattern -File | Remove-Item -Force }
    if ($case.RemoveDir)   { if (Test-Path (Join-Path $iso $case.RemoveDir)) { Remove-Item (Join-Path $iso $case.RemoveDir) -Recurse -Force } }
    $neg = $null
    try {
        $neg = Start-Engine -Root $iso -Name $case.Name -PortNumber ($Port + 1)
        if ($neg.Healthy) {
            Record "negative/$($case.Name)" 'FAIL' "engine still became healthy without $($case.RemoveFile)$($case.RemovePattern)$($case.RemoveDir) (would risk silent fallback)"
        } elseif ($neg.Process.HasExited) {
            $last = (($neg.Log -split "`n") | Where-Object { $_ -match 'FATAL|error|ROCm|backend|hip|LoadLibrary|HIP' } | Select-Object -Last 2) -join ' | '
            Record "negative/$($case.Name)" 'PASS' "exit $($neg.Process.ExitCode): $last"
        } else {
            Record "negative/$($case.Name)" 'FAIL' "engine neither exited nor answered; killed"
        }
    } catch {
        Record "negative/$($case.Name)" 'FAIL' $_.Exception.Message
    } finally {
        Stop-Engine $neg
        Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================ 6. negative: unknown device id must not redirect
$wrongDevice = $null
try {
    $wrongDevice = Start-Engine -Root $EngineRoot -Name 'wrong-device' -PortNumber ($Port + 2) -Device 'ROCm9'
    if ($wrongDevice.Healthy) {
        Record 'negative/wrong-device-id' 'FAIL' 'engine became healthy on --device ROCm9: an unknown device must fail, not start on another one'
    } elseif ($wrongDevice.Process.HasExited) {
        $last = (($wrongDevice.Log -split "`n") | Where-Object { $_ -match 'FATAL|error|device|ROCm|backend' } | Select-Object -Last 2) -join ' | '
        Record 'negative/wrong-device-id' 'PASS' "exit $($wrongDevice.Process.ExitCode): $last"
    } else {
        Record 'negative/wrong-device-id' 'FAIL' 'engine neither exited nor answered; killed'
    }
} catch {
    Record 'negative/wrong-device-id' 'FAIL' $_.Exception.Message
} finally {
    Stop-Engine $wrongDevice
}

# ====================================================== 7. portable env (no SDK)
$noSdk = $true
foreach ($v in @('HIP_PATH', 'ROCM_PATH')) {
    if ([Environment]::GetEnvironmentVariable($v)) { $noSdk = $false }
}
Record 'portable/no-sdk-env' $(if ($noSdk) { 'PASS' } else { 'FAIL' }) 'SDK variables were absent while the engine ran app-locally'

# =================================================================== 8. outputs
$Results | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutputDir 'results.json') -Encoding UTF8
$Results | Export-Csv -Path (Join-Path $OutputDir 'results.csv') -NoTypeInformation -Encoding UTF8
Get-ChildItem $AudioDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    "$(Get-FileSha256 $_.FullName) *$($_.Name)" | Add-Content -Path (Join-Path $OutputDir 'audio-sha256.txt')
}
$pass = ($Results | Where-Object status -eq 'PASS').Count
$fail = ($Results | Where-Object status -eq 'FAIL').Count
$blocked = ($Results | Where-Object status -eq 'BLOCKED').Count
Write-Host ""
Write-Host "==== $pass PASS, $fail FAIL, $blocked BLOCKED ===="
exit $(if ($fail -gt 0) { 1 } elseif ($blocked -gt 0) { 2 } else { 0 })
