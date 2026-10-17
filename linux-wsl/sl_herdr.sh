#!/usr/bin/env bash
# Memory of N sandboxed (Sandlock) or Herdr-hosted idle processes, and a plain baseline. Run as the normal user in WSL.
set -u
SL=$HOME/.local/bin/sandlock
HERDR=$(command -v herdr || ls $HOME/.local/bin/herdr $HOME/.cargo/bin/herdr 2>/dev/null | head -1)
num() { local v="${1:-}"; if [[ "$v" =~ ^-?[0-9]+$ ]]; then echo "$v"; else echo 0; fi; }
wslused() { free -m | awk 'NR==2{print $3}'; }
descendants() { local p=$1 c; echo $p; for c in $(pgrep -P $p 2>/dev/null); do descendants $c; done; }
pss_kb() { local s=0 v p; for p in "$@"; do v=$(awk '/^Pss:/{s+=$2} END{print s+0}' /proc/$p/smaps_rollup 2>/dev/null); s=$((s+$(num "$v"))); done; echo $s; }
count_procs() { echo $#; }

run_case() { # name N  ; command-start function body is passed by case below
  :
}

measure() { # label N pidlist...
  local label=$1 n=$2; shift 2
  local all=(); for p in "$@"; do for d in $(descendants $p); do all+=($d); done; done
  local uniq=($(printf "%s\n" "${all[@]}" | sort -un))
  local kb=$(pss_kb "${uniq[@]}")
  echo "RESULT kind=$label N=$n processes=${#uniq[@]} pss_total_mb=$((kb/1024)) pss_per_agent_kb=$((kb/n)) wsl_used_delta_mb=$(( $(wslused) - BASE ))"
}

cleanup_pids() { for p in "$@"; do kill $p 2>/dev/null; done; sleep 1; for p in "$@"; do kill -9 $p 2>/dev/null; done; }

for N in 1 5; do
  # ---- plain baseline: N bare sleep processes
  sync; BASE=$(wslused); pids=()
  for i in $(seq 1 $N); do /bin/sleep 100000 & pids+=($!); done
  sleep 3; measure "plain-sleep" $N "${pids[@]}"; cleanup_pids "${pids[@]}"; sleep 2

  # ---- Sandlock: N sandboxed sleeps with read-only system paths and a writable HOME
  sync; BASE=$(wslused); pids=()
  for i in $(seq 1 $N); do
    H=/tmp/slmem$i; mkdir -p $H
    $SL run --clean-env --env HOME=$H --env PATH=/usr/bin:/bin \
      -r /usr -r /lib -r /lib64 -r /bin -r /sbin -r /etc/ssl -r /etc/ca-certificates -r /etc/resolv.conf -r /etc/hosts -r /etc/nsswitch.conf -r /etc/passwd -r /etc/group -r /dev/urandom -r /dev/random -r /proc/self \
      -w /dev/null -w $H --net-allow '*' --net-allow-bind 0 -- /bin/sleep 100000 > /dev/null 2>&1 < /dev/null &
    pids+=($!)
  done
  sleep 4; alive=0; for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && alive=$((alive+1)); done
  echo "[sandlock N=$N] supervisors alive: $alive"
  measure "sandlock-sleep" $N "${pids[@]}"; cleanup_pids "${pids[@]}"; pkill -f "sleep 100000" 2>/dev/null; sleep 2
done

# ---- Herdr: one server, N workspaces each running a sleep
if [ -z "${HERDR:-}" ]; then echo "RESULT kind=herdr (binary not found in this WSL)"; exit 0; fi
echo "[herdr] binary: $HERDR ($($HERDR --version 2>&1 | head -1))"
for N in 1 5; do
  S=memlab$N
  sync; BASE=$(wslused)
  setsid nohup $HERDR --session $S server > /tmp/herdr-$S.log 2>&1 < /dev/null &
  for t in $(seq 1 30); do $HERDR --session $S workspace list > /dev/null 2>&1 && break; sleep 0.5; done
  for i in $(seq 1 $N); do
    out=$($HERDR --session $S workspace create --cwd /tmp --label w$i --no-focus 2>&1)
    pane=$(echo "$out" | grep -oE '"pane_id": *"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$pane" ] && $HERDR --session $S pane run "$pane" "sleep 100000" > /dev/null 2>&1
  done
  sleep 4
  srv=$(pgrep -f "herdr --session $S server" | head -1)
  if [ -n "${srv:-}" ]; then measure "herdr-server+shells" $N $srv; else echo "RESULT kind=herdr N=$N (server not running)"; tail -3 /tmp/herdr-$S.log; fi
  for i in $(seq 1 $N); do :; done
  pkill -f "herdr --session $S" 2>/dev/null; pkill -f "sleep 100000" 2>/dev/null; sleep 2
done
echo "=== SL+HERDR DONE"
