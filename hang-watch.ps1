<#
.SYNOPSIS
    Watches a Windows app and reports whether its window froze: what Windows says about it, and, if the app has a
    TCP control port, whether that port still answers. It sends no keys or clicks. See README.md.

.EXAMPLE
    .\hang-watch.ps1 -AttachName notepad -Seconds 30
.EXAMPLE
    .\hang-watch.ps1 -Exe .\app.exe -AppArgs '--port','7000' -Probe 7000 -ProbeLine 'ping' -Send 'slow-command' -Close
#>
[CmdletBinding()]
param(
    # The app to start. Use this, or -AttachPid, or -AttachName.
    [string]$Exe,
    # Arguments for -Exe.
    [string[]]$AppArgs = @(),
    # Watch a process that is already running, by id.
    [int]$AttachPid = 0,
    # Watch a process that is already running, by name. Refused if the name fits more than one with a window.
    [string]$AttachName,
    # Stop watching after this many seconds.
    [ValidateRange(1, 86400)][int]$Seconds = 120,
    # Seconds between samples while the app is healthy. A frozen app makes samples slower: see the README.
    [ValidateRange(0.1, 60.0)][double]$Interval = 0.5,
    # Seconds to wait once the app is up, before sampling and before -Send.
    [ValidateRange(0, 3600)][int]$Settle = 0,
    # Seconds the app gets to show a window, or to answer -Probe.
    [ValidateRange(1, 3600)][int]$StartTimeout = 60,
    # A control port to try with each sample: 7000 or host:7000 (the default host is 127.0.0.1).
    [string]$Probe,
    # The line to send on -Probe with each sample; any line back counts as an answer. Without it, a probe only
    # connects, which an app with a frozen window may still accept.
    [string]$ProbeLine = '',
    # How long a probe waits for its answer, in milliseconds.
    [ValidateRange(100, 60000)][int]$ProbeTimeoutMs = 3000,
    # One line to send on -Probe when sampling starts: the request under test. Watching ends when it has been answered
    # and the app is healthy.
    [string]$Send,
    # Write every sample to this file as it is taken (tab-separated).
    [string]$Out,
    # Close the app at the end, if this script started it, by asking its window to close. It is never killed, and an
    # attached process is never closed.
    [switch]$Close
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Stop-WithError([string]$Message) {
    [Console]::Error.WriteLine("hang-watch: $Message")
    exit 2
}

# Run in this thread for probes and in a runspace for -Send, so it stays one script block with no script-scope names.
$askBlock = {
    param([string]$TargetHost, [int]$Port, [string]$Line, [int]$TimeoutMs)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient
    $ok = $false
    $reply = $null
    try {
        $pending = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if ($pending.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($pending)
            if ($Line -eq '') {
                $ok = $true
            } else {
                $client.ReceiveTimeout = $TimeoutMs
                $client.SendTimeout = $TimeoutMs
                $stream = $client.GetStream()
                $writer = New-Object IO.StreamWriter($stream)
                $writer.NewLine = "`n"
                $writer.AutoFlush = $true
                $writer.WriteLine($Line)
                $reply = (New-Object IO.StreamReader($stream)).ReadLine()
                $ok = $null -ne $reply
            }
        }
    } catch {
        $ok = $false
    } finally {
        $client.Close()
    }
    [pscustomobject]@{ Ok = $ok; Seconds = $clock.Elapsed.TotalSeconds; Reply = $reply }
}

function Format-Number([double]$Value, [string]$Format = '0.0') {
    $Value.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

# Start-Process joins its arguments with spaces and doesn't quote them.
function Join-Arguments([string[]]$Values) {
    ($Values | ForEach-Object { if ($_ -eq '' -or $_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

# Checks that need no process.
$targets = @(@($Exe, $AttachName | Where-Object { $_ }).Count, [int]($AttachPid -ne 0)) | Measure-Object -Sum
if ($targets.Sum -ne 1) { Stop-WithError 'give exactly one of -Exe, -AttachPid and -AttachName' }
if ($AttachPid -lt 0) { Stop-WithError "-AttachPid must be a process id, not $AttachPid" }
$probeHost = '127.0.0.1'
$probePort = 0
if ($Probe) {
    $at = $Probe.LastIndexOf(':')
    if ($at -ge 0) { $probeHost = $Probe.Substring(0, $at); $portText = $Probe.Substring($at + 1) } else { $portText = $Probe }
    if (-not [int]::TryParse($portText, [ref]$probePort) -or $probePort -lt 1 -or $probePort -gt 65535 -or $probeHost -eq '') {
        Stop-WithError "-Probe must be a port or host:port, not '$Probe'"
    }
}
if ($Send -and -not $Probe) { Stop-WithError '-Send needs -Probe, the port to send it on' }
if ($ProbeLine -and -not $Probe) { Stop-WithError '-ProbeLine needs -Probe, the port to send it on' }
if ($Out) {
    try {
        $outFolder = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
        if (-not (Test-Path -LiteralPath $outFolder -PathType Container)) { Stop-WithError "-Out: no folder '$outFolder'" }
        [IO.File]::WriteAllText($Out, "seconds`tresponding`twindow`tprobe_ok`tprobe_ms`n")
    } catch {
        Stop-WithError "-Out: can't write '$Out': $($_.Exception.Message)"
    }
}

# Find or start the app.
$started = $false
try {
    if ($Exe) {
        if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { Stop-WithError "no program '$Exe'" }
        $startArgs = @{ FilePath = $Exe; PassThru = $true }
        if ($AppArgs.Count -gt 0) { $startArgs.ArgumentList = Join-Arguments $AppArgs }
        $proc = Start-Process @startArgs
        $started = $true
    } elseif ($AttachPid -ne 0) {
        $proc = Get-Process -Id $AttachPid -ErrorAction SilentlyContinue
        if (-not $proc) { Stop-WithError "no process with id $AttachPid" }
    } else {
        $name = $AttachName -replace '\.exe$', ''
        $found = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { Stop-WithError "no process named '$name'" }
        $withWindow = @($found | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        if ($withWindow.Count -gt 1) { Stop-WithError "'$name' fits several processes; use -AttachPid with one of: $(($withWindow.Id) -join ', ')" }
        $proc = if ($withWindow.Count -eq 1) { $withWindow[0] } elseif ($found.Count -eq 1) { $found[0] } else { $null }
        if (-not $proc) { Stop-WithError "'$name' fits several processes; use -AttachPid with one of: $(($found.Id) -join ', ')" }
    }
} catch {
    Stop-WithError "can't start or find the app: $($_.Exception.Message)"
}
$appName = "$($proc.ProcessName) (process $($proc.Id))"

# Wait until it is up: its port answers, or it has a window.
$up = $false
$waited = [Diagnostics.Stopwatch]::StartNew()
while ($waited.Elapsed.TotalSeconds -lt $StartTimeout) {
    $proc.Refresh()
    if ($proc.HasExited) { break }
    if ($Probe) {
        $up = (& $askBlock $probeHost $probePort $ProbeLine ([Math]::Min($ProbeTimeoutMs, 2000))).Ok
    } else {
        $up = $proc.MainWindowHandle -ne [IntPtr]::Zero
    }
    if ($up) { break }
    Start-Sleep -Milliseconds 200
}
if (-not $up) {
    $proc.Refresh()
    if ($proc.HasExited) {
        [Console]::Error.WriteLine("hang-watch: $appName ended before it was up")
    } elseif ($Probe) {
        [Console]::Error.WriteLine("hang-watch: $appName didn't answer on $Probe within $StartTimeout s")
    } else {
        [Console]::Error.WriteLine("hang-watch: $appName has no window: Windows can't say whether it responds. Give it a -Probe to test.")
    }
    exit 3
}
if ($Settle -gt 0) { Start-Sleep -Seconds $Settle }

# The request under test, in the background, so it can't hold up the samples and its own time is exact.
$request = $null
$requestDone = $null
if ($Send) {
    $request = [powershell]::Create()
    [void]$request.AddScript($askBlock.ToString()).AddArgument($probeHost).AddArgument($probePort).AddArgument($Send).AddArgument($Seconds * 1000)
    $requestDone = $request.BeginInvoke()
}

$clock = [Diagnostics.Stopwatch]::StartNew()
$samples = 0
$notResponding = 0
$firstBad = $null
$lastBad = $null
$windowSamples = 0
$unanswered = 0
$slowest = 0.0
$lastHealthy = 0.0
$longestGap = 0.0
$gapFrom = 0.0
$healthy = $true
$endedAt = $null

while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    $at = $clock.Elapsed.TotalSeconds
    try {
        $proc.Refresh()
        if ($proc.HasExited) { $endedAt = $at; break }
        $hasWindow = $proc.MainWindowHandle -ne [IntPtr]::Zero
        $responding = $proc.Responding
    } catch {
        $endedAt = $at
        break
    }
    $answer = if ($Probe) { & $askBlock $probeHost $probePort $ProbeLine $ProbeTimeoutMs } else { $null }

    $samples++
    if ($hasWindow) { $windowSamples++ }
    if (-not $responding) {
        $notResponding++
        if ($null -eq $firstBad) { $firstBad = $at }
        $lastBad = $at
    }
    if ($answer) {
        if ($answer.Ok) { if ($answer.Seconds -gt $slowest) { $slowest = $answer.Seconds } } else { $unanswered++ }
    }
    if ($Out) {
        $probeOk = if ($answer) { $answer.Ok } else { '' }
        $probeMs = if ($answer) { Format-Number ($answer.Seconds * 1000) '0' } else { '' }
        [IO.File]::AppendAllText($Out, "$(Format-Number $at)`t$responding`t$hasWindow`t$probeOk`t$probeMs`n")
    }

    $healthy = $responding -and ((-not $answer) -or $answer.Ok)
    if ($healthy) {
        if ($at - $lastHealthy -gt $longestGap) { $longestGap = $at - $lastHealthy; $gapFrom = $lastHealthy }
        $lastHealthy = $at
        if ($requestDone -and $requestDone.IsCompleted) { break }
    }
    $rest = $Interval - ($clock.Elapsed.TotalSeconds - $at)
    if ($rest -gt 0) { Start-Sleep -Milliseconds ([int]($rest * 1000)) }
}
$watched = $clock.Elapsed.TotalSeconds
$stillBad = (-not $healthy) -and ($null -eq $endedAt)
if ($stillBad -and ($watched - $lastHealthy -gt $longestGap)) { $longestGap = $watched - $lastHealthy; $gapFrom = $lastHealthy }

# The report.
$froze = ($notResponding -gt 0) -or ($unanswered -gt 0)
function Write-Field([string]$Name, [string]$Text) { Write-Output ($Name.PadRight(16) + $Text) }
Write-Field 'app' $appName
Write-Field 'watched' "$(Format-Number $watched) s, $samples samples"
if ($windowSamples -eq 0 -and -not $Probe) {
    Write-Field 'window' 'none seen: Windows says nothing about an app with no window'
}
$bad = "$notResponding of $samples samples"
if ($null -ne $firstBad) { $bad += " (first at $(Format-Number $firstBad) s, last at $(Format-Number $lastBad) s)" }
Write-Field 'not responding' $bad
if ($Probe) {
    Write-Field 'probe' "$unanswered of $samples unanswered within $ProbeTimeoutMs ms, slowest answered $(Format-Number ($slowest * 1000) '0') ms"
}
if ($froze) {
    Write-Field 'longest freeze' "about $(Format-Number $longestGap) s (from $(Format-Number $gapFrom) s)$(if ($stillBad) { ', still frozen at the end' })"
}
if ($request) {
    if ($requestDone.IsCompleted) {
        $result = @($request.EndInvoke($requestDone))
        $text = if ($result.Count -gt 0 -and $result[0].Ok) {
            $reply = [string]$result[0].Reply
            "answered after $(Format-Number $result[0].Seconds) s: $($reply.Substring(0, [Math]::Min(100, $reply.Length)))"
        } else {
            'no answer: the connection failed or closed'
        }
    } else {
        $text = "not answered within $(Format-Number $watched) s"
        [void]$request.BeginStop($null, $null)
    }
    Write-Field 'request' $text
}
if ($null -ne $endedAt) { Write-Field 'app ended' "after $(Format-Number $endedAt) s" }
Write-Field 'verdict' $(if ($froze) { 'FROZE' } elseif ($samples -eq 0) { 'NOTHING SAMPLED' } else { 'OK' })
if ($Out) { Write-Field 'samples in' $Out }

if ($Close -and $started) {
    $proc.Refresh()
    if (-not $proc.HasExited) {
        [void]$proc.CloseMainWindow()
        if (-not $proc.WaitForExit(5000)) { Write-Field 'still running' "$appName didn't close when asked; it wasn't killed" }
    }
}

if ($froze) { exit 1 }
if ($samples -eq 0) { exit 3 }
if ($windowSamples -eq 0 -and -not $Probe) { exit 3 }
exit 0
