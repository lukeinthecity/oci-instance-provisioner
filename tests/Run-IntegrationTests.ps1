#Requires -Version 5.1
<#
.SYNOPSIS
    Hermetic integration tests for OciProvisioner.ps1.

.DESCRIPTION
    Exercises the assembled script end-to-end WITHOUT touching Oracle Cloud or the
    network. The OCI CLI is replaced with a local 'oci.cmd' stub on PATH, and ntfy is
    pointed at a closed localhost port so a "successful" run never publishes a real push.

    Each scenario runs the real script in a child PowerShell process and asserts on its
    exit code, console output, the success-marker file, and the durable log. The script
    exits non-zero if any assertion fails, so it is safe to wire into CI.

.EXAMPLE
    .\tests\Run-IntegrationTests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Resolve the script under test relative to this file (no hard-coded paths).
$ScriptUnderTest = (Resolve-Path (Join-Path $PSScriptRoot '..\OciProvisioner.ps1')).Path
$ExampleConfig   = (Resolve-Path (Join-Path $PSScriptRoot '..\config.json.example')).Path
$SandboxRoot     = Join-Path $env:TEMP ('ociprov_tests_{0}' -f $PID)

# ---- tiny assertion harness ------------------------------------------------
$script:Pass = 0
$script:Fail = 0
function Assert($Condition, $Message) {
    if ($Condition) {
        $script:Pass++
        Write-Host "    [PASS] $Message" -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host "    [FAIL] $Message" -ForegroundColor Red
    }
}

