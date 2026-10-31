# A small window to watch, for the tests. Freezes on purpose by keeping its UI thread busy.
# Its control port takes one line per connection, handled on the UI thread as many apps do:
#   ping    answers at once
#   work N  keeps the UI thread busy for N seconds, then answers (a command that freezes the window)
#   bg N    answers after N seconds, and the window stays alive meanwhile (a command that runs in the background)
param([int]$Port = 0, [double]$HangAfter = -1, [double]$HangFor = 0, [double]$LifeSeconds = 120)

Add-Type -AssemblyName System.Windows.Forms

$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:hung = $false
$script:later = New-Object System.Collections.ArrayList
$script:listener = $null
if ($Port -gt 0) {
    $script:listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $script:listener.Start()
}

# Not Start-Sleep: on this thread it goes on handling the messages Windows uses to test a window, so the window
# isn't frozen as far as Windows can tell.
function Stop-Pumping([double]$Seconds) {
    $until = $script:clock.Elapsed.TotalSeconds + $Seconds
    while ($script:clock.Elapsed.TotalSeconds -lt $until) { [Threading.Thread]::SpinWait(200000) }
}

function Send-Reply($Client, [string]$Text) {
    try {
        $writer = New-Object IO.StreamWriter($Client.GetStream())
        $writer.AutoFlush = $true
        $writer.WriteLine($Text)
    } catch { }
    $Client.Close()
}

$form = New-Object Windows.Forms.Form
$form.Text = 'hang-watch test app'
$form.Width = 320
$form.Height = 120
$form.WindowState = 'Minimized'

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
    $now = $script:clock.Elapsed.TotalSeconds
    if ($now -ge $LifeSeconds) { $timer.Stop(); $form.Close(); return }
    if ($HangAfter -ge 0 -and -not $script:hung -and $now -ge $HangAfter) {
        $script:hung = $true
        Stop-Pumping $HangFor
    }
    foreach ($item in @($script:later)) {
        if ($now -ge $item.Due) {
            Send-Reply $item.Client 'done'
            [void]$script:later.Remove($item)
        }
    }
    while ($script:listener -and $script:listener.Pending()) {
        $client = $script:listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 2000
            $line = (New-Object IO.StreamReader($client.GetStream())).ReadLine()
        } catch {
            $line = $null
        }
        $word, $amount = "$line".Trim() -split '\s+', 2
        switch ($word) {
            'ping' { Send-Reply $client 'pong' }
            'work' { Stop-Pumping ([double]$amount); Send-Reply $client 'done' }
            'bg' { [void]$script:later.Add([pscustomobject]@{ Due = $now + [double]$amount; Client = $client }) }
            default { $client.Close() }
        }
    }
})
$timer.Start()
[Windows.Forms.Application]::Run($form)
if ($script:listener) { $script:listener.Stop() }
