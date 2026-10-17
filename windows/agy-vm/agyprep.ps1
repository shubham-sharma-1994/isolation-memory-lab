param([string]$Exe, [string]$Base, [int]$MemMB = 512, [int]$FloorMB = 1500)
$ErrorActionPreference = 'Continue'

function Smol([string[]]$a, [int]$timeoutS = 180) {
  $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $Exe -ArgumentList $a -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden -PassThru
  $null = $p.Handle
  $done = $p.WaitForExit($timeoutS * 1000)
  $r = [pscustomobject]@{ Ok = ($done -and $p.ExitCode -eq 0); Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Out = ((Get-Content $o -Raw) + (Get-Content $e -Raw)).Trim() }
  Remove-Item $o, $e -EA SilentlyContinue
  $r
}
function ExecCmd([string]$name, [string]$shellLine) {
  $o = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  cmd /c "`"$Exe`" machine exec --name $name -- sh -c `"$shellLine`" > `"$o`" 2>&1"
  $r = [pscustomobject]@{ Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Out = ((Get-Content $o -Raw) -replace "`r?`n", " | ").Trim() }
  Remove-Item $o -EA SilentlyContinue
  $r
}
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }

"== 1. remove leftovers from the interrupted test"
foreach ($n in 'agyvm-a', 'agyvm-b', 'agyvm-c', 'agyvm-d', 'agyvm-e') {
  Smol @('machine', 'stop', '--name', $n) 60 | Out-Null
  $d = Smol @('machine', 'delete', '--name', $n, '--force') 60
  if ($d.Out -match 'Deleted') { "  deleted $n" }
}
Start-Sleep 2
$free0 = FreeMB
"free RAM after cleanup: $free0 MB (memory setting per VM: $MemMB MB, floor $FloorMB MB)"

foreach ($a in 'c', 'd', 'e') { New-Item -ItemType Directory -Force "$Base\$a\home" | Out-Null }

"== 2. create and start one VM per account"
$ready = @()
foreach ($a in 'a', 'b', 'c', 'd', 'e') {
  $n = "agyvm-$a"
  $f = FreeMB
  if ($f -lt ($FloorMB + 600)) { "  SAFETY STOP before ${n}: free RAM ${f} MB"; break }
  $c = Smol @('machine', 'create', '--name', $n, '--net', '--image', 'debian:stable-slim', '--mem', "$MemMB", '--cpus', '1',
    '-v', "$Base\bin:/opt/agy:ro", '-v', "$Base\$a\home:/home/agent") 120
  if ($c.Out -match 'rror') { "  create $n FAILED: " + $c.Out.Substring(0, [math]::Min(300, $c.Out.Length)); continue }
  $s = Smol @('machine', 'start', '--name', $n) 300
  "  $n started in $($s.Secs)s"
  $ready += $n
}

"== 3. install CA certificates and check agy runs in each VM"
foreach ($n in $ready) {
  $r = ExecCmd $n "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq ca-certificates >/dev/null 2>&1; ls /etc/ssl/certs/ca-certificates.crt"
  $v = ExecCmd $n "HOME=/home/agent /opt/agy/agy --version 2>&1 | head -1"
  $k = ExecCmd $n "uname -r; id -un; ls /home | tr '\n' ' '"
  "  $n  certs: $($r.Out)  | agy: $($v.Out)  | kernel/user/home: $($k.Out)"
}

"== 4. the two saved accounts (a, b): does their login work inside the VM?"
foreach ($n in 'agyvm-a', 'agyvm-b') {
  if ($ready -notcontains $n) { continue }
  $m = ExecCmd $n "HOME=/home/agent /opt/agy/agy models 2>&1 | head -3"
  "  $n -> $($m.Secs)s  $($m.Out)"
}
"== state"
"VMs running: $($ready.Count); host RAM used by them: $($free0 - (FreeMB)) MB; free RAM now: $(FreeMB) MB"
