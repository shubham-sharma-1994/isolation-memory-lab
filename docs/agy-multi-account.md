# Several agy Accounts: What Works Where

Written 2026-10-17 from our own tests (2026-10-12 to 2026-10-17), Google's documentation, and public issue threads. Antigravity CLI (`agy`) is the target. Using several accounts to get more quota may breach a provider's terms; this note is about isolation, not quota.

## Where agy keeps its login

| OS | Storage | Source |
| --- | --- | --- |
| Windows | Windows Credential Manager | Google's auth and troubleshooting pages |
| macOS | Keychain | Same |
| Linux | Secret Service over D-Bus | Same |
| **Any OS, when the keyring is unavailable or times out** | A file, `~/.gemini/antigravity-cli/antigravity-oauth-token` | Seen on disk in our account folders; the binary also has "falling back to file storage" paths and a "keyring timeout marker" |

A third-party blog (agentsroom.dev) says the keyring entry has one fixed name, `gemini:antigravity` on Windows, for the whole machine, with no setting to choose between several. We did not verify that, and Google has not confirmed it.

Google's docs list no setting to move the credential store. Environment variables seen in the binary and **not understood**: `AGY_ACCOUNT` and `ANTIGRAVITY_EXECUTABLE_DATA_DIR` (another multi-agent tool sets the second per instance to avoid a shared trust prompt; whether it affects the login is unknown). Per-process alternatives from the docs: a Gemini API key (`GEMINI_API_KEY` plus `modelProvider: gemini` in `settings.json`; pay-per-use billing, not the subscription) and Application Default Credentials (`AGY_ADC_AUTH=true`; Google Cloud billing).

## What we tested

| Setup | Several accounts? | Result |
| --- | --- | --- |
| **WSL2, plain**, one HOME per account | Two accounts | Both logged in independently (`agy models`). Not isolated from each other (`isolation-probe.md`) |
| **WSL2 under Sandlock**, one HOME per account | Two accounts, four sessions at once | Worked, and isolated (`sandlock-agy.md`) |
| **smolvm VM**, one VM per account, its own folder mounted | Two accounts at once | Worked, and isolated; about 300 to 360 MB per VM with agy (`smolvm-windows.md`) |
| **Native Windows** (PowerShell or cmd) | Not run; analysis only | See below |

Why the first three work: WSL and VMs have no keyring, so agy falls back to a login file inside the account's own HOME. Account folders do not collide.

## Native Windows: the likely problem (not run)

Windows always has Credential Manager, so the file fallback normally never triggers. If the entry has one fixed name per Windows user, a second login in another folder overwrites the first, whatever `HOME` or `USERPROFILE` say:

```
login A (own folder) -> Credential Manager "gemini:antigravity" = token A
login B (other folder) -> the same entry                          = token B
```

Google's own answer is for macOS only (issue 1080: run each worker with its own `HOME` and run `agy login` once in it). The Windows version of the question is issue 1261, opened 2026-10-16 with no replies when we looked, asking which of `HOME`, `USERPROFILE` and `LOCALAPPDATA` wins and whether Credential Manager entries are namespaced per profile.

**An untested lead:** the binary mentions a keyring timeout marker file, and says agy uses file storage while that marker is fresh. A per-account marker might make agy never touch Credential Manager. It depends on internal details that change between releases (agy went from 1.3.3 to 1.4.0 within days).

## Ways to run several accounts, by cost

| Way | Per account | Status |
| --- | --- | --- |
| Sandlock plus one HOME per account (Linux, WSL2) | about 4 MB over the agent | **Tested, works** |
| smolvm VM per account | 300 to 360 MB with agy | **Tested, works** |
| One Windows user per account | agent only | Probably works; not tested; needs admin and password handling |
| Gemini API key per process | agent only | Works anywhere; API billing, not the subscription |
| Keyring timeout marker (Windows) | agent only | Lead, unverified |
| Account switchers | one at a time | Not parallel |

## Google asked account a to verify itself

Sending a real prompt as account a returned "Please verify your account in your browser" with a sign-in link, in a smolvm VM **and** in WSL2 under Sandlock. Listing models worked both times. Account b answered normally in both places. So the block follows the **account**: it needs a person to complete the check in a browser, and we do not know why it was triggered. Automating accounts may meet such checks again.

## Parallel sessions do not need several accounts

Two to four sessions shared one account's login in our tests (and two live host sessions do the same). A second account adds **quota**, not parallelism. Using several accounts to get more quota is the kind of thing providers police, and Google's terms (`antigravity.google/terms`) warn that using third-party tools to access Antigravity can lead to suspension of the account.

## State

Tested on Linux/WSL2 and in smolvm VMs; native Windows is analysis only. The questions in the native Windows section are open.

## Sources

- Antigravity docs: `antigravity.google/docs/install` (authentication) and `.../cli/troubleshooting` (keyring).
- GitHub `google-antigravity/antigravity-cli`: issue 1080 (per-worker isolation, macOS), issue 1261 (Windows).
- Blog (third party, claims unverified): agentsroom.dev, "Antigravity CLI keeps one Google login per machine".
- Our runs: `isolation-probe.md`, `sandlock-agy.md`, `smolvm-windows.md`.
