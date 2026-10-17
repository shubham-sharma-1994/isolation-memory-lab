param([string]$Exe, [string]$Base, [string[]]$Accounts = @('a', 'b'), [int]$FloorMB = 1400)
$ErrorActionPreference = 'Continue'
$Accounts = @($Accounts | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Smol([string[]]$a, [int]$timeoutS = 180) {
  $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $Exe -ArgumentList $a -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden -PassThru
  $null = $p.Handle
  $done = $p.WaitForExit($timeoutS * 1000)
  $r = [pscustomobject]@{ Ok = $done; Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Out = ((Get-Content $o -Raw) + (Get-Content $e -Raw)).Trim() }
  try { [IO.File]::Delete($o) } catch { }
  try { [IO.File]::Delete($e) } catch { }
  $r
}
function ExecCmd([string]$name, [string]$shellLine) {
  $o = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  cmd /c "`"$Exe`" machine exec --name $name -- sh -c `"$shellLine`" > `"$o`" 2>&1"
  $r = [pscustomobject]@{ Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Out = ((Get-Content $o -Raw) -replace "`r?`n", " | ").Trim() }
  [IO.File]::Delete($o)
  $r
}
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }
function Fp([string]$path) { if (Test-Path $path) { (Get-FileHash $path -Algorithm SHA256).Hash.Substring(0, 8).ToLower() } else { 'none' } }

$names = @($Accounts | ForEach-Object { "agyvm-$_" })
$free0 = FreeMB
"accounts: $($Accounts -join ', ') | free RAM at start: $free0 MB | floor: $FloorMB MB"
try {
  "== 1. start the VMs (one after another)"
  $up = @()
  foreach ($a in $Accounts) {
    $n = "agyvm-$a"
    if ((FreeMB) -lt ($FloorMB + 500)) { "  SAFETY STOP before ${n}: free RAM $(FreeMB) MB"; break }
    $s = Smol @('machine', 'start', '--name', $n) 300
    "  $n started in $($s.Secs)s | free RAM $(FreeMB) MB"
    $up += $n
  }

  "== 2. each VM sees only its own login (fingerprints, host vs inside the VM)"
  $fps = @{}
  foreach ($a in $Accounts) {
    $n = "agyvm-$a"; if ($up -notcontains $n) { continue }
    $host_fp = Fp "$Base\$a\home\.gemini\antigravity-cli\antigravity-oauth-token"
    $vm = ExecCmd $n "ls /home | tr '\n' ' '; echo; sha256sum /home/agent/.gemini/antigravity-cli/antigravity-oauth-token 2>/dev/null | cut -c1-8; ls /mnt /Users 2>&1 | head -2 | tr '\n' ' '"
    $fps[$a] = $host_fp
    "  $a : host fingerprint $host_fp | inside $n -> $($vm.Out)"
  }
  $distinct = ($fps.Values | Sort-Object -Unique).Count
  "  distinct logins: $distinct of $($fps.Count)"

  "== 3. all accounts at the same time: list models, then one small prompt each"
  $jobs = @()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($a in $Accounts) {
    $n = "agyvm-$a"; if ($up -notcontains $n) { continue }
    $jobs += Start-Job -Name $n -ArgumentList $Exe, $n -ScriptBlock {
      param($Exe, $n)
      $o = [IO.Path]::GetTempFileName(); $t = [Diagnostics.Stopwatch]::StartNew()
      cmd /c "`"$Exe`" machine exec --name $n -- sh -c `"HOME=/home/agent timeout 150 /opt/agy/agy models 2>&1 | sed -n 2p`" > `"$o`" 2>&1"
      $m = ((Get-Content $o -Raw) -replace "`r?`n", " ").Trim(); $tm = [math]::Round($t.Elapsed.TotalSeconds, 1)
      $t.Restart()
      cmd /c "`"$Exe`" machine exec --name $n -- sh -c `"HOME=/home/agent timeout 170 /opt/agy/agy -p 'Reply with exactly the single word: OK' 2>&1 | tail -3`" > `"$o`" 2>&1"
      $p = ((Get-Content $o -Raw) -replace "`r?`n", " | ").Trim(); $tp = [math]::Round($t.Elapsed.TotalSeconds, 1)
      [IO.File]::Delete($o)
      [pscustomobject]@{ VM = $n; ModelsSecs = $tm; Models = $m; PromptSecs = $tp; Prompt = $p }
    }
  }
  $null = Wait-Job -Job $jobs -Timeout 420
  foreach ($j in $jobs) {
    $r = Receive-Job $j -ErrorAction SilentlyContinue
    if ($r) { "  {0}: models {1}s -> {2}`n      prompt {3}s -> {4}" -f $r.VM, $r.ModelsSecs, $r.Models.Substring(0, [math]::Min(70, $r.Models.Length)), $r.PromptSecs, $r.Prompt.Substring(0, [math]::Min(220, $r.Prompt.Length)) }
    else { "  $($j.Name): no result (state $($j.State))" }
  }
  "  wall time for the concurrent step: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

  "== 4. memory with $($up.Count) VMs after the real agy run"
  $p = Get-Process smolvm -EA SilentlyContinue
  "  smolvm processes: $(@($p).Count), total working set $([math]::Round((($p | Measure-Object WorkingSet64 -Sum).Sum)/1MB)) MB | free RAM $(FreeMB) MB (was $free0 MB)"
  "  per process MB: " + (($p | Sort-Object WorkingSet64 -Descending | ForEach-Object { [math]::Round($_.WorkingSet64 / 1MB) }) -join ', ')
  "  login fingerprints on the host after the run: " + (($Accounts | ForEach-Object { "$_=" + (Fp "$Base\$_\home\.gemini\antigravity-cli\antigravity-oauth-token") }) -join '  ')
}
finally {
  "== 5. stop the VMs (kept, not deleted)"
  foreach ($n in $names) { Smol @('machine', 'stop', '--name', $n) 90 | Out-Null }
  "  free RAM after stopping: $(FreeMB) MB"
  "== done"
}
