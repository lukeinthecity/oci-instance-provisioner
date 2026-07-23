# OCI Instance Provisioner

> A resilient PowerShell utility that automatically grabs an Oracle Cloud **Always Free** Ampere A1 (ARM) compute instance the moment capacity becomes available — and pings your phone when it lands.

[![CI](https://github.com/lukeinthecity/oci-instance-provisioner/actions/workflows/ci.yml/badge.svg)](https://github.com/lukeinthecity/oci-instance-provisioner/actions/workflows/ci.yml)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Why this exists

Oracle Cloud's [Always Free tier](https://www.oracle.com/cloud/free/) includes a genuinely
generous ARM allocation (up to 2 OCPUs and 12 GB of RAM on `VM.Standard.A1.Flex` — Oracle
lowered this from 4/24 in 2026). The catch:
the popular regions are almost always **"Out of host capacity"**, so a one-shot `launch` call
usually fails. Capacity frees up unpredictably — often for just a few seconds at a time.

This tool turns that frustrating game of refresh-and-retry into a hands-off background job. It
loops the native OCI CLI launch call with a polite randomized backoff, validates that a *real*
instance was created (not just a non-error response), and notifies you via [ntfy.sh](https://ntfy.sh)
the instant it succeeds.

> **Use responsibly.** This is a personal-use retry helper for resources you're entitled to under
> the Always Free tier. The built-in jitter backoff exists specifically so you don't hammer
> Oracle's API. Respect the [Oracle Cloud Terms of Service](https://www.oracle.com/contracts/cloud-services/).

## Features

- **Zero secrets in code** — all infrastructure parameters live in a git-ignored `config.json`.
- **Strict success validation** — only exits when the response contains a genuine `ocid1.instance.oc1…` OCID; every other outcome (including non-zero CLI exit codes) is retried.
- **Randomized jitter backoff** — configurable base delay plus random pad, to spread out retries.
- **Push notifications** — fires an unauthenticated ntfy.sh push on success.
- **Survives reboots** — ships with a helper to register it as a Scheduled Task (as your own user or SYSTEM).
- **Idempotent** — writes a success marker so a reboot won't accidentally provision a *second* instance.
- **Durable logging** — writes a timestamped `provisioner.log` so headless runs are auditable.
- **Fail-fast preflight** — missing CLI, config, or SSH key stops immediately instead of looping forever.

## Prerequisites

1. **Windows + PowerShell 5.1+** (built into Windows 10/11).
2. **OCI CLI** installed and configured:
   ```powershell
   # Install (see official docs for the latest one-liner)
   # https://docs.oracle.com/iaas/tools/oci-cli/latest/
   oci setup config      # generates your API key + ~/.oci/config
   ```
   Verify it works: `oci os ns get` should return your tenancy namespace.
3. **An SSH public key** (`.pub`) to inject into the instance. Generate one with `ssh-keygen` if needed.

## Setup

```powershell
# 1. Clone
git clone https://github.com/lukeinthecity/oci-instance-provisioner.git
cd oci-instance-provisioner

# 2. Create your local config from the template
Copy-Item .\config.json.example .\config.json

# 3. Edit config.json with your real values (see the table below)
notepad .\config.json
```

### Configuration reference

| Key                  | Required | Description                                                                 | Where to find it |
|----------------------|:--------:|-----------------------------------------------------------------------------|------------------|
| `CompartmentId`      | ✅       | OCID of the compartment to launch into (often your root tenancy OCID).      | Console → Identity → Compartments, or `oci iam compartment list` |
| `SubnetId`           | ✅       | OCID of the subnet for the instance's VNIC.                                 | Console → Networking → VCN → Subnets |
| `ImageId`            | ✅       | OCID of the OS image (e.g. an aarch64 Ubuntu/Oracle Linux build).           | `oci compute image list --compartment-id <id> --shape VM.Standard.A1.Flex` |
| `AvailabilityDomain` | ✅       | **Full** AD name(s) incl. the tenancy prefix (e.g. `Uocm:US-ASHBURN-AD-1`) — bare `US-ASHBURN-AD-1` is rejected. A **single string** polls one AD; a **JSON array** sweeps several each cycle (see below). | `oci iam availability-domain list --compartment-id <id> --query "data[].name" --raw-output` |
| `SshKeyPath`         | ✅       | Local path to your **public** key (`.pub`).                                 | e.g. `C:\Users\you\.ssh\id_ed25519.pub` |
| `NtfyTopic`          | ✅       | A unique ntfy.sh topic string. Subscribe to it in the ntfy app first.       | You pick it — make it long/random so it stays private |
| `Region`             | ⬜†      | Target region (e.g. `us-ashburn-1`). Must match your Subnet/Image/AD. If blank, the CLI's `~/.oci/config` region is used. | `oci iam region-subscription list` |
| `Shape`              | ⬜       | Compute shape. Default `VM.Standard.A1.Flex`.                               | — |
| `Ocpus` / `MemoryInGBs` | ⬜    | Flex shape sizing. Defaults `2` / `12` (full free allocation).             | — |
| `DisplayName`        | ⬜       | Instance display name. Default `oci-free-arm-instance`.                      | — |
| `AssignPublicIp`     | ⬜       | Whether to assign a public IP. Default `true`.                              | — |
| `AntiIdleKeepAlive`  | ⬜       | Bakes a cloud-init cron job into the launch that briefly burns one core every 6h, so Oracle's idle-instance reclamation never sees a genuinely idle box. Default `true`; set `false` to opt out. | — |
| `WaitForRunning`     | ⬜       | After launch, wait for the instance to reach RUNNING and put its **public IP** in the log + push. Default `false`. | — |
| `WaitTimeoutSeconds` | ⬜       | Max seconds to wait for RUNNING when `WaitForRunning` is on. Default `600`.  | — |
| `NtfyServer`         | ⬜       | ntfy base URL. Default `https://ntfy.sh`. Override to self-host.            | — |
| `BaseDelaySeconds`   | ⬜       | Base backoff between retries. Default `60`.                                 | — |
| `JitterSeconds`      | ⬜       | Max random jitter added to the base delay. Default `30`.                    | — |
| `OciCliConfigPath`   | ⬜       | Absolute path to your `~/.oci/config`. Only needed for **SYSTEM** runs (see below). | — |
| `LogPath`            | ⬜       | Custom log file path. Default: `provisioner.log` next to the script.        | — |
| `SuccessMarkerPath`  | ⬜       | Sentinel file written on success (enables idempotency). Default: `provisioner.success`. | — |

> † `Region` is technically optional but **strongly recommended** — leaving it blank relies on your `~/.oci/config` default, and a region mismatch fails on every attempt.

> `config.json`, `provisioner.log`, `provisioner.success`, and key files are all in `.gitignore` — they will never be committed.

### Polling one vs. multiple Availability Domains

Capacity frees up in different ADs at different moments, so your odds improve if you watch more
than one. It's your choice, set entirely by how you write `AvailabilityDomain`:

```jsonc
// One AD (default):
"AvailabilityDomain": "Uocm:US-ASHBURN-AD-1"

// Several — swept back-to-back each cycle, first one with capacity wins:
"AvailabilityDomain": ["Uocm:US-ASHBURN-AD-1", "Uocm:US-ASHBURN-AD-2", "Uocm:US-ASHBURN-AD-3"]
```

With a list, each retry cycle tries every AD in turn **with no delay between them**, stops the
instant one yields an instance, and only then backs off before the next sweep. They're tried
sequentially (never in parallel) on purpose — two simultaneous successes would provision two
instances and exceed the Always Free allocation.

## Usage

### Run it interactively

```powershell
.\OciProvisioner.ps1
```

You'll see timestamped attempts scroll by. Leave the window open; it stops on the first success
and sends your ntfy push.

By default the script reads `config.json` next to it. To point at a config stored elsewhere
(handy for the Scheduled-Task setup, or running multiple targets from separate configs), pass
`-ConfigPath`:

```powershell
.\OciProvisioner.ps1 -ConfigPath 'D:\secrets\oci.json'
```

### Run it as a background Scheduled Task

So it keeps running after reboots / power loss, register it from an elevated (Administrator)
PowerShell prompt. Two modes:

```powershell
# Least-privilege (recommended): runs as your own account, "whether logged on or not".
.\Register-ScheduledTask.ps1 -RunAsCurrentUser

# Or as NT AUTHORITY\SYSTEM (the original setup):
.\Register-ScheduledTask.ps1

Start-ScheduledTask -TaskName 'OCI-Instance-Provisioner'
```

Then just watch the log:

```powershell
Get-Content .\provisioner.log -Wait -Tail 20
```

> [!IMPORTANT]
> **The task fires on every startup, and the script keeps no memory of past success — except
> via its marker file.** A `provisioner.success` marker is written when an instance is secured;
> on subsequent runs the script sees it and exits without provisioning again. **Keep that marker
> (don't `.gitignore`-clean it away) or unregister the task once you've got your instance**,
> otherwise a reboot after deleting the marker would launch *another* instance and could exhaust
> your free-tier quota.

> [!WARNING]
> **Running as SYSTEM is a privilege/credentials trade-off.** (1) SYSTEM executes this script at
> every boot with `-ExecutionPolicy Bypass`, so ensure only administrators can write to the repo
> folder. (2) The OCI CLI looks for credentials in the *running user's* profile, so as SYSTEM it
> won't find the `~/.oci/config` you created — set `OciCliConfigPath` in `config.json` to that
> file's absolute path. Prefer `-RunAsCurrentUser` to avoid both issues.

To remove the task once you've got your instance:

```powershell
Unregister-ScheduledTask -TaskName 'OCI-Instance-Provisioner' -Confirm:$false
```

## Notifications via ntfy.sh

[ntfy.sh](https://ntfy.sh) is a free, no-signup push service.

1. Install the ntfy app (iOS / Android / web).
2. **Subscribe** to the exact topic string you put in `NtfyTopic`.
3. That's it — on success you'll get a push titled *"OCI Instance Secured"*.

> Topics are public by anyone who knows the string, so choose something long and unguessable.
> Running your own ntfy server? Set `NtfyServer` in `config.json` to its base URL.
> Turn on `WaitForRunning` and the push includes the instance's **public IP** — so the notification tells you exactly where to SSH.

## How it works

```
load config.json (PSScriptRoot) ─▶ already provisioned? (marker exists) ─▶ exit 0
        │                                       │ no
        ▼                                       ▼
 preflight (CLI? config valid? SSH key?) ── fail ▶ clean error + exit 1
        │ ok
        ▼
   ┌─────────────────────  retry loop  ─────────────────────┐
   │  oci compute instance launch  (args passed as array)   │
   │             │                                          │
   │   contains "ocid1.instance.oc1" AND exit code 0?       │
   │        │ yes                        │ no               │
   │        ▼                            ▼                  │
   │  write marker + ntfy + break  sleep(base + jitter) ────┘
   └────────────────────────────────────────────────────────┘
```

> Native `oci` stderr is captured as plain text (not promoted to a terminating error), so a
> successful launch that also prints a harmless warning is still detected — success is decided
> solely by the exit code plus a literal `ocid1.instance.oc1` match.
>
> A confirmed launch means OCI *accepted* the request; the instance is still provisioning.
> With `WaitForRunning` on, the script additionally waits for RUNNING and resolves the public
> IP (best-effort — a hiccup here never undoes the already-confirmed success).

## Project layout

```
oci-instance-provisioner/
├─ OciProvisioner.ps1          # Main provisioning loop
├─ Register-ScheduledTask.ps1  # One-time scheduled-task installer (user or SYSTEM)
├─ config.json.example         # Configuration blueprint (copy → config.json)
├─ tests/
│  └─ Run-IntegrationTests.ps1 # Hermetic end-to-end tests (mock oci, no network)
├─ docs/
│  └─ TEST-FLIGHT-NOTES.md     # Lessons-learned runbook (for humans + AI agents)
├─ .gitignore                  # Keeps secrets/logs out of git
├─ LICENSE                     # MIT
└─ README.md
```

## Tests

A hermetic integration suite mocks the OCI CLI and points notifications at a closed local
port, so it never touches Oracle Cloud or the network. Run it any time:

```powershell
.\tests\Run-IntegrationTests.ps1
```

It covers the config gate, placeholder detection, idempotency, the success path (including
the stderr-handling fix), and the failure → backoff path. It exits non-zero on any failure,
so it drops cleanly into CI.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `The OCI CLI ('oci') was not found on PATH` | Install the OCI CLI and reopen your shell. |
| `config.json could not be parsed as valid JSON` | Check for trailing commas / unescaped backslashes in paths (use `\\`). |
| `AvailabilityDomain ... is missing its tenancy prefix` | Use the **full** AD name (e.g. `Uocm:US-ASHBURN-AD-1`) from `oci iam availability-domain list`. |
| Loops forever with `Out of host capacity` | Working as intended — capacity is genuinely unavailable. Leave it running. |
| **Aborts** with a "permanent error" (auth / not-found / quota / invalid request) | Not a capacity issue — the script now fails fast and prints the real CLI error. Fix the config and re-run. |
| Aborts citing the Always Free A1 limit | You already have an A1 instance (cap is 2 OCPU / 12 GB per tenancy). Terminate it, or lower `Ocpus`/`MemoryInGBs`. |
| Repeated 404s / `NotAuthorizedOrNotFound` | Region mismatch — set `Region` in `config.json` to match your Subnet/Image/AD, and run `oci setup config` to confirm auth. |
| Auth errors **only** under the SYSTEM Scheduled Task | SYSTEM can't see your user's `~/.oci/config`. Set `OciCliConfigPath` in `config.json`, or register with `-RunAsCurrentUser`. |
| No ntfy push but instance created | Confirm you subscribed to the **same** topic string; check the log for the warning line. |

## Lessons learned

[**docs/TEST-FLIGHT-NOTES.md**](docs/TEST-FLIGHT-NOTES.md) is the field-notes runbook from taking
Gen 1 from "pushed" to "verified flying": the live-only bugs (the ones the mocked tests couldn't
catch), how to read OCI's error language, the deployment & ops gotchas, and the process lessons —
each as *symptom → root cause → fix → lesson*.

It's written for **humans and AI agents alike**: feed it to a coding assistant alongside
[`AGENTS.md`](AGENTS.md) at the start of a session so it can correlate the lessons to the code and
directory and avoid re-introducing solved problems.

## Roadmap

Where the project has been and where it's going, roughly highest-value first. Everything under
**Shipped** is live on `main`; **Planned** items are open — issues and PRs welcome.

**Shipped**

- [x] **CI** — GitHub Actions runs the hermetic suite on `windows-latest` on every push (status badge up top).
- [x] **Linting** — `PSScriptAnalyzer` runs in CI, findings kept clean.
- [x] **Secret scanning** — gitleaks scans the full history on every push/PR, as a backstop to `.gitignore`.
- [x] **Multi-AD fallback** — `AvailabilityDomain` takes a list and the loop sweeps every AD each cycle; `Region` can be pinned.
- [x] **Anti-idle keep-alive** — cloud-init cron baked into the launch so Oracle's idle-instance reclamation never sees a genuinely idle box (opt-out via `AntiIdleKeepAlive: false`).
- [x] **v1.0.0** — first tagged release.
- [x] **Wait-for-RUNNING** — optional `--wait-for-state RUNNING` + public IP surfaced in the log and the ntfy push (opt-in via `WaitForRunning: true`).

**Planned**

- [ ] **Cross-region rotation** — sweep multiple regions, not just multiple ADs within one.
- [ ] **Cross-platform** — a `pwsh` + cron path so Linux/macOS users can run it too.
- [ ] **Pester** — optionally migrate the integration suite to Pester.
- [ ] **Docs polish** — an asciinema clip or screenshot of a successful run.
- [ ] **`CONTRIBUTING.md`** — a contribution guide if/when outside PRs are accepted.

## License

[MIT](LICENSE) © 2026 Luke Shefski
