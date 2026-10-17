$ErrorActionPreference = 'Continue'
$dock = "$env:ProgramFiles\Docker\Docker"
$docker = "$dock\resources\bin\docker.exe"
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }
function VmmemMB { $p = Get-Process | Where-Object { $_.Name -like 'vmmem*' }; if ($p) { [math]::Round((($p | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) } else { 0 } }
function DockerProcsMB { $p = Get-Process | Where-Object { $_.Name -like 'Docker*' -or $_.Name -like 'com.docker*' }; [pscustomobject]@{ Count = @($p).Count; MB = [math]::Round((($p | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) } }
function Snap($label) { $d = DockerProcsMB; "{0,-34} free RAM {1,5} MB | vmmem {2,5} MB | Docker Desktop processes {3} = {4} MB" -f $label, (FreeMB), (VmmemMB), $d.Count, $d.MB }

"== 1. baseline (before Docker Desktop)"
Snap 'baseline'
$b = @{ vm = VmmemMB; free = FreeMB; dk = (DockerProcsMB).MB }

"== 2. start Docker Desktop and wait for the engine (up to 4 minutes)"
Start-Process "$dock\Docker Desktop.exe" -WindowStyle Hidden
$up = $false
for ($i = 0; $i -lt 48; $i++) {
  Start-Sleep -Seconds 5
  $info = & $docker info --format '{{.ServerVersion}}' 2>$null
  if ($LASTEXITCODE -eq 0 -and $info) { $up = $true; "engine up after ~$(($i+1)*5)s: Docker $info"; break }
}
if (-not $up) { "ENGINE DID NOT START in 4 minutes (a first-run dialog may be waiting). Stopping here."; "== done"; return }
Start-Sleep -Seconds 40
Snap 'Docker Desktop idle (no containers)'
$e = @{ vm = VmmemMB; free = FreeMB; dk = (DockerProcsMB).MB }
"   => base cost of Docker Desktop: vmmem +$($e.vm - $b.vm) MB, Docker processes +$($e.dk - $b.dk) MB, free RAM -$($b.free - $e.free) MB"

"== 3. pull alpine"
& $docker pull alpine 2>&1 | Select-Object -Last 1

foreach ($n in 1, 5) {
  "== 4. $n idle container(s): alpine sleep"
  for ($i = 1; $i -le $n; $i++) { & $docker run -d --name "mem$i" alpine sleep 100000 2>&1 | Out-Null }
  Start-Sleep -Seconds 20
  Snap "Docker + $n container(s)"
  $s = @{ vm = VmmemMB; free = FreeMB }
  "   => vs engine idle: vmmem $(if (($s.vm - $e.vm) -ge 0) {'+'})$($s.vm - $e.vm) MB, free RAM change $($e.free - $s.free) MB"
  "   docker stats (memory the engine reports per container):"
  & $docker stats --no-stream --format '      {{.Name}}: {{.MemUsage}}' 2>&1 | Select-Object -First 5
  for ($i = 1; $i -le $n; $i++) { & $docker rm -f "mem$i" 2>&1 | Out-Null }
  Start-Sleep -Seconds 5
}

"== 5. shut Docker Desktop down again"
& $docker desktop stop 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds 25
Snap 'after stopping Docker Desktop'
"== done"
