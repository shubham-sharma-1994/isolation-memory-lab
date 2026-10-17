param([string]$Exe, [int]$Target = 20, [int]$MemMB = 256, [int]$FloorMB = 1900)
$ErrorActionPreference = 'Continue'

function Smol([string[]]$a, [int]$timeoutS = 120) {
  $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $Exe -ArgumentList $a -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden -PassThru
  $null = $p.Handle
  $done = $p.WaitForExit($timeoutS * 1000)
  $r = [pscustomobject]@{ Ok = ($done -and $p.ExitCode -eq 0); Secs = $sw.Elapsed.TotalSeconds; Out = ((Get-Content $o -Raw) + (Get-Content $e -Raw)).Trim() }
  Remove-Item $o, $e -EA SilentlyContinue
  $r
}
function ExecCmd([string]$name, [string]$shellLine) {
  $o = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  cmd /c "`"$Exe`" machine exec --name $name -- sh -c `"$shellLine`" > `"$o`" 2>&1"
  $r = [pscustomobject]@{ Secs = $sw.Elapsed.TotalSeconds; Out = (Get-Content $o -Raw) }
  Remove-Item $o -EA SilentlyContinue
  $r
}
function SmolMemMB { $m = (Get-Process smolvm -EA SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum; if ($m) { [math]::Round($m / 1MB) } else { 0 } }
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }
function CpuPct {
  $v = @((Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples | ForEach-Object { $_.CookedValue })
  [math]::Round(($v | Measure-Object -Average).Average)
}
function Median($xs) { $s = @($xs | Sort-Object); $s[[int][math]::Floor(($s.Count - 1) / 2)] }

$names = @(); $rows = @(); $stopReason = "reached target"
$free0 = FreeMB; $mem0 = SmolMemMB
"start: free RAM $free0 MB, target $Target VMs x $MemMB MB, floor $FloorMB MB"
try {
  for ($i = 1; $i -le $Target; $i++) {
    $f = FreeMB
    if ($f -lt $FloorMB) { $stopReason = "SAFETY STOP before VM ${i}: free RAM ${f} MB is below the floor of ${FloorMB} MB"; break }
    $n = "bench-{0:D2}" -f $i
    $c = Smol @('machine', 'create', '--name', $n, '--image', 'alpine', '--mem', "$MemMB", '--cpus', '1') 60
    $s = Smol @('machine', 'start', '--name', $n) 180
    $names += $n
    $w = ExecCmd $n "nohup sh -c 'while :; do head -c 200000 /dev/urandom | md5sum >/dev/null; sleep 1; done' >/dev/null 2>&1 &"
    $row = [pscustomobject]@{ N = $i; CreateS = [math]::Round($c.Secs, 1); StartS = [math]::Round($s.Secs, 1); WorkloadCallS = [math]::Round($w.Secs, 1); SmolHostMB = (SmolMemMB) - $mem0; FreeMB = (FreeMB) }
    $rows += $row
    "VM {0,2}: create {1,4}s  start {2,5}s  workload-launch {3,4}s | smolvm host +{4} MB | free RAM {5} MB" -f $i, $row.CreateS, $row.StartS, $row.WorkloadCallS, $row.SmolHostMB, $row.FreeMB
    if ($i -in 1, 5, 10, 15, 20) {
      $lat = @(1..5 | ForEach-Object { (ExecCmd 'bench-01' 'true').Secs })
      $mn = ($lat | Measure-Object -Minimum).Minimum; $mx = ($lat | Measure-Object -Maximum).Maximum
      "   -> at {0} VMs: exec latency on bench-01 median {1:N2}s (min {2:N2}, max {3:N2}); host CPU {4}%" -f $i, (Median $lat), $mn, $mx, (CpuPct)
    }
  }
  "STOP: $stopReason"
  if ($names.Count -gt 0) {
    $g = ExecCmd 'bench-01' "cat /proc/loadavg; ps | grep -c '[m]d5sum'; free -m | sed -n 2p"
    "guest bench-01 loadavg / md5sum procs / memory: " + ($g.Out -replace "`r?`n", " | ")
    "VMs running: {0}; smolvm host RAM total {1} MB; free RAM {2} MB (was {3} MB)" -f $names.Count, ((SmolMemMB) - $mem0), (FreeMB), $free0
    $listed = @(((Smol @('machine', 'list')).Out -split "`n") | Where-Object { $_ -match 'bench-' }).Count
    "list check: $listed bench VMs listed"
  }
}
finally {
  "== teardown"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($n in $names) {
    Smol @('machine', 'stop', '--name', $n) 90 | Out-Null
    Smol @('machine', 'delete', '--name', $n, '--force') 90 | Out-Null
  }
  "teardown of {0} VMs: {1:N1}s" -f $names.Count, $sw.Elapsed.TotalSeconds
  Start-Sleep 3
  "left: " + (Smol @('machine', 'list')).Out + " | smolvm processes: " + @(Get-Process smolvm -EA SilentlyContinue).Count + " | free RAM " + (FreeMB) + " MB"
  $rows | Export-Csv "$PSScriptRoot\last-run.csv" -NoTypeInformation
}
