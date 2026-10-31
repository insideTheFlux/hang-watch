# hang-watch

A small script that watches a Windows app and tells you whether its window froze, and for how long.

I wrote it to prove a freeze before and after a fix: the same steps, on the old build and the new one, with numbers
instead of "it felt better". It works on any app with a window, and it sends no keys or clicks, so it can't type into
whatever else you have open.

## What it looks at

- **What Windows says.** Each sample reads `Process.Responding`, the same kind of check behind the "not responding"
  dialog.
- **A control port, if the app has one.** With `-Probe`, each sample also sends a line to a TCP port and times the answer.
  An app that does its port's work on its UI thread stops answering when its window freezes.

## Run it

It needs Windows PowerShell 5.1, which comes with Windows, and nothing else. Run it from PowerShell. If your execution
policy blocks scripts, allow them for this one session first:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Watch an app that is already open while you do the slow thing yourself:

```powershell
.\hang-watch.ps1 -AttachName notepad -Seconds 60
```

Start an app, and close it again at the end:

```powershell
.\hang-watch.ps1 -Exe .\app.exe -AppArgs '--some','option' -Seconds 60 -Close
```

Start an app with a control port, send it the slow command, and stop when it has answered:

```powershell
.\hang-watch.ps1 -Exe .\app.exe -AppArgs '--control','7000' -Settle 15 -Close `
    -Probe 7000 -ProbeLine '{"method":"status"}' -Send '{"method":"slow-command"}'
```

`-ProbeLine` is what each sample sends, and it should be something quick. `-Send` is the request under test, sent once.
Any line back counts as an answer. The app's own settings, such as a scratch profile, are set the usual way, with
`$env:NAME = 'value'` before you run it.

## Reading the result

The same request on two builds of a photo app, with 210 raw photos. First the build that does the work on its UI thread:

```text
app             lightcraft-main (process 10168)
watched         41.2 s, 15 samples
not responding  13 of 15 samples (first at 0.5 s, last at 40.6 s)
probe           11 of 15 unanswered within 3000 ms, slowest answered 1903 ms
longest freeze  about 41.2 s (from 0.0 s)
request         answered after 40.6 s: {"id":3,"ok":true,"result":{"photos":[{"id":1,"similarity":1.0},...
verdict         FROZE
```

Then the build that moved the work to a background thread:

```text
app             lightcraft-fix (process 7564)
watched         22.0 s, 44 samples
not responding  0 of 44 samples
probe           0 of 44 unanswered within 3000 ms, slowest answered 37 ms
request         answered after 21.6 s: {"id":3,"ok":true,"result":{"photos":[{"id":1,"similarity":1.0},...
verdict         OK
```

| Line | Meaning |
|---|---|
| `not responding` | Samples where Windows said the window wasn't responding |
| `probe` | Samples where the port gave no answer in time, and the slowest answer it did give |
| `longest freeze` | The longest time between two healthy samples, so an upper limit: it can be off by one sample |
| `request` | How long `-Send` took, and the start of its answer |
| `verdict` | `FROZE` if any sample was unhealthy, else `OK` |

A frozen app gives fewer samples, because each one can wait for Windows and for the probe's timeout. That's why the first
result above has 15 samples and the second has 44.

`-Out samples.tsv` writes every sample as it is taken, so a run you stop early still leaves its data:

```text
seconds	responding	window	probe_ok	probe_ms
0.5	False	True	False	3009
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | No freeze seen |
| 1 | It froze |
| 2 | Bad arguments, or the app can't be found or started |
| 3 | It can't tell: no window and no port that answers, or the app was gone before the first sample |

## All the options

| Option | Default | Meaning |
|---|---|---|
| `-Exe`, `-AppArgs` | | The app to start, and its arguments |
| `-AttachPid` | | Watch a running process by id |
| `-AttachName` | | Watch a running process by name; refused if it fits several with a window |
| `-Seconds` | 120 | Stop watching after this long |
| `-Interval` | 0.5 | Seconds between samples while healthy |
| `-Settle` | 0 | Seconds to wait once the app is up, before sampling and `-Send` |
| `-StartTimeout` | 60 | Seconds the app gets to show a window or answer the probe |
| `-Probe` | | A port to test with each sample: `7000` or `host:7000` (not IPv6) |
| `-ProbeLine` | | The line each probe sends; without it a probe only connects |
| `-ProbeTimeoutMs` | 3000 | How long a probe waits for its answer |
| `-Send` | | One line to send when sampling starts; watching ends when it is answered and the app is healthy |
| `-Out` | | Write every sample to this file |
| `-Close` | | Close the app at the end, if this script started it |

`-Close` asks the window to close, as clicking its ✕ would. It never kills the app, and it never closes an app it only
attached to.

## What it can't tell you

- **Windows only notices after a while.** It can take several seconds to report a window as not responding, so a freeze
  of a second or two can go unseen unless a probe catches it.
- **A busy app isn't always a frozen one.** Windows only asks whether the window handles messages. An app can look
  frozen to you, showing a stale picture for instance, and still pass.
- **Console programs always pass.** A console window is drawn by another process, so it keeps responding whatever the
  program is doing. With no window at all, Windows has nothing to say: use `-Probe`, or the exit code is 3.
- **A probe with no `-ProbeLine` proves little.** The system can accept a connection for an app whose window is frozen.
- **The numbers aren't precise timings.** Samples are half a second apart at best, and much further apart during a freeze.
  `request` is timed exactly.

It has only been run on Windows 11 with Windows PowerShell 5.1.

## Tests

```powershell
.\tests\run-tests.ps1
```

They watch `tests/fake-app.ps1`, a small window that freezes on purpose, and take about a minute. Small minimized windows
appear in the taskbar meanwhile, and the test app keeps one CPU core busy while it is "frozen".

## Licence

MIT. See [LICENSE](LICENSE).