# ---- fixtures --------------------------------------------------------------
function New-TestDir([string]$Name) {
    $d = Join-Path $SandboxRoot $Name
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Copy-Item $ScriptUnderTest (Join-Path $d 'OciProvisioner.ps1')
    return $d
}
function New-SuccessOci([string]$Dir) {
    # A stub OCI CLI: prints a real-looking instance OCID to stdout AND a harmless
    # notice to stderr, then exits 0 -- the exact shape that broke the original script.
    # When python is present (the real OCI CLI requires it), the stub also validates that
    # --shape-config survived the PowerShell -> native-exe boundary as real JSON, so a
    # regression in quote-escaping makes this stub exit 1 just like the real CLI does.
    @'
import sys, json, base64
a = sys.argv[1:]
try:
    json.loads(a[a.index("--shape-config") + 1])
except Exception:
    sys.exit(3)
# --metadata is optional (anti-idle keep-alive can be disabled); only validate when
# present. Same native-exe quote-escaping boundary as --shape-config, so this is an
# identical regression guard: confirm it survived as real JSON AND that the
# base64-encoded user_data decodes back to the cloud-init content we expect.
if "--metadata" in a:
    try:
        meta = json.loads(a[a.index("--metadata") + 1])
        decoded = base64.b64decode(meta["user_data"]).decode("utf-8")
        assert "cloud-config" in decoded
    except Exception:
        sys.exit(4)
sys.exit(0)
'@ | Set-Content -Path (Join-Path $Dir 'validate_shape.py') -Encoding ASCII
    @'
@echo off
echo oci-was-called>> "%~dp0oci_called.txt"
echo %* >> "%~dp0oci_args.txt"
where python >nul 2>nul
if errorlevel 1 goto emit
python "%~dp0validate_shape.py" %*
if errorlevel 1 (
  echo ServiceError: launch argument failed validation ^(shape_config or metadata^). 1>&2
  exit /b 1
)
:emit
echo {"data": {"id": "ocid1.instance.oc1.iad.aaaaexamplefake"}}
echo WARNING: a harmless non-fatal notice 1>&2
exit /b 0
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-FailingOci([string]$Dir) {
    # Simulates "Out of host capacity": writes to stderr and exits non-zero.
    @'
@echo off
echo ServiceError: Out of host capacity. 1>&2
exit /b 1
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-PermanentlyFailingOci([string]$Dir) {
    # Simulates a non-retryable error (bad AD / auth / not found): the API returns
    # 404 NotAuthorizedOrNotFound. The script must FAIL FAST, not loop on "capacity".
    @'
@echo off
echo oci-was-called>> "%~dp0oci_called.txt"
echo ServiceError: NotAuthorizedOrNotFound. Authorization failed or requested resource not found. 1>&2
exit /b 1
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-CliUsageErrorOci([string]$Dir) {
    # Simulates the real-world bug this scenario guards against: a stale/buggy script splices
    # an entire multi-AD array into a single --availability-domain argument, and the OCI CLI
    # (a Click app) rejects it as a usage error BEFORE ever making an API call. The script must
    # treat this as fatal, not as an unclassified "will retry" failure.
    @'
@echo off
echo oci-was-called>> "%~dp0oci_called.txt"
echo Usage: oci compute instance launch [OPTIONS] 1>&2
echo Error: Got unexpected extra arguments (abCD:US-ASHBURN-AD-2 abCD:US-ASHBURN-AD-3) 1>&2
exit /b 2
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-AdSelectiveOci([string]$Dir) {
    # Capacity ONLY in AD-3: fails "Out of host capacity" for AD-1/AD-2, succeeds for AD-3.
    # Records each invocation's args so the test can confirm all three ADs were swept.
    @'
@echo off
echo %* >> "%~dp0oci_args.txt"
echo %*| findstr /C:"AD-3" >nul
if errorlevel 1 (
  echo ServiceError: Out of host capacity. 1>&2
  exit /b 1
)
echo {"data": {"id": "ocid1.instance.oc1.iad.aaaaexamplefake"}}
exit /b 0
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-WaitForRunningOci([string]$Dir) {
    # Branches on subcommand: 'list-vnics' returns a VNIC with a public IP, 'instance get'
    # (the --wait-for-state call) reports RUNNING, and anything else (the launch) returns the
    # instance OCID. Lets the WaitForRunning path be exercised end-to-end with no Oracle and
    # no real waiting. Records args with a SPACE before '>>': a trailing numeric argument
    # (--max-wait-seconds 600) would otherwise make cmd parse '600>>file' as an file-descriptor
    # redirect and silently drop the line - see the space-before-'>>' fix applied above.
    @'
@echo off
echo %* >> "%~dp0oci_args.txt"
echo %*| findstr /C:"list-vnics" >nul
if not errorlevel 1 (
  echo {"data": [{"public-ip": "203.0.113.42"}]}
  exit /b 0
)
echo %*| findstr /C:"instance get" >nul
if not errorlevel 1 (
  echo {"data": {"lifecycle-state": "RUNNING"}}
  exit /b 0
)
echo {"data": {"id": "ocid1.instance.oc1.iad.aaaaexamplefake"}}
exit /b 0
'@ | Set-Content -Path (Join-Path $Dir 'oci.cmd') -Encoding ASCII
}
function New-Key([string]$Dir) {
    Set-Content -Path (Join-Path $Dir 'key.pub') -Value 'ssh-ed25519 AAAAtest test@host' -Encoding ASCII
}
function New-ValidConfig {
    param(
        [string]$Dir,
        [string]$NtfyServer = 'https://ntfy.sh',
        [int]$BaseDelay = 60,
        [int]$Jitter = 30,
        [string]$AvailabilityDomain = 'abCD:US-ASHBURN-AD-1',
        [string]$Region = ''
    )
    ([ordered]@{
        CompartmentId      = 'ocid1.tenancy.oc1.aaaareal'
        SubnetId           = 'ocid1.subnet.oc1.iad.aaaareal'
        ImageId            = 'ocid1.image.oc1.iad.aaaareal'
        AvailabilityDomain = $AvailabilityDomain
        SshKeyPath         = (Join-Path $Dir 'key.pub')
        NtfyTopic          = 'hermetic-test-topic'
        NtfyServer         = $NtfyServer
        Region             = $Region
        BaseDelaySeconds   = $BaseDelay
        JitterSeconds      = $Jitter
    } | ConvertTo-Json) | Set-Content -Path (Join-Path $Dir 'config.json') -Encoding UTF8
}

# Run the script under test in a child process; capture exit code + combined output
# without letting the child's stderr become a terminating error in this harness.
function Invoke-Provisioner([string]$Dir) {
    $script  = Join-Path $Dir 'OciProvisioner.ps1'
    $oldPath = $env:PATH
    $env:PATH = "$Dir;$env:PATH"
    try {
        $out = & {
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | ForEach-Object { "$_" }
        } | Out-String
    } finally { $env:PATH = $oldPath }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Out = $out }
}

# ---- run -------------------------------------------------------------------
if (Test-Path $SandboxRoot) { Remove-Item $SandboxRoot -Recurse -Force }
New-Item -ItemType Directory -Path $SandboxRoot -Force | Out-Null
Write-Host "Running OciProvisioner integration tests..." -ForegroundColor Cyan

try {
    # --- Scenario 1: missing config.json => clean fatal exit ---
    Write-Host "`n[1] Missing config.json"
    $d = New-TestDir '1-missing'
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                              "exits 1"
    Assert ($r.Out -match 'Configuration file not found')   "prints clean 'not found' guidance"
    Assert ($r.Out -notmatch 'CategoryInfo')                "no raw PowerShell error blob"
    Assert ((Get-Content (Join-Path $d 'provisioner.log') -Raw) -match 'Configuration file not found') `
        "ALSO logs the fatal error to file (not console-only) - critical under a headless Scheduled Task"

    # --- Scenario 2: placeholder config (the shipped example) => lists all keys ---
    Write-Host "`n[2] Placeholder config (config.json.example)"
    $d = New-TestDir '2-placeholder'
    Copy-Item $ExampleConfig (Join-Path $d 'config.json')
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                                                          "exits 1"
    Assert ($r.Out -match 'missing or contains placeholder values')                     "explains the problem"
    foreach ($k in 'CompartmentId','SubnetId','ImageId','AvailabilityDomain','SshKeyPath','NtfyTopic') {
        Assert ($r.Out -match $k) "flags placeholder '$k'"
    }

    # --- Scenario 3: idempotency (marker present) => skip, never call oci ---
    Write-Host "`n[3] Idempotency: success marker present"
    $d = New-TestDir '3-idempotent'
    New-SuccessOci $d; New-Key $d; New-ValidConfig -Dir $d
    Set-Content (Join-Path $d 'provisioner.success') 'prior run' -Encoding UTF8
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 0)                                  "exits 0"
    Assert ($r.Out -match 'already provisioned')                "reports already provisioned"
    Assert (-not (Test-Path (Join-Path $d 'oci_called.txt')))   "does NOT invoke oci"

    # --- Scenario 4: success path with stderr noise (the critical fix) ---
    Write-Host "`n[4] Success path (OCID on stdout + noise on stderr)"
    $d = New-TestDir '4-success'
    New-SuccessOci $d; New-Key $d
    New-ValidConfig -Dir $d -NtfyServer 'http://127.0.0.1:1'   # closed port => push fails fast & safe
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 0)                                  "exits 0"
    Assert (Test-Path (Join-Path $d 'oci_called.txt'))          "invoked oci"
    Assert ($r.Out -match 'Instance secured')                   "detected success despite stderr"
    Assert (Test-Path (Join-Path $d 'provisioner.success'))     "wrote success marker"
    Assert ((Get-Content (Join-Path $d 'provisioner.success') -Raw) -match 'ocid1\.instance\.oc1')  "marker records the OCID"
    Assert ($r.Out -match 'notification failed')                "ntfy failure handled gracefully (non-fatal)"

    # --- Scenario 5: failure path routes to backoff (no crash, keeps retrying) ---
    Write-Host "`n[5] Failure path => jitter backoff"
    $d = New-TestDir '5-backoff'
    New-FailingOci $d; New-Key $d; New-ValidConfig -Dir $d -BaseDelay 1 -Jitter 0
    $oldPath = $env:PATH; $env:PATH = "$d;$env:PATH"
    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $d 'OciProvisioner.ps1') `
            -WorkingDirectory $d -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 4
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    } finally { $env:PATH = $oldPath }
    $log = if (Test-Path (Join-Path $d 'provisioner.log')) { Get-Content (Join-Path $d 'provisioner.log') -Raw } else { '' }
    Assert ($log -match 'Out of host capacity') "surfaced the real CLI failure reason"
    Assert ($log -match 'will retry')           "classified capacity error as transient"
    Assert ($log -match 'Backing off')          "entered jitter backoff and kept retrying"

    # --- Scenario 6: bare AvailabilityDomain (missing tenancy prefix) => fail fast ---
    Write-Host "`n[6] Bare AvailabilityDomain (no tenancy prefix)"
    $d = New-TestDir '6-bare-ad'
    New-SuccessOci $d; New-Key $d
    New-ValidConfig -Dir $d -AvailabilityDomain 'US-ASHBURN-AD-1'   # no colon => invalid
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                                   "exits 1"
    Assert ($r.Out -match 'missing its tenancy prefix')          "explains the AD-prefix problem"
    Assert (-not (Test-Path (Join-Path $d 'oci_called.txt')))    "fails preflight before invoking oci"

    # --- Scenario 7: permanent API error => abort fast, do NOT loop on "capacity" ---
    Write-Host "`n[7] Permanent error (NotAuthorizedOrNotFound)"
    $d = New-TestDir '7-permanent'
    New-PermanentlyFailingOci $d; New-Key $d; New-ValidConfig -Dir $d -BaseDelay 1 -Jitter 0
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                                   "exits 1 (does not loop forever)"
    Assert ($r.Out -match 'Non-retryable')                       "labels it non-retryable"
    Assert ($r.Out -match 'NotAuthorizedOrNotFound')             "surfaces the real CLI error"
    Assert ($r.Out -notmatch 'Backing off')                      "does NOT enter the backoff loop"

    # --- Scenario 8: Region pins --region in the launch args ---
    Write-Host "`n[8] Region => --region passed to oci"
    $d = New-TestDir '8-region'
    New-SuccessOci $d; New-Key $d
    New-ValidConfig -Dir $d -NtfyServer 'http://127.0.0.1:1' -Region 'us-ashburn-1'
    $r = Invoke-Provisioner $d
    $ociArgs = if (Test-Path (Join-Path $d 'oci_args.txt')) { Get-Content (Join-Path $d 'oci_args.txt') -Raw } else { '' }
    Assert ($r.ExitCode -eq 0)                                   "exits 0"
    Assert ($ociArgs -match '--region us-ashburn-1')             "passed --region to the CLI"

    # --- Scenario 9: multi-AD sweep => lands on whichever AD has capacity, in one cycle ---
    Write-Host "`n[9] Multi-AD sweep (capacity only in AD-3)"
    $d = New-TestDir '9-multi-ad'
    New-AdSelectiveOci $d; New-Key $d
    ([ordered]@{
        CompartmentId      = 'ocid1.tenancy.oc1.aaaareal'
        SubnetId           = 'ocid1.subnet.oc1.iad.aaaareal'
        ImageId            = 'ocid1.image.oc1.iad.aaaareal'
        AvailabilityDomain = @('abCD:US-ASHBURN-AD-1', 'abCD:US-ASHBURN-AD-2', 'abCD:US-ASHBURN-AD-3')
        SshKeyPath         = (Join-Path $d 'key.pub')
        NtfyTopic          = 'hermetic-test-topic'
        NtfyServer         = 'http://127.0.0.1:1'
        Region             = 'us-ashburn-1'
        BaseDelaySeconds   = 1
        JitterSeconds      = 0
    } | ConvertTo-Json) | Set-Content -Path (Join-Path $d 'config.json') -Encoding UTF8
    $r = Invoke-Provisioner $d
    $ociArgs = if (Test-Path (Join-Path $d 'oci_args.txt')) { Get-Content (Join-Path $d 'oci_args.txt') -Raw } else { '' }
    Assert ($r.ExitCode -eq 0)                       "exits 0 (found capacity during the sweep)"
    Assert ($r.Out -match 'Instance secured')        "secured an instance"
    Assert ($ociArgs -match 'AD-1')                  "tried AD-1"
    Assert ($ociArgs -match 'AD-2')                  "tried AD-2 (no delay after AD-1's miss)"
    Assert ($ociArgs -match 'AD-3')                  "tried AD-3 (where capacity was) in the same sweep"

    # --- Scenario 10: anti-idle keep-alive is ON by default => --metadata passed ---
    Write-Host "`n[10] Anti-idle keep-alive (default: enabled)"
    $d = New-TestDir '10-antiidle-default'
    New-SuccessOci $d; New-Key $d
    New-ValidConfig -Dir $d -NtfyServer 'http://127.0.0.1:1'   # no AntiIdleKeepAlive key => default true
    $r = Invoke-Provisioner $d
    $ociArgs = if (Test-Path (Join-Path $d 'oci_args.txt')) { Get-Content (Join-Path $d 'oci_args.txt') -Raw } else { '' }
    Assert ($r.ExitCode -eq 0)                                   "exits 0"
    Assert ($r.Out -match 'Anti-idle keep-alive: enabled')       "logs keep-alive as enabled"
    Assert ($ociArgs -match '--metadata')                        "passed --metadata to the CLI"

    # --- Scenario 11: AntiIdleKeepAlive: false => no --metadata, opt-out respected ---
    Write-Host "`n[11] Anti-idle keep-alive (explicitly disabled)"
    $d = New-TestDir '11-antiidle-disabled'
    New-SuccessOci $d; New-Key $d
    ([ordered]@{
        CompartmentId      = 'ocid1.tenancy.oc1.aaaareal'
        SubnetId           = 'ocid1.subnet.oc1.iad.aaaareal'
        ImageId            = 'ocid1.image.oc1.iad.aaaareal'
        AvailabilityDomain = 'abCD:US-ASHBURN-AD-1'
        SshKeyPath         = (Join-Path $d 'key.pub')
        NtfyTopic          = 'hermetic-test-topic'
        NtfyServer         = 'http://127.0.0.1:1'
        AntiIdleKeepAlive  = $false
    } | ConvertTo-Json) | Set-Content -Path (Join-Path $d 'config.json') -Encoding UTF8
    $r = Invoke-Provisioner $d
    $ociArgs = if (Test-Path (Join-Path $d 'oci_args.txt')) { Get-Content (Join-Path $d 'oci_args.txt') -Raw } else { '' }
    Assert ($r.ExitCode -eq 0)                                   "exits 0"
    Assert ($r.Out -match 'Anti-idle keep-alive: disabled')      "logs keep-alive as disabled"
    Assert ($ociArgs -notmatch '--metadata')                     "did NOT pass --metadata (opt-out respected)"

    # --- Scenario 12: CLI usage/argument-parsing error => abort fast, do NOT loop forever ---
    Write-Host "`n[12] CLI usage error (stale script mis-building --availability-domain)"
    $d = New-TestDir '12-cli-usage-error'
    New-CliUsageErrorOci $d; New-Key $d; New-ValidConfig -Dir $d -BaseDelay 1 -Jitter 0
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                                   "exits 1 (does not loop forever)"
    Assert ($r.Out -match 'usage/argument-parsing error')        "labels it a CLI usage error, not capacity"
    Assert ($r.Out -match 'Got unexpected extra arguments')      "surfaces the real CLI error"
    Assert ($r.Out -notmatch 'Backing off')                      "does NOT enter the backoff loop"
    Assert ($r.Out -notmatch 'unclassified')                     "is NOT swallowed by the generic unclassified fallback"

    # --- Scenario 13: WaitForRunning => waits for RUNNING and surfaces the public IP ---
    Write-Host "`n[13] WaitForRunning (waits for RUNNING, resolves public IP)"
    $d = New-TestDir '13-wait-for-running'
    New-WaitForRunningOci $d; New-Key $d
    ([ordered]@{
        CompartmentId      = 'ocid1.tenancy.oc1.aaaareal'
        SubnetId           = 'ocid1.subnet.oc1.iad.aaaareal'
        ImageId            = 'ocid1.image.oc1.iad.aaaareal'
        AvailabilityDomain = 'abCD:US-ASHBURN-AD-1'
        SshKeyPath         = (Join-Path $d 'key.pub')
        NtfyTopic          = 'hermetic-test-topic'
        NtfyServer         = 'http://127.0.0.1:1'
        Region             = 'us-ashburn-1'
        WaitForRunning     = $true
        WaitTimeoutSeconds = 5
    } | ConvertTo-Json) | Set-Content -Path (Join-Path $d 'config.json') -Encoding UTF8
    $r = Invoke-Provisioner $d
    $ociArgs = if (Test-Path (Join-Path $d 'oci_args.txt')) { Get-Content (Join-Path $d 'oci_args.txt') -Raw } else { '' }
    Assert ($r.ExitCode -eq 0)                                    "exits 0"
    Assert ($r.Out -match 'Wait-for-RUNNING: enabled')            "logs wait-for-RUNNING as enabled"
    Assert ($r.Out -match 'Instance secured')                     "secured an instance"
    Assert ($ociArgs -match 'instance get')                       "queried instance get"
    Assert ($ociArgs -match '--wait-for-state RUNNING')           "waited for the instance to reach RUNNING"
    Assert ($ociArgs -match 'list-vnics')                         "queried the VNIC for the public IP"
    Assert ($r.Out -match 'Public IP: 203\.0\.113\.42')           "surfaced the public IP in the log"
    Assert ($r.Out -match 'notification failed')                  "ntfy still attempted (best-effort) despite closed port"

    # --- Scenario 14: malformed JSON => clean fatal exit, ALSO logged to file ---
    # Reproduces a real incident: a missing comma between two keys in config.json produced a
    # fatal error that was completely invisible under a headless Scheduled Task, because
    # Exit-Fatal only ever wrote to the (nonexistent, for a hidden task) console. This is the
    # earliest possible Exit-Fatal call site - before config.json is even successfully parsed,
    # let alone before the normal $LogPath = Get-ConfigValue(...) resolution - so it specifically
    # exercises the early deterministic $LogPath default that makes logging safe this early.
    Write-Host "`n[14] Malformed JSON (missing comma) => fails fast AND logs to file"
    $d = New-TestDir '14-malformed-json'
    @'
{
  "CompartmentId": "ocid1.tenancy.oc1.aaaareal",
  "SubnetId": "ocid1.subnet.oc1.iad.aaaareal",
  "ImageId": "ocid1.image.oc1.iad.aaaareal",
  "AvailabilityDomain": "abCD:US-ASHBURN-AD-1",
  "SshKeyPath": "key.pub",
  "NtfyTopic": "hermetic-test-topic",
  "WaitTimeoutSeconds": 600
  "DisplayName": "oci-free-arm-instance"
}
'@ | Set-Content -Path (Join-Path $d 'config.json') -Encoding UTF8
    $r = Invoke-Provisioner $d
    Assert ($r.ExitCode -eq 1)                                          "exits 1"
    Assert ($r.Out -match 'could not be parsed as valid JSON')          "prints the JSON-parse fatal error"
    Assert ((Get-Content (Join-Path $d 'provisioner.log') -Raw) -match 'could not be parsed as valid JSON') `
        "ALSO logs it to file - this is the exact incident: previously invisible under a headless run"
}
finally {
    Remove-Item $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- summary ---------------------------------------------------------------
Write-Host ("`n================ {0} passed, {1} failed ================" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
