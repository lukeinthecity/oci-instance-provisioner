#Requires -Version 5.1
<#
.SYNOPSIS
    Autonomous Oracle Cloud Infrastructure (OCI) "Always Free" compute provisioner.

.DESCRIPTION
    Oracle Cloud's Always Free Ampere A1 (ARM) shapes are perpetually in high demand,
    and the API frequently returns "Out of host capacity" until a slot opens up in the
    target Availability Domain. This script runs a resilient retry loop around the native
    OCI CLI 'compute instance launch' call, applies a randomized jitter backoff between
    attempts (to stay a good API citizen), and exits cleanly the moment a real instance
    OCID is returned. On success it fires an optional unauthenticated ntfy.sh push so you
    get a notification on your phone the instant capacity is secured.

    All infrastructure parameters are decoupled into a local 'config.json' (ignored by git),
    so this file contains no secrets and is safe to publish.

.PARAMETER ConfigPath
    Optional override for the configuration file path. Defaults to 'config.json' located
    alongside this script ($PSScriptRoot).

.EXAMPLE
    .\OciProvisioner.ps1
    Runs using the config.json sitting next to the script.

.EXAMPLE
    .\OciProvisioner.ps1 -ConfigPath 'D:\secrets\oci.json'
    Runs using an explicit configuration file path.

.NOTES
    Author : Luke Shefski
    License: MIT
    Requires: Oracle Cloud Infrastructure CLI (https://docs.oracle.com/iaas/tools/oci-cli/latest/)
              configured with a valid API key ('oci setup config').

.LINK
    https://github.com/lukeinthecity/oci-instance-provisioner
#>
[CmdletBinding()]
param(
    # Allow callers / scheduled tasks to point at a config file elsewhere if desired.
    [string]$ConfigPath
)

# Make cmdlet errors terminating so the try/catch loop below is the single, predictable
# control point. NOTE: native-executable stderr is handled separately inside the loop —
# see the comment on the 'oci' invocation for why we relax this preference there.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
#  REGION: Fatal-exit helper
#  Intentional, non-retryable setup failures (missing config, bad JSON, missing
#  CLI, etc.) should print a clean, multi-line, actionable message and exit 1 —
#  NOT surface PowerShell's raw "At line:x char:y / CategoryInfo / ..." error blob
#  (which is what Write-Error produces while $ErrorActionPreference = 'Stop').
# ==============================================================================
function Exit-Fatal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# ==============================================================================
#  REGION: Logging helper
#  When this script runs under a SYSTEM-context Scheduled Task there is no console
#  attached, so Write-Host output is lost. Write-Log mirrors every message to a
#  timestamped log file (next to the script, or wherever config.LogPath points)
#  while still colorizing interactive runs.
# ==============================================================================
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO',
        [string]$Path
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[{0}] [{1,-7}] {2}" -f $stamp, $Level, $Message

    # Console (best-effort: only meaningful for interactive runs).
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    # File (durable: this is what you read back after a headless scheduled run).
    if ($Path) {
        try { Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 } catch { }
    }
}

# ==============================================================================
#  REGION: Configuration resolution & evaluation gate (Refactoring Target #3)
#  Locate config.json relative to the script itself so the tool is portable, then
#  hard-stop with a clean, actionable message if it is missing or malformed.
# ==============================================================================

# Resolve the default config location to the script's own directory.
if (-not $ConfigPath) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.json'
}

# EVALUATION GATE: a missing config is a fatal, non-retryable setup error.
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Exit-Fatal @"
Configuration file not found: $ConfigPath

This tool will not run without a local config.json.
  1. Copy the template:   Copy-Item .\config.json.example .\config.json
  2. Fill in your OCI infrastructure OCIDs and SSH key path.
See README.md for how to retrieve each value.
"@
}

# Parse the JSON, failing fast (and clearly) on syntax errors.
try {
    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}
catch {
    Exit-Fatal "config.json could not be parsed as valid JSON: $($_.Exception.Message)"
}

# Validate that every required field is present and not left at a placeholder value.
$RequiredKeys = @(
    'CompartmentId',
    'SubnetId',
    'ImageId',
    'AvailabilityDomain',
    'SshKeyPath',
    'NtfyTopic'
)

