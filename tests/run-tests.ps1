# Runs hang-watch against tests/fake-app.ps1, which freezes on purpose. Takes about two minutes and flashes small
# minimized windows in the taskbar. Run it from Windows PowerShell: .\tests\run-tests.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$watch = Join-Path (Split-Path -Parent $here) 'hang-watch.ps1'
$fake = Join-Path $here 'fake-app.ps1'
$script:failed = 0
$script:port = 18600 + (Get-Random -Maximum 300)

function New-Port { $script:port++; $script:port }

# The console is hidden so that the form is the process's main window: a console window is drawn by another process
# and always responds.
function Get-FakeArgs([string]$Path = $fake, [string[]]$More = @()) {
    @('-WindowStyle', 'Hidden', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $More
}

function Invoke-Watch([hashtable]$Params) {
    $global:LASTEXITCODE = 0
    $text = (& $watch @Params 2>&1 | Out-String)
    [pscustomobject]@{ Code = $global:LASTEXITCODE; Text = $text }
}

# In a process of its own, for what goes to real stderr. Arguments as a command line would give them.
function Invoke-Child([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $text = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watch @Arguments 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}

function Test-Case([string]$Name, [bool]$Passed, [string]$Detail) {
    if ($Passed) {
        Write-Output "PASS  $Name"
    } else {
        $script:failed++
        Write-Output "FAIL  $Name"
        Write-Output ($Detail -replace '(?m)^', '      ')
    }
}

# The number of samples in "not responding  3 of 7 samples".
function Get-Bad([string]$Text) {
    $m = [regex]::Match($Text, 'not responding\s+(\d+) of')
    if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
}

$r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs); Seconds = 4; Close = $true }
Test-Case 'a healthy window is OK, exit 0' ($r.Code -eq 0 -and (Get-Bad $r.Text) -eq 0 -and $r.Text -match 'verdict\s+OK') $r.Text

$r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs -More '-HangAfter', '1', '-HangFor', '10'); Seconds = 15; Close = $true }
$m = [regex]::Match($r.Text, 'longest freeze\s+about ([\d.]+) s')
$gap = if ($m.Success) { [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
Test-Case 'a frozen window is FROZE, exit 1, with how long' ($r.Code -eq 1 -and (Get-Bad $r.Text) -gt 0 -and $r.Text -match 'verdict\s+FROZE' -and $gap -ge 7) $r.Text

$p = New-Port
$r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs -More '-Port', "$p"); Seconds = 40; Probe = "$p"; ProbeLine = 'ping'; Send = 'work 9'; Close = $true }
$m = [regex]::Match($r.Text, 'answered after ([\d.]+) s')
$took = if ($m.Success) { [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
Test-Case 'a request that freezes the app: FROZE by both tests, and the request timed' ($r.Code -eq 1 -and $took -ge 8.5 -and $took -lt 15 -and (Get-Bad $r.Text) -gt 0 -and $r.Text -match 'probe\s+[1-9]\d* of') $r.Text

$p = New-Port
$r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs -More '-Port', "$p"); Seconds = 40; Probe = "127.0.0.1:$p"; ProbeLine = 'ping'; Send = 'bg 4'; Close = $true }
$m = [regex]::Match($r.Text, 'answered after ([\d.]+) s')
$took = if ($m.Success) { [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
Test-Case 'a request in the background: OK, ends when answered' ($r.Code -eq 0 -and $took -ge 3.5 -and $took -lt 8 -and $r.Text -match 'probe\s+0 of' -and $r.Text -match 'verdict\s+OK') $r.Text

$p = New-Port
$other = Start-Process powershell.exe -ArgumentList ((Get-FakeArgs -More '-Port', "$p") -join ' ') -PassThru -WindowStyle Hidden
try {
    $r = Invoke-Watch @{ AttachPid = $other.Id; Seconds = 3; Probe = "$p"; ProbeLine = 'ping'; Close = $true }
    $other.Refresh()
    Test-Case 'attached by id: watched, and left running despite -Close' ($r.Code -eq 0 -and -not $other.HasExited) $r.Text
} finally {
    if (-not $other.HasExited) { Stop-Process -Id $other.Id -Force }
}

$r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs -More '-LifeSeconds', '3'); Seconds = 30 }
Test-Case 'an app that ends: said so, without waiting out the time' ($r.Code -eq 0 -and $r.Text -match 'app ended\s+after' -and $r.Text -notmatch 'watched\s+(1\d|2\d)') $r.Text

