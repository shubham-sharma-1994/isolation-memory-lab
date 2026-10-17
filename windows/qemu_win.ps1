param([string]$Qemu, [string]$Firmware, [string]$Assets, [int]$MemMB = 256)
$ErrorActionPreference = 'Continue'
$work = "$env:TEMP\memlab-qwork"; New-Item -ItemType Directory -Force $work | Out-Null
function FreeMB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) }
function Fwd([string]$p) { $p -replace '\\', '/' }
$cmdline = 'console=ttyS0 root=/dev/vda rw init=/sbin/init panic=1 noapic'

foreach ($kind in 'q35', 'microvm') {
  foreach ($n in 1, 5) {
    if ((FreeMB) -lt 1800) { "SKIP $kind N=${n}: free RAM $(FreeMB) MB is below 1800 MB"; continue }
    Get-ChildItem $work -File -EA SilentlyContinue | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch { } }
    $free0 = FreeMB; $procs = @(); $starts = @()
    for ($i = 1; $i -le $n; $i++) {
      Copy-Item "$Assets\alpine.ext4" "$work\vm$i.ext4"
      [IO.File]::WriteAllText("$work\log$i.txt", "")
      $common = @('-accel', 'whpx,kernel-irqchip=off', '-m', "$MemMB", '-smp', '1', '-kernel', (Fwd "$Assets\vmlinux"), '-L', (Fwd $Firmware),
                  '-drive', "id=r$i,file=$(Fwd "$work\vm$i.ext4"),format=raw,if=none", '-nodefaults', '-no-user-config',
                  '-display', 'none', '-monitor', 'none', '-serial', "file:$(Fwd "$work\log$i.txt")")
      if ($kind -eq 'q35') { $args2 = @('-M', 'q35') + $common + @('-device', "virtio-blk-pci,drive=r$i", '-append', "`"$cmdline`"") }
      else                 { $args2 = @('-M', 'microvm') + $common + @('-device', "virtio-blk-device,drive=r$i", '-append', "`"$cmdline pci=off`"") }
      $starts += [Diagnostics.Stopwatch]::StartNew()
      $procs += Start-Process -FilePath $Qemu -ArgumentList $args2 -RedirectStandardOutput "$work\qout$i.txt" -RedirectStandardError "$work\qerr$i.txt" -WindowStyle Hidden -PassThru
    }
    $booted = 0; $sum = 0.0
    for ($i = 0; $i -lt $n; $i++) {
      for ($t = 0; $t -lt 180; $t++) {
        if ((Get-Content "$work\log$($i+1).txt" -Raw -EA SilentlyContinue) -match 'MEMLAB-BOOTED') { $booted++; $sum += $starts[$i].Elapsed.TotalSeconds; break }
        if ($procs[$i].HasExited) { break }
        Start-Sleep -Milliseconds 500
      }
    }
    "[$kind N=$n] booted $booted of $n"
    if ($booted -lt $n) {
      "  --- first guest log tail:"; (Get-Content "$work\log1.txt" -Tail 4 -EA SilentlyContinue) | ForEach-Object { "     $_" }
      "  --- qemu stderr:"; (Get-Content "$work\qerr1.txt" -Tail 4 -EA SilentlyContinue) | ForEach-Object { "     $_" }
      "  exited: " + (($procs | ForEach-Object { $_.HasExited }) -join ',')
    }
    Start-Sleep -Seconds 20
    $alive = @($procs | Where-Object { -not $_.HasExited })
    if ($alive.Count -gt 0) {
      $ws = 0; foreach ($p in $alive) { $ws += (Get-Process -Id $p.Id -EA SilentlyContinue).WorkingSet64 }
      $ws = [math]::Round($ws / 1MB); $free1 = FreeMB
      "RESULT kind=win-qemu-$kind N=$n alive=$($alive.Count) avg_boot_s=$([math]::Round($sum / [math]::Max($booted,1),1)) qemu_working_set_total_mb=$ws per_guest_mb=$([math]::Round($ws / $alive.Count)) win_free_delta_mb=$($free0 - $free1)"
    } else { "RESULT kind=win-qemu-$kind N=$n alive=0 (no QEMU process survived)" }
    foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Start-Sleep -Seconds 4
  }
}
"leftover qemu processes: " + @(Get-Process | Where-Object { $_.Name -like 'qemu*' }).Count
"== done"
