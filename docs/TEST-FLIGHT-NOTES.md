# Gen 1 Test Flight — Lessons Learned

> Field notes from taking the provisioner from "code pushed to GitHub" to "running headless
> and verified on a remote, always-on PC." Written while it was fresh. The code-level fixes
> below are already committed; this doc captures *why* they were needed and the operational
> lessons that don't live in the source.

> **Purpose — written for AI agents as much as for humans.** Feed this file to an AI coding
> assistant at the *start* of a session, alongside [`CLAUDE.md`](../CLAUDE.md). Parsed against the
> codebase and directory layout, it lets the agent skip re-deriving these hard-won lessons and
> avoid re-introducing problems we already solved. Re-discovering a known pain point costs a full
> (and, for this project, slow) feedback cycle; this document is how we spend that knowledge once
> and keep it. It is a **living context primer**, not a frozen retrospective — update it whenever a
> new class of bug or operational gotcha turns up.

---

## The meta-lesson: tests prove logic, live runs prove integration

The repo ships a 37-assertion hermetic test suite that mocks the OCI CLI and proves every
code path — config gates, idempotency, success detection, backoff, error classification,
the multi-AD sweep. **Every one of those tests passed before a single real bug was found.**

That's the whole point worth internalizing: a mock can only verify the behavior you thought
to model. The bugs that actually grounded the first flights were all at the boundary between
our code and *reality* — argument quoting across the PowerShell↔native-exe seam, the real
format of OCI error payloads, the semantics of Availability Domain names, region resolution.
None of those were knowable from a mock that "returns success."

**The capacity-hunting run itself was the real integration test.** And it only worked because
a human was running it against the live remote and reading the output — the bugs surfaced from
*reality contact*, not from the test suite.

---

## Live-only bugs (the ones mocks couldn't catch)

### 1. `--shape-config` JSON got its quotes eaten
- **Symptom:** every attempt failed with `Parameter 'shape_config' must be in JSON format` and
  looped forever — *looking* like a capacity wait, but it was a permanent client-side rejection.
- **Root cause:** PowerShell strips the double quotes from a string when handing it to a *native*
  executable, so `oci` received `{ocpus:4,memoryInGBs:24}` (invalid JSON) instead of
  `{"ocpus":4,"memoryInGBs":24}`.
- **Fix:** escape the inner quotes — `(... | ConvertTo-Json -Compress) -replace '"','\"'` — so they
  survive the boundary. Verified against `python.exe` (the OCI CLI *is* Python), reproducing the
  exact arg-passing path.
- **Lesson:** passing JSON to a native CLI from PowerShell is a known sharp edge. The mock missed
  it because the fake `oci` ignored its arguments — so the test suite was hardened to validate
  `--shape-config` as real JSON.

### 2. Bare `AvailabilityDomain` → 404 on every attempt
- **Symptom:** would have looped forever once the shape-config bug was cleared.
- **Root cause:** OCI AD names carry a tenancy-specific prefix (e.g. `Uocm:US-ASHBURN-AD-1`). The
  bare `US-ASHBURN-AD-1` is never valid; the API rejects it with `404 NotAuthorizedOrNotFound`.
  The prefix is assigned per-tenancy and is **not** derivable — you must look it up.
- **Fix:** a preflight that rejects any AD without a colon and prints the exact lookup command
  (`oci iam availability-domain list --compartment-id <id> --query "data[].name" --raw-output`).
- **Lesson:** a value can pass JSON validation, pass your own checks, and still be semantically
  wrong in a way only the API knows. Fail fast with the real fix, don't retry blindly.

### 3. Region mismatch (the silent 404)
- **Root cause:** subnet/image OCIDs are region-pinned, but the region the CLI *talks to* comes
  from `~/.oci/config` unless you pass `--region`. A profile pointed at the wrong region 404s on
  every call — indistinguishable from capacity exhaustion.
- **Fix:** an optional `Region` config that gets pinned via `--region`, plus a startup warning when
  the subnet/image region tokens disagree or no region is set.
- **Lesson:** make implicit environmental dependencies explicit and loud.

### 4. Every failure was mislabeled "capacity"
- **Root cause:** the original catch block treated *any* non-zero exit as a transient capacity
  wait and retried forever. On a remote always-on PC, a misconfiguration (auth, bad AD, quota)
  would hide indefinitely behind a fake "still hunting" message.
- **Fix:** classify the real CLI output. **Permanent** errors (auth / not-found / quota / invalid
  request) abort fast via a fatal helper with the real message; only genuinely **transient** ones
  (capacity / throttle / 5xx / timeout) retry.
- **Lesson:** "retry forever" is only correct for genuinely transient failures. Everything else
  deserves to fail loudly with the truth.

