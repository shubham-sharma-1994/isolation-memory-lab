#!/usr/bin/env bash
# 4 concurrent real agy sessions inside Sandlock: 2 on account a, 2 on account b. Run as the normal user in WSL.
set -u
SL=$HOME/.local/bin/sandlock
AGY=$HOME/.local/bin/agy
ACC=$HOME/agy-accounts
W=/tmp/slagy; rm -rf $W; mkdir -p $W
num() { local v="${1:-}"; if [[ "$v" =~ ^-?[0-9]+$ ]]; then echo "$v"; else echo 0; fi; }

sessions=("s1:a" "s2:a" "s3:b" "s4:b")
for s in "${sessions[@]}"; do mkdir -p $W/${s%%:*}; done

# Read-only system paths, plus the session's own working folder.
sb() { # acct workdir cmd...
  local acct=$1 wd=$2; shift 2; local H=$ACC/$acct/home
  ( cd "$wd" && exec $SL run --clean-env --env HOME=$H --env PATH=/usr/bin:/bin --env TMPDIR=$H/.tmp \
    -r /usr -r /lib -r /lib64 -r /bin -r /sbin -r /etc/ssl -r /etc/ca-certificates -r /etc/resolv.conf -r /etc/hosts -r /etc/nsswitch.conf -r /etc/passwd -r /etc/group -r /dev/urandom -r /dev/random -r /proc/self \
    -w /dev/null -w $H -w "$wd" -r $HOME/.local/bin --net-allow '*' --net-allow-bind 0 -- "$@" )
}

fp() { sha256sum $ACC/$1/home/.gemini/antigravity-cli/antigravity-oauth-token 2>/dev/null | cut -c1-8; }
echo "agy: $($AGY --version 2>&1 | head -1) | sandlock: $($SL --version 2>&1 | head -1)"
echo "login fingerprints before: a=$(fp a) b=$(fp b)"

# peak memory sampler: PSS of every agy/sandlock process of this user
sample() { local peak=0 maxn=0 tot n p v; while [ -f $W/.sampling ]; do tot=0; n=0
    for p in $(pgrep -u $(id -u) -f "$AGY|$SL"); do v=$(awk '/^Pss:/{s+=$2} END{print s+0}' /proc/$p/smaps_rollup 2>/dev/null); tot=$((tot+$(num "$v"))); n=$((n+1)); done
    [ $tot -gt $peak ] && peak=$tot; [ $n -gt $maxn ] && maxn=$n; sleep 1; done
  echo "$((peak/1024)) $maxn" > $W/peak.txt; }

parse() { # file -> "elapsed s | max RSS MB | exit"
  local f=$1; local el=$(grep -m1 'Elapsed (wall clock)' $f | sed 's/.*): //'); local rss=$(grep -m1 'Maximum resident' $f | awk '{print $NF}'); local ex=$(grep -m1 'Exit status' $f | awk '{print $NF}')
  echo "elapsed $el | max RSS $(( $(num "$rss") / 1024 )) MB | exit ${ex:-?}"; }

echo; echo "== STEP 1: agy models, 4 sessions at the same time"
touch $W/.sampling; sample & sp=$!
for s in "${sessions[@]}"; do id=${s%%:*}; ac=${s##*:}
  ( sb $ac $W/$id /usr/bin/time -v $AGY models > $W/$id.models.txt 2>&1 ) &
done; wait $(jobs -p | grep -v "^$sp$") 2>/dev/null; rm -f $W/.sampling; wait $sp 2>/dev/null
echo "peak (PSS of all agy+sandlock processes): $(cat $W/peak.txt | awk '{print $1" MB across up to "$2" processes"}')"
for s in "${sessions[@]}"; do id=${s%%:*}; ac=${s##*:}
  echo "  $id (acct $ac): $(grep -m1 -E 'gemini|Error|sign in' $W/$id.models.txt | cut -c1-60) | $(parse $W/$id.models.txt)"; done

echo; echo "== STEP 2: a real task in each session (file creation through agy's own tools), 4 at the same time"
PROMPT='Create a file named proof.txt in the current directory containing exactly the word SANDLOCK, then reply with exactly: DONE'
touch $W/.sampling; sample & sp=$!
for s in "${sessions[@]}"; do id=${s%%:*}; ac=${s##*:}
  ( sb $ac $W/$id /usr/bin/time -v timeout 170 $AGY -p "$PROMPT" --dangerously-skip-permissions > $W/$id.task.txt 2>&1 ) &
done; wait $(jobs -p | grep -v "^$sp$") 2>/dev/null; rm -f $W/.sampling; wait $sp 2>/dev/null
echo "peak (PSS of all agy+sandlock processes): $(cat $W/peak.txt | awk '{print $1" MB across up to "$2" processes"}')"
for s in "${sessions[@]}"; do id=${s%%:*}; ac=${s##*:}
  reply=$(grep -v -E '^\s*(Command being timed|User time|System time|Percent|Average|Maximum|Major|Minor|Voluntary|Involuntary|Swaps|File system|Socket|Signals|Page size|Exit status|Elapsed|\s)' $W/$id.task.txt | grep -v '^$' | tail -2 | tr '\n' ' ' | cut -c1-110)
  f="none"; [ -f $W/$id/proof.txt ] && f="$(head -c 30 $W/$id/proof.txt | tr -d '\r\n')"
  echo "  $id (acct $ac): reply: [$reply] | proof.txt: [$f] | $(parse $W/$id.task.txt)"; done

echo; echo "== STEP 3: isolation probes under the same Sandlock rules (session s1, account a)"
probe() { local label=$1; shift; r=$(sb a $W/s1 "$@" 2>&1 | head -1 | cut -c1-90); echo "  $label -> ${r:-<empty>}"; }
probe "list account b's login folder      " /bin/ls $ACC/b/home/.gemini/antigravity-cli/
probe "list the real ~/.gemini             " /bin/ls $HOME/.gemini
probe "list the Windows drive /mnt/c       " /bin/ls /mnt/c
probe "list session s2's working folder    " /bin/ls $W/s2
probe "write a file into the real HOME     " /bin/sh -c "echo x > $HOME/sandlock_escape_test && echo WROTE"
probe "list its own working folder (ok)    " /bin/ls $W/s1
echo "  other processes visible from inside: $(sb a $W/s1 /bin/sh -c 'ls /proc | grep -c "^[0-9]"' 2>&1 | head -1)"
[ -f $HOME/sandlock_escape_test ] && echo "  !! escape file exists on the host" || echo "  (no escape file was created on the host)"

echo; echo "login fingerprints after:  a=$(fp a) b=$(fp b)"
echo "leftover agy/sandlock processes: $(pgrep -u $(id -u) -fc "$AGY|$SL")"
echo "=== DONE"