$MissingKeys = foreach ($key in $RequiredKeys) {
    # Guard the absent-property case explicitly: under Set-StrictMode -Version Latest,
    # reading '.Value' on a $null member (i.e. a key that was deleted/never copied from
    # the template) throws a cryptic error. We want it to flow into the clean message below.
    $prop  = $Config.PSObject.Properties[$key]
    $value = if ($prop) { $prop.Value } else { $null }
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '(?i)REPLACE_ME|\.\.\.') {
        $key
    }
}

if ($MissingKeys) {
    Exit-Fatal ("config.json is missing or contains placeholder values for: {0}`nEdit {1} and supply real values." -f ($MissingKeys -join ', '), $ConfigPath)
}

# ==============================================================================
#  REGION: Optional / defaulted settings
#  Instance shape and backoff timing are tunable but optional — fall back to sane
#  defaults (the full Always Free ARM allocation: 4 OCPUs / 24 GB) when omitted.
# ==============================================================================
function Get-ConfigValue {
    param([string]$Name, $Default)
    if ($Config.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        return $Config.$Name
    }
    return $Default
}

$Shape          = Get-ConfigValue -Name 'Shape'          -Default 'VM.Standard.A1.Flex'
$Ocpus          = Get-ConfigValue -Name 'Ocpus'          -Default 4
$MemoryInGBs    = Get-ConfigValue -Name 'MemoryInGBs'    -Default 24
$DisplayName    = Get-ConfigValue -Name 'DisplayName'    -Default 'oci-free-arm-instance'
$AssignPublicIp = Get-ConfigValue -Name 'AssignPublicIp' -Default $true
$BaseDelay      = [int](Get-ConfigValue -Name 'BaseDelaySeconds' -Default 60)
$JitterRange    = [int](Get-ConfigValue -Name 'JitterSeconds'    -Default 30)

# Target region for the launch. STRONGLY recommended: it must match the region of your
# SubnetId / ImageId / AvailabilityDomain. If left blank the CLI falls back to the region
# in ~/.oci/config, which can silently mismatch and 404 forever (see preflight below).
$Region         = Get-ConfigValue -Name 'Region' -Default ''