### 5. StrictMode scalar `.Count` crash (caught *before* the remote)
- **Symptom:** the multi-AD feature crashed on a single-AD config with
  `The property 'Count' cannot be found on this object`.
- **Root cause:** `Where-Object` returns a *scalar* for a single match, and `.Count` on a scalar
  string throws under `Set-StrictMode -Version Latest`.
- **Fix:** force list-shaped values to arrays with `@(...)`.
- **Lesson:** this one never reached the remote because **the test suite caught it before the
  push.** That's the payoff of test-before-ship — the cheap feedback loop catching what the
  expensive one (a slow expedition cycle) would have.

---

## Reading OCI's error language

- **`"status": 500, "code": "InternalError", "message": "Out of host capacity."`** — counter-
  intuitively, capacity exhaustion arrives as an HTTP 500, *not* a 4xx. A 500 here is normal and
  expected, not a server fault on your end.
- **Client-side validation errors** (like the shape-config one) happen *before* the request ever
  reaches Oracle — so they're not capacity, they're you. The endpoint URL in the payload
  (`request_endpoint`) confirms whether a call even left the building.
- **`RequestException: ... connection ... timed out`** is a network blip, correctly treated as
  transient — the loop rode straight through one during the test flight without flinching.

---

## Deployment & operations gotchas

- **Pull the right branch.** `git pull` reported `Already up to date` while the working files were
  stale, because the checked-out branch wasn't tracking the one that received the commits. The fix
  that always works: `git fetch origin` then `git reset --hard origin/<branch>`. (Safe here —
  `config.json` and logs are git-ignored, so a hard reset never touches them.)
- **A running process holds the *old* code in memory.** `git pull` updates files on disk; it does
  not patch a process that's already running. Always **restart** after pulling.
- **`config.json` is per-machine and git-ignored.** Pulls never overwrite it; each box keeps its
  own. (This is a feature — secrets stay local — but means config fixes are done on the box, not
  in git.)
- **Foreground scripts die with the terminal.** Closing the window kills the run. To detach you
  need a real background mechanism.
- **The Scheduled Task is the right backgrounding tool** (`-RunAsCurrentUser`): it survives both
  closing the terminal *and* reboots, and runs without an interactive login. `Start-Job` does
  **not** detach — it dies with the session.
- **Never run two provisioners at once.** Two concurrent runs could both land capacity and
  provision *two* instances, blowing the Always Free 4 OCPU / 24 GB cap. Stop the foreground run
  *before* starting the task. (Same reason the AD sweep is sequential, never parallel.)
- **`Ready` ≠ `Running`.** Registering a task installs it; it doesn't start it. With an at-startup
  trigger it won't run until a reboot unless you `Start-ScheduledTask` it manually the first time.
- **A tailing log is a *viewer*, not proof of life.** `Get-Content -Wait` looks identical whether
  the process is alive or frozen. Confirm the real thing:
  `(Get-ScheduledTask -TaskName '...').State` and watch for *new* log lines with fresh timestamps.
- **Verify reboot survival by actually rebooting once.** "It should restart" is theory until you've
  power-cycled the box and watched the task come back `Running` with a post-reboot log banner.

---

## How we worked (process lessons)

- **The operator was the sensor.** The automation ran on a remote PC the assistant couldn't see;
  every live bug surfaced because a human ran it and read the output. Reality contact is a role,
  not an afterthought.
- **Batch fixes to fit the feedback loop.** Each expedition cycle is slow (clone → run → wait), so
  remaining bugs were hunted *proactively* (adversarial review surfaced the AD-prefix and
  error-classification issues) and fixed in one push, instead of discovering them one slow cycle
  at a time.
- **Test before push.** The hermetic suite is the cheap, fast loop; the live remote is the
  expensive, slow one. Catching the StrictMode bug locally is the whole argument for keeping the
  fast loop honest.

---

## Where Gen 1 stands

Running headless as a Scheduled Task, sweeping all configured Availability Domains each cycle,
classifying permanent vs transient failures, idempotent against reboots and re-runs, and set to
fire an ntfy push on success. **Live test flight in progress:** the loop is verified against the
live tenancy — real API calls, correct classification and retry of genuine capacity failures —
but a successful launch has not yet been observed. Capacity simply hasn't opened up in the target
region; the hunt continues. This doc will be updated when the first instance lands.

**Next (see the roadmap in [`CLAUDE.md`](../CLAUDE.md)):** cross-*region* rotation, and an
optional wait-for-RUNNING that surfaces the public IP in the success notification. (GitHub
Actions CI running the suite on every push — with status badge — has since shipped.)
