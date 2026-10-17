# isolation-memory-lab

Open research notes and scripts from a personal investigation: **how much host memory does it cost to run each coding agent in its own sandbox or VM, and does the sandbox really stop it?** Everything here was run by hand on one Windows 11 laptop (i7-7700HQ, 16 GB, WSL2), with one run per case. Treat the numbers as a starting point and re-run them on your own machine.

Two axes were measured:

1. **Memory per isolated guest** (idle Alpine guest, 256 MB setting, 1 and 5 guests): Sandlock, Herdr, Docker, Firecracker, Cloud Hypervisor, QEMU, Quicksand, smolvm.
2. **Real agent sessions inside the sandbox**: four `agy` (Antigravity CLI) sessions on two accounts under Sandlock, and two accounts in two smolvm VMs: do they work, and can one session reach another's login?

## Headline results

| Option | Host RAM per guest (5 running) |
| --- | --- |
| Plain process | about 2 MB |
| Sandlock (Landlock + seccomp, Linux only) | about 4 MB |
| Docker container (engine not counted) | about 1 MiB; Docker Desktop on Windows needs about 1.9 GB first |
| Firecracker microVM | about 45 MB |
| Cloud Hypervisor microVM | about 53 MB (Linux hosts only) |
| QEMU microVM or q35 in WSL2 | about 77 MB |
| QEMU q35 on native Windows (WHPX) | about 124 MB |
| Quicksand (QEMU on WHPX) | about 197 MB |
| smolvm (libkrun, Windows/Linux/macOS) | about 130 to 226 MB |

Plus the agent itself: `agy` took 140 to 160 MB natively and about 300 to 360 MB per smolvm VM. Full table, method and caveats: [`docs/memory-comparison.md`](docs/memory-comparison.md).

## Notes

| File | What |
| --- | --- |
| [`docs/memory-comparison.md`](docs/memory-comparison.md) | The memory table, how it was measured, what runs where |
| [`docs/smolvm-windows.md`](docs/smolvm-windows.md) | smolvm on native Windows, including a 20-VM benchmark |
| [`docs/sandlock-agy.md`](docs/sandlock-agy.md) | Four real `agy` sessions in Sandlock, with isolation probes |
| [`docs/agy-multi-account.md`](docs/agy-multi-account.md) | Where `agy` keeps its login and which setups allow several accounts |
| [`docs/isolation-probe.md`](docs/isolation-probe.md) | What a process can reach with no sandbox, bubblewrap or Sandlock (tmux, Herdr, plain process hosts) |

Raw logs of our runs are in [`results/`](results/).

## Run it yourself

Linux or WSL2 (`linux-wsl/`):

```bash
sudo ./linux-wsl/setup.sh          # as root; downloads Firecracker, Cloud Hypervisor, a kernel, Alpine, installs QEMU (work dir /root/memlab)
sudo ./linux-wsl/run_all.sh        # Firecracker, Cloud Hypervisor, QEMU microvm and q35 at 1 and 5 guests
./linux-wsl/sl_herdr.sh            # Sandlock and Herdr (needs sandlock and herdr installed)
./linux-wsl/sandlock_agy4.sh       # 4 real agy sessions under Sandlock (needs agy logged in under ~/agy-accounts/<a|b>/home)
```

`setup.sh`, `measure.sh` and `run_all.sh` expect to live in `/root/memlab`; copy the scripts there. Nested virtualization needs `/dev/kvm` (in WSL2, run as root).

Windows (`windows/`, PowerShell):

```powershell
.\windows\smolvm-scale.ps1 -Exe C:\path\to\smolvm.exe -Target 20 -MemMB 256 -FloorMB 1900
.\windows\docker_mem.ps1                 # Docker Desktop idle cost and containers
.\windows\qs_run.ps1                     # Quicksand (needs uv)
.\windows\qemu_win.ps1 -Qemu <qemu-system-x86_64.exe> -Firmware <dir> -Assets <dir>   # QEMU on WHPX
.\windows\agy-vm\agyprep.ps1 -Exe C:\path\to\smolvm.exe -Base <dir>                  # agy in smolvm VMs
```

smolvm needs the Windows Hypervisor Platform turned on (admin PowerShell, then restart) and Developer Mode.

The scripts stop early when free RAM falls under a floor you can set, and tear down what they start. Read a script before running it: they start VMs and processes on your machine.

## Credentials

The `agy` scripts work on **your own** login files in folders you create. Never commit those folders: they hold OAuth tokens. The logs in `results/` only contain short fingerprints of the files, and sign-in links were removed.

## Limits

One machine, one run per case, idle guests (except the `agy` runs), a Windows working set compared against Linux PSS. See each note's "Caveats" or "What this does not show".

## Licence

MIT for the scripts and notes. The tools measured (smolvm, Firecracker, Sandlock, QEMU, etc.) have their own licences.