# Availability Domain(s). Accept EITHER a single string or a JSON array. We sweep through
# all of them back-to-back each cycle (no delay between ADs) so capacity in ANY of them is
# caught, then back off once per full sweep. The OUTER @(...) is essential: Where-Object
# returns a scalar for a single match, and '.Count' on a scalar string throws under
# Set-StrictMode -Version Latest — so we force the result to always be an array.
$AvailabilityDomains = @(@($Config.AvailabilityDomain) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

# ntfy endpoint. Defaults to the public service; override to point at a self-hosted
# instance. Trailing slash trimmed so the URI is built cleanly below.
$NtfyServer     = (Get-ConfigValue -Name 'NtfyServer' -Default 'https://ntfy.sh').TrimEnd('/')

# Durable log file (config override, else next to the script).
$LogPath = Get-ConfigValue -Name 'LogPath' -Default (Join-Path -Path $PSScriptRoot -ChildPath 'provisioner.log')

# Success marker: a sentinel file written once an instance is secured. Its presence
# makes the script idempotent — see the idempotency gate below.
$SuccessMarkerPath = Get-ConfigValue -Name 'SuccessMarkerPath' -Default (Join-Path -Path $PSScriptRoot -ChildPath 'provisioner.success')

# The OCI CLI expects --shape-config as a JSON string. Critical PowerShell gotcha:
# when a string containing double quotes is passed to a NATIVE exe, the quotes are
# stripped, so 'oci' receives {ocpus:4,memoryInGBs:24} and rejects it with
# "Parameter 'shape_config' must be in JSON format". Escaping the inner quotes as \"
# lets them survive the native-command boundary intact. Keep -Compress (no spaces)
# so the value stays a single argument.
$ShapeConfigJson = (@{ ocpus = $Ocpus; memoryInGBs = $MemoryInGBs } | ConvertTo-Json -Compress) -replace '"', '\"'

# ==============================================================================
#  REGION: Idempotency gate
#  This loop exits on the FIRST success, but a Scheduled Task re-launches it at every
#  startup. Without a guard, each reboot would attempt to provision ANOTHER instance
#  (and may succeed, consuming your free-tier quota). If we've already secured one,
#  stop here. Delete the marker file to deliberately provision again.
# ==============================================================================
if (Test-Path -LiteralPath $SuccessMarkerPath -PathType Leaf) {
    Write-Log -Path $LogPath -Level INFO -Message "An instance was already provisioned (marker: $SuccessMarkerPath). Nothing to do."
    Write-Log -Path $LogPath -Level INFO -Message "Delete that marker file (and re-run) if you intend to provision another instance."
    exit 0
}

# ==============================================================================
#  REGION: Preflight checks (fail fast, never loop forever on setup errors)
#  A missing CLI, missing key, or unreachable CLI config is a configuration problem,
#  not a transient capacity problem — so we validate them BEFORE entering the loop.
# ==============================================================================

# Under a SYSTEM-context Scheduled Task, the OCI CLI looks for its config under
# SYSTEM's profile (not your user profile), so it won't find the ~/.oci/config you
# created with 'oci setup config'. Point OCI_CLI_CONFIG_FILE at the real file.
$OciCliConfigPath = Get-ConfigValue -Name 'OciCliConfigPath' -Default ''
if (-not [string]::IsNullOrWhiteSpace($OciCliConfigPath)) {
    if (-not (Test-Path -LiteralPath $OciCliConfigPath -PathType Leaf)) {
        Exit-Fatal "OciCliConfigPath '$OciCliConfigPath' was set in config.json but the file does not exist."
    }
    $env:OCI_CLI_CONFIG_FILE = $OciCliConfigPath
}

if (-not (Get-Command -Name 'oci' -ErrorAction SilentlyContinue)) {
    Exit-Fatal "The OCI CLI ('oci') was not found on PATH. Install it and run 'oci setup config' first. See README.md."
}

if (-not (Test-Path -LiteralPath $Config.SshKeyPath -PathType Leaf)) {
    Exit-Fatal "SSH public key not found at '$($Config.SshKeyPath)' (config.SshKeyPath). Point this at your .pub key."
}

# Every Availability Domain must carry its tenancy-specific prefix (e.g. 'Uocm:US-ASHBURN-AD-1').
# A bare 'US-ASHBURN-AD-1' is never valid: the API rejects it (404) on EVERY attempt, which the
# backoff loop would otherwise mistake for transient capacity and retry forever. Check each one
# (works whether AvailabilityDomain is a single string or a list).
foreach ($ad in $AvailabilityDomains) {
    if ($ad -notmatch ':') {
        Exit-Fatal @"
AvailabilityDomain '$ad' is missing its tenancy prefix.
Real OCI AD names look like 'Uocm:US-ASHBURN-AD-1' (the prefix is assigned per-tenancy and
is NOT derivable). Get the exact value(s) with:
  oci iam availability-domain list --compartment-id $($Config.CompartmentId) --query "data[].name" --raw-output
then paste them verbatim into config.json (AvailabilityDomain).
"@
    }
}

# Region-alignment sanity check. Subnet/image OCIDs are region-pinned (the region token sits
# at index 3, e.g. 'iad' in ocid1.subnet.oc1.iad.xxxx). The region the CLI actually talks to
# comes from ~/.oci/config unless we pass --region, and a mismatch 404s forever. Warn loudly
# on any disagreement so it's obvious at startup rather than hidden as "capacity".
$subnetParts = @($Config.SubnetId -split '\.')
$imageParts  = @($Config.ImageId  -split '\.')
$subnetRegionToken = if ($subnetParts.Count -gt 3) { $subnetParts[3] } else { '' }
$imageRegionToken  = if ($imageParts.Count  -gt 3) { $imageParts[3]  } else { '' }
if ($subnetRegionToken -and $imageRegionToken -and $subnetRegionToken -ne $imageRegionToken) {
    Write-Log -Path $LogPath -Level WARN -Message "SubnetId region '$subnetRegionToken' != ImageId region '$imageRegionToken' - these resources are in different regions and the launch will fail."
}
if (-not $Region) {
    Write-Log -Path $LogPath -Level WARN -Message "No 'Region' set in config.json; the OCI CLI will use the region from ~/.oci/config. Your resources are in region '$subnetRegionToken' - if the CLI's active region differs, every attempt will 404. Set 'Region' in config.json to be safe."
}

# ==============================================================================
#  REGION: Provisioning loop
# ==============================================================================
Write-Log -Path $LogPath -Level INFO -Message '================================================================'
Write-Log -Path $LogPath -Level INFO -Message 'OCI Always Free provisioning engine started.'
Write-Log -Path $LogPath -Level INFO -Message ("Shape: {0} ({1} OCPU / {2} GB) | AD(s): {3}" -f $Shape, $Ocpus, $MemoryInGBs, ($AvailabilityDomains -join ', '))
Write-Log -Path $LogPath -Level INFO -Message ("Backoff: {0}s base + 0-{1}s jitter | Log: {2}" -f $BaseDelay, $JitterRange, $LogPath)
Write-Log -Path $LogPath -Level INFO -Message '================================================================'

$Attempt  = 0
$launched = $false
while (-not $launched) {
    $Attempt++

    # ---- ONE SWEEP: try every Availability Domain back-to-back (no delay between them) ----
    # Capacity appears in different ADs at different moments, so we poll them all each cycle and
    # stop the instant one yields an instance. We deliberately do NOT fire them in parallel:
    # two simultaneous successes would provision two instances and blow the Always Free
    # 4 OCPU / 24 GB cap. (With a single AD configured, this is just a one-element sweep.)
    foreach ($ad in $AvailabilityDomains) {
        # Initialize so the catch block can safely inspect it even if the CLI call itself
        # raises a PowerShell-terminating error before assignment (StrictMode safety).
        $Response = $null
        $adLabel  = if ($AvailabilityDomains.Count -gt 1) { " [$ad]" } else { '' }
        Write-Log -Path $LogPath -Level INFO -Message "Attempt #$Attempt$adLabel - requesting instance launch..."

        try {
            # Build the CLI invocation as an ARGUMENT ARRAY. 'oci' is a native executable, not a
            # PowerShell cmdlet, so hashtable splatting would NOT map to --flags; splatting an
            # array passes each element as a discrete, correctly-quoted argument.
            $LaunchArgs = @('compute', 'instance', 'launch')
            # Pin the region when configured so it can't silently diverge from the CLI default.
            if ($Region) { $LaunchArgs += @('--region', $Region) }
            $LaunchArgs += @(
                '--compartment-id',        $Config.CompartmentId,
                '--availability-domain',   $ad,
                '--subnet-id',             $Config.SubnetId,
                '--image-id',              $Config.ImageId,
                '--shape',                 $Shape,
                '--shape-config',          $ShapeConfigJson,
                '--display-name',          $DisplayName,
                '--assign-public-ip',      ($AssignPublicIp.ToString().ToLower()),
                '--ssh-authorized-keys-file', $Config.SshKeyPath
            )

            # Capture stdout + stderr together for the log. Two subtle-but-critical details:
            #  1. We relax $ErrorActionPreference to 'Continue' inside this child scope. With the
            #     global 'Stop', a native command writing ANY line to stderr (the OCI CLI emits
            #     non-fatal notices even on a SUCCESSFUL launch) is promoted to a terminating
            #     error — which would throw before our success gate runs and loop forever
            #     despite the instance being created.
            #  2. Piping through { "$_" } renders merged stderr ErrorRecords as plain message
            #     text, stripping PowerShell's noisy NativeCommandError wrapper.
            # Success is then decided solely by the real exit code + OCID gate below.
            $Response = & {
                $ErrorActionPreference = 'Continue'
                & oci @LaunchArgs 2>&1 | ForEach-Object { "$_" }
            } | Out-String

            # STRICT VALIDATION (Refactoring Target #5): succeed ONLY when the response contains
            # a genuine instance OCID. -like with a literal substring (not regex -match) treats
            # the dots in 'ocid1.instance.oc1' literally. A non-zero exit code OR a missing OCID
            # is a failure and routes to the catch block below.
            if ($LASTEXITCODE -ne 0 -or $Response -notlike '*ocid1.instance.oc1*') {
                throw "Launch did not return a confirmed instance OCID (exit code $LASTEXITCODE)."
            }

            # ---- SUCCESS PATH ----
            Write-Log -Path $LogPath -Level SUCCESS -Message '================================================================'
            Write-Log -Path $LogPath -Level SUCCESS -Message "Instance secured on attempt #$Attempt$adLabel!"
            Write-Log -Path $LogPath -Level SUCCESS -Message '================================================================'
            Write-Log -Path $LogPath -Level INFO    -Message $Response.Trim()

            # Write the idempotency marker so a Scheduled Task won't re-provision on reboot.
            try {
                Set-Content -LiteralPath $SuccessMarkerPath -Encoding UTF8 -Value @"
Provisioned at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$($Response.Trim())
"@
            }
            catch {
                Write-Log -Path $LogPath -Level WARN -Message "Could not write success marker '$SuccessMarkerPath': $($_.Exception.Message)"
            }

            # 🔔 NTFY PUSH NOTIFICATION (Refactoring Target #4)
            # Build the URI by interpolating the topic via a subexpression $(...) — no stray $.
            try {
                $NotificationParams = @{
                    Uri     = "$NtfyServer/$($Config.NtfyTopic)"
                    Method  = 'Post'
                    Body    = "Oracle Cloud ARM instance '$DisplayName' was successfully provisioned. Check your OCI console."
                    Headers = @{
                        'Title'    = 'OCI Instance Secured'
                        'Priority' = 'high'
                        'Tags'     = 'tada,cloud'
                    }
                }
                Invoke-RestMethod @NotificationParams | Out-Null
                Write-Log -Path $LogPath -Level INFO -Message "Push notification sent to ntfy topic '$($Config.NtfyTopic)'."
            }
            catch {
                # A failed notification must not mask a successful provision.
                Write-Log -Path $LogPath -Level WARN -Message "Instance provisioned, but ntfy notification failed: $($_.Exception.Message)"
            }

            $launched = $true
            break   # stop sweeping ADs — we secured one
        }
        catch {
            # ---- PER-AD FAILURE HANDLING ----
            # Permanent errors (auth, not-found, bad AD, quota, invalid request) never clear by
            # waiting, so abort immediately with the REAL message instead of looping — the
            # expensive, undiagnosable failure mode on a remote, always-on PC.
            $rawResponse = if ($Response) { ($Response.Trim() -replace '\s+', ' ') } else { '' }

            $permanentSignatures = 'NotAuthorizedOrNotFound|NotAuthenticated|NotAuthorized|is not authorized|LimitExceeded|QuotaExceeded|service limit|CannotParseRequest|InvalidParameter|MissingParameter|does not exist'
            $transientSignatures = 'Out of host capacity|OutOfCapacity|OutOfHostCapacity|TooManyRequests|throttl|Service.*Unavailable|InternalServerError|timed out|timeout'

            if ($rawResponse -match $permanentSignatures -and $rawResponse -notmatch $transientSignatures) {
                Write-Log -Path $LogPath -Level ERROR -Message 'Non-retryable error from the OCI CLI - this will NOT resolve by waiting:'
                Write-Log -Path $LogPath -Level ERROR -Message $rawResponse
                Exit-Fatal @"
Provisioning aborted: OCI returned a permanent error (auth / not-found / quota / invalid request).
Retrying will not help — fix the underlying configuration and re-run. Common causes:
  - AvailabilityDomain, Region, or the OCIDs point at the wrong tenancy/region.
  - You are already at the Always Free A1 limit (4 OCPU / 24 GB per tenancy) — terminate the
    existing instance, or lower Ocpus/MemoryInGBs in config.json.

Raw CLI output:
$rawResponse
"@
            }

            # Transient (or unrecognized): log it and move straight on to the NEXT AD in this
            # sweep (no delay). The back-off happens once, after every AD has been tried.
            if ($rawResponse -match $transientSignatures) {
                Write-Log -Path $LogPath -Level WARN -Message "Capacity/transient error$adLabel - will retry: $($_.Exception.Message)"
            } else {
                # Never silently mislabel an unexpected failure as capacity — surface it loudly.
                Write-Log -Path $LogPath -Level WARN -Message "Launch failed$adLabel (unclassified - see raw output): $($_.Exception.Message)"
            }
            if ($rawResponse) { Write-Log -Path $LogPath -Level INFO -Message "Raw CLI output: $rawResponse" }
        }
    }

    # ---- END OF SWEEP ----
    # If no AD yielded an instance, back off once before the next full sweep. Randomized jitter
    # spreads retries out instead of hammering the capacity API in lock-step.
    if (-not $launched) {
        $RandomJitter = Get-Random -Minimum 0 -Maximum ($JitterRange + 1)
        $TotalSleep   = $BaseDelay + $RandomJitter
        $sweptNote    = if ($AvailabilityDomains.Count -gt 1) { "Swept all $($AvailabilityDomains.Count) ADs; " } else { '' }
        Write-Log -Path $LogPath -Level INFO -Message "${sweptNote}Backing off ${TotalSleep}s (base ${BaseDelay}s + jitter ${RandomJitter}s)..."
        Start-Sleep -Seconds $TotalSleep
    }
}
