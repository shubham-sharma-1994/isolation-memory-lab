# smolvm on Native Windows: Test Run

A hands-on test of smolvm (`smol-machines/smolvm`) on 2026-10-16, to decide whether agents can run in microVMs on Windows without WSL.

## Setup

| Item | Value |
| --- | --- |
| Host | Windows 11 Pro 10.0.26100, x86_64 |
| Prerequisites | Windows Hypervisor Platform enabled by hand (admin PowerShell, then a restart); Developer Mode on |
| Shell | A normal user, **not** an administrator |
| smolvm | 1.28.1, Windows zip from the GitHub release (43 MB), SHA-256 checked against the release's `checksums.sha256` |
| Install location | `%USERPROFILE%\tools\smolvm\1.28.1` (1.1 GB unpacked: two 512 MB disk templates) |
| State | `%LOCALAPPDATA%\smolvm` (cannot be moved on Windows) |

## Results

| Check | Result |
| --- | --- |
| Boots a real VM | `Linux 6.18.55 x86_64` from Windows: a separate guest kernel |
| Runs as a normal user | Yes, with WHP and Developer Mode on. smolvm's own docs had only tested an admin shell. |
| First run | 52 s, including unpacking its agent filesystem and pulling the Alpine image |
| Throwaway VM per command (`machine run`) | About 37 s each; it pulls the image again every time. Not usable per command. |
| Start a persistent VM (`machine start`) | 7 to 13 s |
| Command in a running VM (`machine exec`) | About 0.1 s; output and exit codes come back correctly (`false` returns 1) |
| Driven from Rust (`std::process::Command`) | Works. `exec` with captured output returns normally. `start` must not have its output captured through a pipe, or the caller waits until the VM dies; with stdout and stderr sent to null it returned in 7.5 s. |
| Network off (`machine run` without `--net`) | Fails: the image cannot be pulled. Offline VMs must be created from an image already on the machine. |
| RAM on the host, one VM alone | A 1 GB VM used 1.1 GB on Windows while Linux inside used about 70 MB. With several VMs running this was too pessimistic: see the 20-VM benchmark below. |
| Disk | About 2 GB really used for two VMs; the 30 to 60 GB shown is sparse files (20 GiB storage and 10 GiB overlay per VM), mostly unallocated |
| Leak | One throwaway VM from `machine run` stayed running after its command finished, with an 8 GiB allowance. It had to be stopped by hand. |
| Cleanup | `machine stop` and `machine delete` removed every VM and process |

## What it means

- **Viable on Windows** for long-lived VMs: one VM per agent, commands inside it.
- **Capacity is set by RAM, but the VM itself is cheap.** The first VM costs its allowance plus about 80 MB; later VMs cost far less (see the benchmark). What really limits the count is the agent CLI inside each VM, which was not benchmarked yet . Cloud agents (Jules) cost no local RAM, so bursts should go to them.
- **Whoever drives the VMs must own their lifecycle**: record every VM, delete it when its job ends, and reap leftovers at startup (VMs persist after the driving process exits).
- **Pre-fetch images** so agents can run with network off or allow-listed.
- **The `smolmachines` Rust crate is not an embedded engine.** Its manifest says it has no engine dependency and drives an installed `smolvm` binary, downloading one on first use.

## Benchmark: 20 VMs on one PC (2026-10-16)

Script: `../windows/smolvm-scale.ps1` (starts VMs one after another up to a target, measures each step, stops early if free RAM drops below a floor, always tears everything down). Run: `-Target 20 -MemMB 256 -FloorMB 1900`.

| | |
| --- | --- |
| Machine | Windows 11 Pro, Intel i7-7700HQ (4 cores, 8 threads), 15.9 GB RAM, 4.8 GB free at the start (Java, antivirus, Claude and Chrome were using the rest) |
| Each VM | Alpine, 256 MB memory setting, 1 vCPU, network off (image already cached), running a small loop: 200 KB of random data through `md5sum` once a second |
| Not measured | A real agent CLI inside the VM; heavy CPU work; a mounted worktree; VMs started in parallel; network on |

| VMs running | Start time of the newest VM | `exec` latency in VM 1 (median) | Host CPU | Free RAM |
| --- | --- | --- | --- | --- |
| 1 | 5.6 s | 0.11 s | 24% | 4,361 MB |
| 5 | 7.0 s | 0.09 s | 2% | 3,800 MB |
| 10 | 9.0 s | 0.09 s | 30% | 3,278 MB |
| 15 | 10.5 s | 0.16 s (max 0.26) | 20% | 2,495 MB |
| 20 | 10.8 s | 0.09 s | 4% | 1,968 MB |

- **All 20 started and ran**; the safety floor (1.9 GB free) was never hit. Inside a VM: 33 MB used of 267 MB, load average 0.01, the loop running.
- **Memory:** 20 VMs cost about **2.8 GB of free RAM in total** (4,812 to 1,968 MB). The first VM cost about 450 MB, then about **130 MB per VM** by free RAM (about 160 MB by smolvm's own working set). That is well below the 256 MB setting, so memory is not fully committed once several VMs run. The earlier "full allowance" finding came from a single VM.
- **Start time grows** from 5.6 s to about 11 s as more VMs run. Sequential start of 20 took about 3 minutes. Parallel start was not tested.
- **`exec` stays fast** at about 0.1 s regardless of how many VMs run.
- **Teardown:** stop and delete of all 20 took 13.8 s; no machines, no `smolvm` processes left; free RAM back to 4,711 MB.
- **A note on the single-VM probes before it:** a single 256 MB VM cost 338 MB and a single 512 MB VM 594 MB, so the fixed overhead per VM is about 80 MB on top of the setting.

**What it means.** Twenty sandboxed VMs are not a problem for this PC; twenty *agents* depends on what runs inside. A Node-based CLI such as Claude Code needs a larger setting than 256 MB (probably 768 MB to 1 GB, to be measured), so the real figure per agent is the guest size plus the agent's own work, not the 130 MB seen here.

## Still open

- RAM with a real agent CLI inside, and the smallest allowance that works (agy: about 300 to 360 MB per VM, see `agy-multi-account.md`).
- Whether Developer Mode is really needed.
- How a terminal or ACP session is kept alive inside a VM for a long-running agent.

## Alternatives looked at the same day

- **Quicksand** (Microsoft, QEMU, Python API, Windows via WHPX): measured in `memory-comparison.md`.
- **SPACE** (Perplexity, Firecracker): a server platform needing Linux with KVM, PostgreSQL and Kubernetes. Not a local sandbox; not run.
