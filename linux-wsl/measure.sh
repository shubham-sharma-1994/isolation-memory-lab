#!/usr/bin/env bash
# Memory of N idle 256 MB guests under one VMM. Run as root inside WSL.
#   measure.sh <fc|ch|qmicro|q35> <N> [MEM_MB]
set -u
W=/root/memlab; cd $W
KIND=${1:?kind}; N=${2:?count}; MEM=${3:-256}
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
GUEST_CMD="console=ttyS0 root=/dev/vda rw init=/sbin/init panic=1"

num() { local v="${1:-}"; if [[ "$v" =~ ^-?[0-9]+$ ]]; then echo "$v"; else echo 0; fi; }
winmem()  { num "$($PS -NoProfile -NonInteractive -Command 'Get-Process | Where-Object { $_.Name -like "vmmem*" } | ForEach-Object { [math]::Round($_.WorkingSet64/1MB) }' < /dev/null 2>/dev/null | tr -d '\r' | head -1)"; }
winfree() { num "$($PS -NoProfile -NonInteractive -Command '[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB)' < /dev/null 2>/dev/null | tr -d '\r' | head -1)"; }
wslused() { free -m | awk 'NR==2{print $3}'; }
pss_mb() { local s=0 v; for p in "$@"; do v=$(awk '/^Pss:/{s+=$2} END{print s+0}' /proc/$p/smaps_rollup 2>/dev/null); s=$((s+$(num "$v"))); done; echo $((s/1024)); }
rss_mb() { local s=0 v; for p in "$@"; do v=$(awk '/^VmRSS:/{print $2}' /proc/$p/status 2>/dev/null); s=$((s+$(num "$v"))); done; echo $((s/1024)); }

fw=$(winfree)
if [ "$fw" -gt 0 ] && [ "$fw" -lt 1500 ]; then echo "ABORT: Windows free RAM $fw MB is below 1500 MB"; exit 2; fi
rm -f vm*.ext4 log*.txt vm*.json chout*.txt qout*.txt
pids=(); starts=()
sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2
base_used=$(wslused); base_win=$(winmem); base_free=$(winfree)

for i in $(seq 1 $N); do
  cp --sparse=always alpine.ext4 vm$i.ext4
  : > log$i.txt
  starts[$i]=$(date +%s.%N)
  case $KIND in
    fc)
      cat > vm$i.json <<EOF
{"boot-source":{"kernel_image_path":"$W/vmlinux","boot_args":"$GUEST_CMD pci=off"},
 "drives":[{"drive_id":"rootfs","path_on_host":"$W/vm$i.ext4","is_root_device":true,"is_read_only":false}],
 "machine-config":{"vcpu_count":1,"mem_size_mib":$MEM}}
EOF
      ./firecracker --no-api --config-file vm$i.json > log$i.txt 2>&1 < /dev/null &
      ;;
    ch)
      ./cloud-hypervisor --kernel $W/vmlinux --disk path=$W/vm$i.ext4,image_type=raw --cmdline "$GUEST_CMD" --cpus boot=1 --memory size=${MEM}M --serial file=log$i.txt --console off > chout$i.txt 2>&1 < /dev/null &
      ;;
    qmicro)
      qemu-system-x86_64 -enable-kvm -M microvm -cpu host -m $MEM -smp 1 -kernel $W/vmlinux -append "$GUEST_CMD pci=off" \
        -drive id=r$i,file=$W/vm$i.ext4,format=raw,if=none -device virtio-blk-device,drive=r$i -nodefaults -no-user-config -display none -monitor none -serial file:log$i.txt > qout$i.txt 2>&1 < /dev/null &
      ;;
    q35)
      qemu-system-x86_64 -enable-kvm -M q35 -cpu host -m $MEM -smp 1 -kernel $W/vmlinux -append "$GUEST_CMD" \
        -drive id=r$i,file=$W/vm$i.ext4,format=raw,if=none -device virtio-blk-pci,drive=r$i -nodefaults -no-user-config -display none -monitor none -serial file:log$i.txt > qout$i.txt 2>&1 < /dev/null &
      ;;
    *) echo "unknown kind $KIND"; exit 1;;
  esac
  pids[$i]=$!
done

booted=0; sumboot=0
for i in $(seq 1 $N); do
  for t in $(seq 1 180); do
    if grep -q MEMLAB-BOOTED log$i.txt 2>/dev/null; then
      e=$(echo "$(date +%s.%N) - ${starts[$i]}" | bc); sumboot=$(echo "$sumboot + $e" | bc); booted=$((booted+1)); break
    fi
    kill -0 ${pids[$i]} 2>/dev/null || break
    sleep 0.5
  done
done
echo "[$KIND N=$N] booted $booted of $N guests"
if [ $booted -lt $N ]; then
  echo "--- last lines of log1:"; tail -6 log1.txt | cut -c1-160
  for f in chout1.txt qout1.txt; do if [ -s $f ]; then echo "--- $f:"; tail -4 $f | cut -c1-160; fi; done
fi
sleep 20   # let memory settle

alive=(); for i in $(seq 1 $N); do if kill -0 ${pids[$i]} 2>/dev/null; then alive+=(${pids[$i]}); fi; done
end_used=$(wslused); end_win=$(winmem); end_free=$(winfree)
if [ ${#alive[@]} -gt 0 ]; then
  avgboot=$(echo "scale=1; $sumboot / ($booted+0.0001)" | bc)
  pss=$(pss_mb ${alive[@]}); rss=$(rss_mb ${alive[@]})
  echo "RESULT kind=$KIND N=$N alive=${#alive[@]} avg_boot_s=$avgboot vmm_pss_total_mb=$pss vmm_rss_total_mb=$rss pss_per_guest_mb=$((pss / ${#alive[@]})) wsl_used_delta_mb=$((end_used - base_used)) vmmemWSL_delta_mb=$((end_win - base_win)) win_free_delta_mb=$((base_free - end_free))"
else
  echo "RESULT kind=$KIND N=$N alive=0 (no VMM process survived)"
fi
for p in "${pids[@]}"; do kill $p 2>/dev/null; done; sleep 3; for p in "${pids[@]}"; do kill -9 $p 2>/dev/null; done
rm -f vm*.ext4 vm*.json
