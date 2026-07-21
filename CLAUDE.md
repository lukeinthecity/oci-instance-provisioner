# Project Context — OCI Instance Provisioner

> Context + working agreement for AI coding agents (Claude Code and friends) on this repo.
> Deliberately kept tracked and public: it documents intent, hard-won gotchas, and the roadmap,
> so an agent (or a human) can pick up the project without re-deriving any of it. Keep it
> secret-free — anything user-specific belongs in the git-ignored `config.json`.

## What this is

A Windows PowerShell utility that repeatedly calls the native OCI CLI to launch an Oracle
Cloud **Always Free** Ampere A1 (ARM) instance, retrying with a randomized jitter backoff
until capacity is available, then fires an ntfy.sh push on success. It is designed to run
unattended — interactively, or as a startup Scheduled Task (current user or SYSTEM).

Current state: refactored from a single hardcoded script into a clean, configurable,
**tested** repo. Secrets are fully decoupled into a git-ignored `config.json`.

## Repo layout

| Path | Role |
|------|------|
| `OciProvisioner.ps1` | Main loop: config gate → preflight → retry/launch → validate → notify |
| `Register-ScheduledTask.ps1` | Installs the startup task (`-RunAsCurrentUser` or SYSTEM) |
| `config.json.example` | Blueprint; copied to `config.json` (ignored by git) |
| `tests/Run-IntegrationTests.ps1` | Hermetic end-to-end tests (mock `oci`, no network) |
| `docs/TEST-FLIGHT-NOTES.md` | Living lessons-learned runbook — **read this first** (see Conventions) |
| `.gitignore` / `LICENSE` | Secrets+logs excluded / MIT, © Luke Shefski |

## Design decisions & gotchas (do not regress these)

These were established (and several were *bugs discovered and fixed*) during the hardening
pass. Preserve them:

1. **Native CLI is invoked with an argument ARRAY**, not hashtable splatting:
   `& oci @LaunchArgs`. Hashtable splatting does not map to `--flags` for a native exe.
2. **`$ErrorActionPreference='Stop'` + native stderr is a trap.** With the global `Stop`,
   `& oci ... 2>&1` throws the moment the CLI writes *any* line to stderr — even on a
   **successful** launch (the OCI CLI emits non-fatal notices). That made the original
   script loop forever on an instance it had already created. The fix, which the tests
   guard: capture inside a child scope that relaxes the preference and renders stderr as
   plain text — `& { $ErrorActionPreference='Continue'; & oci @LaunchArgs 2>&1 | % { "$_" } } | Out-String`.
   **Success is decided solely by `$LASTEXITCODE -eq 0` AND a literal `*ocid1.instance.oc1*` match** (use `-like`, not regex `-match`).
3. **StrictMode-safe config access.** `Set-StrictMode -Version Latest` throws on `.Value`
   of a missing property. Read optional keys via `Get-ConfigValue` and guard
   `$Config.PSObject.Properties[$key]` before touching `.Value`.
4. **Idempotency marker.** On success the script writes `provisioner.success` and exits
   early if it already exists — so a Scheduled Task won't provision a *second* instance on
   reboot. Don't remove this without also rethinking the startup-task story.
5. **ntfy URI** is built as `"$NtfyServer/$($Config.NtfyTopic)"` — subexpression
   interpolation, no stray `$`. `NtfyServer` defaults to `https://ntfy.sh` (override to
   self-host). A failed push is logged as a warning and never masks a successful provision.
6. **Fatal setup errors** use the `Exit-Fatal` helper (clean message + `exit 1`), not
   `Write-Error` (which under `Stop` prints a noisy error blob).
7. **SYSTEM context caveat.** As SYSTEM the OCI CLI can't see the user's `~/.oci/config`;
   `OciCliConfigPath` sets `OCI_CLI_CONFIG_FILE`. Prefer `-RunAsCurrentUser`.
8. **StrictMode + scalar `.Count`.** A single-element `Where-Object`/`-split` result is a
   *scalar*, and `.Count` on a scalar throws under `Set-StrictMode -Version Latest`. Force
   list-shaped values to arrays with `@(...)` — that's why `$AvailabilityDomains` is built as
   `@(@($Config.AvailabilityDomain) | Where-Object {...})`.
9. **Native-arg JSON quoting.** `--shape-config` is JSON; PowerShell strips the double quotes
   when handing a string to a native exe, so they're escaped (`-replace '"','\"'`). The mock
   `oci` in the tests validates this via python so it can't silently regress.
10. **Permanent vs transient errors.** The loop only retries genuine capacity/throttle/5xx
    errors; auth/not-found/quota/invalid-request abort fast via `Exit-Fatal` with the real CLI
    message (so a misconfig can't masquerade as an endless "capacity" wait).
11. **Multi-AD sweep, never parallel.** `AvailabilityDomain` may be a string or a list; the
    loop tries each AD back-to-back per cycle and stops on the first success. Do NOT parallelize
    — concurrent successes would provision multiple instances and exceed the free allocation.

## Conventions

- Target **Windows PowerShell 5.1** (no PS7-only syntax) so it runs on a stock Windows box.
- Heavy, enterprise-style comments — this is a portfolio repo; keep it readable.
- **No secrets in tracked files.** Anything user-specific goes in `config.json`.
- When you change provisioning behavior, **add/adjust a scenario in
  `tests/Run-IntegrationTests.ps1`** and run it (`.\tests\Run-IntegrationTests.ps1`) before
  committing. Keep tests hermetic (mock `oci`, never hit Oracle or the public network).
- **Maintain `docs/TEST-FLIGHT-NOTES.md` as a living lessons-learned runbook.** Read it at the
  start of a session and update it the same day a new class of bug or ops gotcha is found — record
  each as *symptom → root cause → fix → lesson*. It is written to be parsed by AI agents alongside
  this file: correlating it to the code lets an assistant skip re-deriving solved problems and not
  re-introduce them. Keep it secret-free (it ships public) and linked from the README. This is a
  **per-project best practice**, not specific to this repo — start one for every project.

## Look-ahead / future work

Roughly highest-value first:

- [x] **CI**: GitHub Actions workflow running the test suite on `windows-latest` (+ status badge).
- [x] **Linting**: `PSScriptAnalyzer` runs in CI; findings cleaned up.
- [x] **AD fallback**: `AvailabilityDomain` accepts a list; the loop sweeps all ADs each cycle, and `Region` can be pinned. (Cross-*region* rotation is still open.)
- [ ] **Optional wait-for-RUNNING**: `--wait-for-state` and surface the public IP in the log/push.
- [ ] **Cross-platform**: a `pwsh` + cron path for Linux/macOS users.
- [ ] **Pester**: optionally migrate the integration suite to Pester once CI is in place.
- [ ] **Docs polish**: a short asciinema/screenshot of a successful run for the README.
- [ ] **Release hygiene**: add a `CONTRIBUTING.md` if accepting PRs; tag an initial release.
