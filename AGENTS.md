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

Current state: a clean, configurable, **tested**, **public** repo — `v1.0.0` released. Secrets
are fully decoupled into a git-ignored `config.json`. CI, linting, secret scanning, Dependabot,
and branch protection on `main` are all live (see **CI, security & repo governance** below).

## Repo layout

| Path | Role |
|------|------|
| `OciProvisioner.ps1` | Main loop: config gate → preflight → retry/launch → validate → notify |
| `Register-ScheduledTask.ps1` | Installs the startup task (`-RunAsCurrentUser` or SYSTEM) |
| `config.json.example` | Blueprint; copied to `config.json` (ignored by git) |
| `tests/Run-IntegrationTests.ps1` | Hermetic end-to-end tests (mock `oci`, no network) |
| `docs/TEST-FLIGHT-NOTES.md` | Living lessons-learned runbook — **read this first** (see Conventions) |
| `.github/workflows/ci.yml` | CI: three required jobs — tests, PSScriptAnalyzer, gitleaks |
| `PSScriptAnalyzerSettings.psd1` | Lint ruleset consumed by the CI lint job |
| `.github/dependabot.yml` | Weekly `github-actions` dependency updates |
| `SECURITY.md` | Vulnerability disclosure policy (GitHub private reporting) |
| `.github/FUNDING.yml` | Sponsor / funding links |
| `.gitignore` / `LICENSE` | Secrets+logs, plus `.claude/` & `codex_peer_review*`, excluded / MIT, © Luke Shefski |

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
12. **Anti-idle keep-alive (`AntiIdleKeepAlive`, default `true`).** Oracle can reclaim a
    genuinely idle Always Free instance (see `docs/TEST-FLIGHT-NOTES.md`). Mitigated by baking a
    cloud-init `write_files` cron job into the launch's `user_data` (base64-encoded, passed via
    `--metadata`) that briefly burns one core every 6h so utilization never reads as idle. Reuses
    the same native-exe quote-escaping as `$ShapeConfigJson` (#9) since `--metadata` crosses the
    identical PowerShell↔native-exe boundary. Set `AntiIdleKeepAlive: false` to opt out.

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

## CI, security & repo governance

Everything here shipped during the go-public pass. An agent working on this repo **must** know:

- **CI has three required jobs** (`.github/workflows/ci.yml`), all gating merges into `main`:
  - `Integration tests (Windows PowerShell 5.1)` — runs `tests/Run-IntegrationTests.ps1` on `windows-latest`.
  - `PSScriptAnalyzer` — lints against `PSScriptAnalyzerSettings.psd1`, fails on any finding.
  - `Secret scan (gitleaks)` — runs on `ubuntu-latest` with `fetch-depth: 0`, scanning **full history** on every push/PR.
- **`main` is a protected branch.** You **cannot push to `main` directly** and **cannot merge a PR
  until all three checks are green** — the ruleset has no admin bypass. Always: branch → push →
  open PR → wait for green → merge. A direct push or an early merge is rejected with
  `405 Repository rule violations found`.
- **Never commit secrets — gitleaks fails the build**, and the scan covers history, not just the
  working tree. `config.json`, `*.pem`, `*.key`, and the SSH-key patterns are git-ignored; keep it
  that way.
- **GitHub Actions are pinned and Dependabot-managed** (`.github/dependabot.yml`, weekly). Current
  pins: `actions/checkout@v7`, `gitleaks/gitleaks-action@v3`. Let Dependabot bump these — don't
  hand-edit action versions unless fixing a break.
- **Vulnerability disclosure** goes through GitHub's private vulnerability reporting (Security tab),
  documented in `SECURITY.md` — no personal email in tracked files.
- **Releases:** `v1.0.0` is tagged. Only cut a new tag when the **provisioning logic itself** changes
  (`OciProvisioner.ps1` / `Register-ScheduledTask.ps1`); docs/CI/meta changes ride along on `main`
  without a release.

## Look-ahead / future work

The **canonical, user-facing roadmap now lives in the README** ([Roadmap](README.md#roadmap)) — keep
the two roughly in sync when scope changes. Agent-facing snapshot:

**Shipped:** CI, linting, gitleaks secret scanning, multi-AD sweep + `Region` pinning,
anti-idle keep-alive (`AntiIdleKeepAlive`), `v1.0.0`, branch protection, Dependabot, `SECURITY.md`.

**Open (highest-value first):**

- [ ] **Wait-for-RUNNING**: `--wait-for-state` and surface the public IP in the log/push.
- [ ] **Cross-region rotation**: sweep regions, not just ADs within one.
- [ ] **Cross-platform**: a `pwsh` + cron path for Linux/macOS users.
- [ ] **Pester**: optionally migrate the integration suite to Pester once time allows.
- [ ] **Docs polish**: a short asciinema/screenshot of a successful run for the README.
- [ ] **`CONTRIBUTING.md`**: add if/when accepting outside PRs.