$folder = Join-Path $env:TEMP ("hang watch test " + (Get-Random))
[void](New-Item -ItemType Directory -Path $folder)
try {
    $spaced = Join-Path $folder 'fake app.ps1'
    Copy-Item $fake $spaced
    $out = Join-Path $folder 'samples.tsv'
    $r = Invoke-Watch @{ Exe = 'powershell.exe'; AppArgs = (Get-FakeArgs -Path $spaced); Seconds = 3; Out = $out; Close = $true }
    Test-Case 'an argument with a space starts the app' ($r.Code -eq 0 -and $r.Text -match 'verdict\s+OK') $r.Text
    $lines = @(Get-Content $out)
    $row = if ($lines.Count -gt 1) { $lines[1] -split "`t" } else { @() }
    Test-Case '-Out has a header and one row per sample' ($lines.Count -ge 3 -and $lines[0] -like 'seconds*' -and $row.Count -eq 5 -and $row[0] -match '^\d+\.\d$' -and $row[1] -eq 'True') ($lines -join "`n")
} finally {
    Remove-Item -LiteralPath $folder -Recurse -Force
}

$quiet = Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep 30' -PassThru -WindowStyle Hidden
try {
    $r = Invoke-Child @('-AttachPid', "$($quiet.Id)", '-Seconds', '3', '-StartTimeout', '2')
    Test-Case 'no window and no port: says it can not tell, exit 3' ($r.Code -eq 3 -and $r.Text -match 'no window') $r.Text
} finally {
    if (-not $quiet.HasExited) { Stop-Process -Id $quiet.Id -Force }
}

$bad = @(
    @('no target', @('-Seconds', '1'), 'exactly one'),
    @('two targets', @('-Exe', 'powershell.exe', '-AttachPid', '4'), 'exactly one'),
    @('a program that is not there', @('-Exe', 'C:\no\such\program.exe'), 'no program'),
    @('a process that is not there', @('-AttachPid', '999999'), 'no process'),
    @('a name that is not there', @('-AttachName', 'no-such-process-3468'), 'no process named'),
    @('a port that is not a number', @('-AttachName', 'x', '-Probe', 'host:abc'), 'host:port'),
    @('a port out of range', @('-AttachName', 'x', '-Probe', '70000'), 'host:port'),
    @('a host with no name', @('-AttachName', 'x', '-Probe', ':7000'), 'host:port'),
    @('-Send without a port', @('-AttachName', 'x', '-Send', 'go'), 'needs -Probe'),
    @('-ProbeLine without a port', @('-AttachName', 'x', '-ProbeLine', 'go'), 'needs -Probe'),
    @('-Out in a folder that is not there', @('-AttachName', 'x', '-Out', 'C:\no\such\folder\a.tsv'), 'no folder')
)
foreach ($case in $bad) {
    $r = Invoke-Child $case[1]
    Test-Case "refused with exit 2: $($case[0])" ($r.Code -eq 2 -and $r.Text -match [regex]::Escape($case[2])) "exit $($r.Code)`n$($r.Text)"
}

try {
    $r = Invoke-Watch @{ AttachName = 'x'; Seconds = 0 }
    Test-Case 'refused: -Seconds 0' ($false) $r.Text
} catch {
    Test-Case 'refused: -Seconds 0' ($_.Exception.Message -match 'Seconds') $_.Exception.Message
}

Write-Output ''
if ($script:failed -gt 0) { Write-Output "$($script:failed) failed"; exit 1 }
Write-Output 'all passed'
