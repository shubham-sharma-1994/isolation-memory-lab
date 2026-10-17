# Isolation Options, Measured on One Ground: Memory

Measured 2026-10-17. It compares every way we have looked at to run an agent on its own, on **one axis only: host RAM per isolated agent**. Scripts are in `../linux-wsl/` and `../windows/`; raw logs in `../results/`.

## The test

Every option got the same test: start **1 and then 5 idle guests, each with a 256 MB memory setting**, wait for all to be ready, let memory settle for 20 s, then read memory. Everything is torn down between runs.

- **Machine:** Windows 11 Pro, Intel i7-7700HQ (4 cores, 8 threads), 16 GB.
- **Guest:** a minimal Alpine idle system. The Linux options used one shared kernel (Linux 6.1.155 from Firecracker's CI) and one 64 MB Alpine image that prints `MEMLAB-BOOTED` and idles. smolvm and Quicksand used their own Alpine images, kernels and guest agents.
- **Where it ran:** Firecracker, Cloud Hypervisor, QEMU, Sandlock and Herdr ran **inside WSL2** (nested virtualization, `/dev/kvm` as root). smolvm, Quicksand and Docker ran **natively on Windows**.

**How memory was read.**
- Inside WSL: **PSS**, the process's real share of memory, summed over the runtime's processes (a shared page is split between its users).
- On Windows: the **working set** of the runtime's processes (shared pages are counted in full, so it reads high), plus the drop in free RAM where useful.
- The Windows-side change in the WSL VM stayed at 0 for the Linux runs: the guests fit inside memory WSL had already claimed. The cost of having WSL at all (about 0.8 to 2 GB, and not returned until `wsl --shutdown`) is **not** in the per-guest figures.

## Results

| Option | What it is | 1 guest | 5 guests (total) | Per guest at 5 | Start per guest |
| --- | --- | --- | --- | --- | --- |
| Plain process (`sleep`) | no isolation | 5 MB | 11 MB | about 2 MB | instant |
| **Sandlock** | same kernel, Landlock and seccomp | 10 MB | 20 MB | **about 4 MB** (about 2 MB over plain) | under 0.05 s (isolation-probe.md) |
| **Herdr** (server plus shells) | session host, not isolation | 37 MB | 42 MB | about 9 MB; the server is a fixed 33 MB, each workspace adds about 1 MB | n/a |
| **Docker** containers | same kernel, namespaces | 1.4 MiB per container (engine's figure) | about 6 MiB | **about 1 MiB per container** | n/a |
| **Docker Desktop** (engine, Windows) | Linux VM under Docker | **base cost +1.9 GB of free RAM** with zero containers (WSL VM +1.25 GB, Docker processes +0.83 GB) | +100 MB over the idle engine | about 8 to 25 MB per container on the host side | engine up in about 5 s |
| **Firecracker** v1.17 | one microVM each | 47 MB | 229 MB | **about 45 MB** | 1.5 s |
| **Cloud Hypervisor** v54 | one microVM each | 57 MB | 268 MB | **about 53 MB** | 1.0 to 1.1 s |
| **QEMU** 10.2, microvm machine, in WSL2 | one VM each | 107 MB | 385 MB | **about 77 MB** | 2.8 s (first cold start 10.6 s) |
| **QEMU** 10.2, q35 machine, in WSL2 | one VM each | 108 MB | 391 MB | **about 78 MB** | 1.5 to 2.1 s |
| **QEMU** 10.2.91, **q35, native Windows** (WHPX) | one VM each | 124 MB | 619 MB | **about 124 MB** | 3.8 s alone, 6.5 s each at 5 |
| **QEMU, microvm, native Windows** (WHPX) | one VM each | does not boot | does not boot | n/a | see below |
| **Cloud Hypervisor, native Windows** | n/a | cannot run | cannot run | n/a | Linux-only releases |
| **smolvm** 1.28.1 (libkrun) | one microVM each | 338 MB | about 1,130 MB | **about 226 MB** (130 to 160 MB each at 20 VMs) | 5 to 11 s |
| **Quicksand** 0.13 (QEMU on WHPX) | one VM each | 214 MB | 986 MB | **about 197 MB** | 5.1 s alone, 3.7 s each at 5 |
| SPACE (Firecracker plus PostgreSQL plus Kubernetes) | server platform | not run | not run | not run | needs Linux and KVM, so not tried |

The smolvm figures come from `smolvm-windows.md` (same 256 MB Alpine, same method) and are working sets, so they read high next to PSS.

**On Windows, all three runtimes measured the same way (working set, WHPX):** QEMU q35 with our minimal guest **124 MB**, Quicksand **197 MB**, smolvm **226 MB**. So Quicksand costs about 70 MB and smolvm about 100 MB over a bare QEMU, which is what their guest agents and fuller guest systems add. The same QEMU and guest read 78 MB in WSL2 (PSS) and 124 MB on Windows (working set), so a Windows figure is not comparable with a WSL figure.

**Notes on the Windows QEMU runs.**
- The QEMU bundled in Quicksand lacks two firmware files needed to boot a kernel file directly (`pvh.bin`, `kvmvapic.bin`). They were copied from Debian's QEMU package into a separate folder.
- q35 under WHPX needs `-accel whpx,kernel-irqchip=off` and `noapic` on the kernel command line (taken from Quicksand's own code); without them the guest hangs silently.
- **microvm does not boot on WHPX with this kernel.** Three combinations were tried: irqchip off with `noapic` (kernel crash), the default irqchip without `noapic` (kernel panic about 20 ms in, then a reboot loop, 35 boots in 90 s), and irqchip off without `noapic` (hangs after the TSC is detected). It boots fine under KVM in WSL2.
- **Cloud Hypervisor has no Windows host build.** Its releases hold only Linux binaries (`cloud-hypervisor-static`, `ch-remote`, x86-64 and aarch64), and its README says it runs on KVM or MSHV, Microsoft's hypervisor on Linux hosts. Windows is only a supported *guest*. Its WSL2 figures above are the only ones that can exist.

## What the numbers say

1. **Process-level confinement is almost free.** Sandlock adds about 2 MB per agent over a plain process. Isolation that costs nothing is possible only on Linux.
2. **A bare microVM costs about 45 to 55 MB** of host RAM with a tiny guest (Firecracker 45, Cloud Hypervisor 53), and **QEMU about 77 MB**. These are the floor for "a separate kernel per agent".
3. **smolvm and Quicksand cost about 200 MB each, but the fair comparison is on Windows.** There a bare QEMU with a minimal guest is 124 MB, so Quicksand adds about 70 MB and smolvm about 100 MB for their guest agents and fuller guest systems. Most of the gap to the 45 MB Linux microVMs is the platform and the measuring method (WHPX and working set against KVM and PSS), not the products.
4. **Docker's cost is the engine, not the containers.** An idle container is about 1 MiB, but on Windows Docker Desktop needs **about 1.9 GB** of free RAM before the first container. On native Linux there is no such base cost (not measured here).
5. **Start time:** Firecracker and Cloud Hypervisor about 1 s, QEMU 1.5 to 3 s, Quicksand about 4 s, smolvm 5 to 11 s, containers instant.
6. **Add the agent on top.** None of this includes the agent itself: `agy` takes 140 to 160 MB natively (two live sessions) and about 300 to 360 MB per smolvm VM once it has run.

## Caveats

- **Not like for like in two ways.** The Linux options share one tiny guest; smolvm and Quicksand ship their own. And PSS (Linux) against working set (Windows) differ by design.
- **The Linux options ran nested inside WSL2**, which adds overhead we did not isolate. A native Linux host would likely read the same or lower.
- **Idle guests only.** A guest that does work grows; page cache inside a guest stays resident on the host until the VM stops (seen with smolvm after `apt`).
- **One machine, one run per case**, N of 1 and 5.
- Windows free-RAM figures are noisy (other programs, standby cache); treat them as rough.

## Which could run where (checked)

| Option | Windows native | Linux | macOS |
| --- | --- | --- | --- |
| Sandlock, bubblewrap | no | yes | no |
| Firecracker | no (ran in WSL2 with KVM) | yes | no |
| Cloud Hypervisor | **no**: no Windows host build (ran only in WSL2 with KVM) | yes | no |
| QEMU | q35 yes (WHPX, measured); **microvm machine does not boot** on WHPX (tested) | yes | yes |
| smolvm | yes (WHP) | yes | Apple Silicon |
| Docker | via Docker Desktop (a VM) | yes | via a VM |
| Herdr | Windows build exists, untested | yes | yes |

## Did we use the Windows Hypervisor Platform feature?

It was enabled once by hand (admin PowerShell, then a restart; it was Disabled before). **smolvm and Quicksand used it.** Sandlock, bubblewrap, Herdr, tmux, Firecracker, Cloud Hypervisor and QEMU-in-WSL ran in WSL2, which uses its own virtualization feature. Docker Desktop also uses WSL2.

## Still unmeasured

- A real agent (`agy`, Claude Code) inside each runtime, which is what decides the true cost per isolated agent.
- Native Linux (no WSL layer) for Firecracker, Cloud Hypervisor, QEMU and Docker.
- Docker on Linux without Docker Desktop.
- SPACE.

## Reproduce

See the README. In `linux-wsl/`: `setup.sh` (downloads, run as root in WSL), `measure.sh` and `run_all.sh` (the four VMMs), `sl_herdr.sh` (Sandlock and Herdr). In `windows/`: `docker_mem.ps1`, `qs_run.ps1` with `qs_measure.py` (Quicksand), `qemu_win.ps1` (QEMU on Windows; needs the firmware folder described above), `smolvm-scale.ps1`. Raw logs of this run are in `results/`.
