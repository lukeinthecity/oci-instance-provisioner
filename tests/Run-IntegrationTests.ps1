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
import sys, json
a = sys.argv[1:]
try:
    json.loads(a[a.index("--shape-config") + 1])
except Exception:
    sys.exit(3)
sys.exit(0)
'@ | Set-Content -Path (Join-Path $Dir 'validate_shape.py') -Encoding ASCII
    @'
@echo off
echo oci-was-called>> "%~dp0oci_called.txt"
echo %*>> "%~dp0oci_args.txt"
where python >nul 2>nul
if errorlevel 1 goto emit
python "%~dp0validate_shape.py" %*
if errorlevel 1 (
  echo ServiceError: Parameter 'shape_config' must be in JSON format. 1>&2
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
}
finally {
    Remove-Item $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- summary ---------------------------------------------------------------
Write-Host ("`n================ {0} passed, {1} failed ================" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
