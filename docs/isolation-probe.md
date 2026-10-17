# Isolation Probe: Hosts and Sandboxes, Measured

First measurements of how much a coding-agent process can reach under different hosts and sandboxes. Run on 2026-10-12.

## What was tested

Two sessions were started for every pairing of a **host** and a **sandbox**, each with its own HOME. Both ran a mock ACP agent (no credentials, no model calls). A probe inside each session tried to reach things it should not, and the results came back through ACP. This tests the whole path: session host, sandbox, ACP adapter.

| Axis | Values |
| --- | --- |
| Host (where the process lives, how a human can look at it) | plain process, tmux 3.6, Herdr 0.9.3 |
| Sandbox (how it is confined) | none (own HOME and scrubbed environment only), bubblewrap 0.11.1, Sandlock 0.8.9 |

Machine: WSL2 Ubuntu, Linux 6.18, 8 cores, 7 GB RAM. The harness was a small Rust program (a session host, an ACP client and a mock agent with a probe); it is not part of this repository, so this note records findings only. The Sandlock part is reproduced with real agents in `sandlock-agy.md` and `../linux-wsl/sandlock_agy4.sh`.

## Results

`allowed` means the session **can** do it. Lower is better. All three hosts gave the same answer for a given sandbox, so the table is by sandbox.

| What the session tries | none | bwrap | Sandlock |
| --- | --- | --- | --- |
| List another session's HOME (where its credentials would be) | allowed | blocked | blocked |
| List the real user's `~/.gemini` (the real Antigravity login) | allowed | blocked | blocked |
| See which sensitive entries exist in the real HOME | allowed | blocked | allowed (existence only) |
| List the Windows drive (`/mnt/c`) | allowed | blocked | blocked |
| Write a file into the real HOME or next to its own HOME | allowed, **persists on host** | allowed, private tmpfs only | blocked |
| Write into `/etc` | blocked (not root) | allowed, private tmpfs only | blocked |
| Shared `/tmp` with another session | allowed | blocked (private `/tmp`) | blocked |
| See other agents' processes | allowed (about 40 visible) | blocked (2 visible) | blocked (0 visible) |
| Reach the tmux or Herdr control sockets | allowed | blocked | blocked |
| Outbound network, network on | allowed | allowed | allowed |
| Outbound network, network off | **cannot be turned off** | blocked | blocked |

Cost of starting two sessions: process 0.03 to 0.04 s, tmux 0.10 to 0.11 s, Herdr 0.13 to 0.15 s (the first Herdr start also launches its server, about 1.9 s). The sandbox added under 0.05 s in every case.

## What this means

1. **A separate HOME and a clean environment are not a boundary.** With no sandbox, a session with its own HOME could still list the real login folder, list a peer's HOME, write to the real HOME, see every process, and reach the tmux and Herdr control sockets. This is the strongest argument for adding a real sandbox.
2. **The host does not change confinement; the sandbox does.** Process, tmux and Herdr behaved identically under the same sandbox. The host choice is about startup time, how a human watches a session, and status reporting, not security. Without a sandbox, the tmux and Herdr sockets are reachable from inside a session, so a session could read or drive the others. Never run those hosts without a sandbox.
3. **bubblewrap gives strong file, process and `/tmp` isolation, but its network control is all or nothing.** It either shares the host network or blocks it. An agent that must reach a model API cannot be limited to that one host.
4. **Sandlock gives the same file and process isolation without namespaces, and adds default-deny networking with per-host allow-lists.** It can limit a session to, for example, one API host and port. Its rules are not mount-based: the existence of paths outside the grants can still be seen (not their contents or listings), and `/tmp` is shared at the OS level, so each session needs its own temp folder inside its HOME. It needs Linux 6.12 or newer for the network rules; this WSL kernel is 6.18.
5. **Sandlock closed every gap the probe found, at near-zero cost.** Whether Docker adds anything on top was not run.

## What this does not show

- It tests what a session **can reach**, with a cooperative probe. It does not try to escape the sandbox (kernel bugs, Landlock or bubblewrap flaws).
- The agent was a mock. A real agent runs its own shell commands, so it needs more than this probe tests: package managers, git, build tools, home-directory dotfiles, DNS.
- The sandbox settings are a first cut. For example, bwrap mounts all of `/usr` read-only and Sandlock grants a fixed list of system paths.
- Resource limits (memory, processes, time) were not measured. Sandlock has flags for them; bwrap does not.
- Docker and Firecracker were not run. Firecracker needs KVM, which this WSL setup was not checked for.
- Debug builds, one machine, one run per pairing.
