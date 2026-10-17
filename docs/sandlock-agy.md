# Sandlock with Real agy: Four Sessions at Once

Run 2026-10-17 to see whether Sandlock can confine real agent sessions. Earlier evidence: a cooperative probe with a mock agent (`isolation-probe.md`) and the memory comparison (`memory-comparison.md`, about 4 MB per sandboxed agent). This run adds **real agy sessions doing real work**.

## Setup

| Item | Value |
| --- | --- |
| Where | WSL2 Ubuntu, kernel 6.18.33.2, on the Windows machine used for all tests |
| Sandlock | 0.8.9, (read-only system paths, write only to the session's own HOME and working folder, `--clean-env`, `--net-allow *`, `--net-allow-bind 0`) |
| agy | 1.4.0 |
| Sessions | **4 at the same time**: s1 and s2 on account a, s3 and s4 on account b. Two sessions on one account shared that account's HOME (and so its login file); each session had its own working folder |
| Commands | Step 1: `agy models`. Step 2: a real task, `agy -p "Create a file named proof.txt in the current directory containing exactly the word SANDLOCK, then reply with exactly: DONE" --dangerously-skip-permissions`. Step 3: isolation probes under the same rules |

## Results

| Step | Session | Result |
| --- | --- | --- |
| `agy models` | all four | Passed, about 7.8 s each, all at the same time |
| Real task | **s3, s4 (account b)** | **Passed.** Both replied `DONE`; each wrote its own `proof.txt` containing `SANDLOCK` (24 s and 36 s) |
| Real task | **s1, s2 (account a)** | **Blocked by Google, not by Sandlock.** agy answered with a "verify your account in your browser" link and exited 1 after 9 to 10 s. The same block hit account a inside a smolvm VM, so it follows the account (see `agy-multi-account.md`) |

**Isolation probes** (session s1, account a, same Sandlock rules). Every attempt was refused:

| Attempt | Result |
| --- | --- |
| List account b's login folder | Permission denied |
| List the real `~/.gemini` | Permission denied |
| List the Windows drive `/mnt/c` | Permission denied |
| List session s2's working folder | Permission denied |
| Write a file into the real HOME | Permission denied (no file created on the host) |
| List `/proc` (to see other processes) | Permission denied |
| Use its own working folder | Allowed; agy's file tool wrote there |

**Memory.**

| | Per session | All four together |
| --- | --- | --- |
| `agy models` | 181 to 183 MB (peak RSS) | **419 MB** PSS across up to 12 processes |
| Real task | 190 MB (the blocked sessions), **237 to 240 MB** (the sessions that did the work) | **459 MB** PSS across up to 16 processes |

Sandlock's own share is a few MB per session (measured earlier); the agent is the cost.

**Other observations.**
- Both accounts' login files were **refreshed during the run** (a: `e75a3f55` to `7e4b68ae`, b: `4c0b9752` to `8617724e`), including with two sessions per account sharing one login file. The calls that followed still worked.
- Nothing was left running afterwards.

## What this does not show

- Account a never completed a real task. Listing models worked under Sandlock, but a full task is unproven for it until it has been verified in a browser.
- **The network was fully open.** A per-host allow-list with agy (which hosts it needs) was not tested.
- `--dangerously-skip-permissions` was needed because headless agy cannot answer prompts. Sandlock, not agy, bounds what it can do, which is the point.
- WSL2 only. Native Linux, resource limits (memory, processes, time) and long sessions were not tested.
- One run.

## Reproduce

`linux-wsl/sandlock_agy4.sh` (run as the normal user in WSL; needs `sandlock` and `agy` in `~/.local/bin` and two accounts already logged in under `~/agy-accounts/<a|b>/home`) and the log in `results/sandlock_agy4.log`.
