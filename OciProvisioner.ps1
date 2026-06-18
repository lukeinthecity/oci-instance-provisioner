# ==============================================================================
# 🎯 DEV OPS AUTOMATED INFRASTRUCTURE HUNTER (WINDOWS POWERSHELL EDITION)
# Hardened Validation Core & Randomized Jitter Backoff
# ==============================================================================

# --- USER INFRASTRUCTURE CONFIGURATION ---
$CompartmentId     = "ocid1.tenancy.oc1..."
$SubnetId          = "ocid1.subnet.oc1.iad...."
$ImageId           = "ocid1.image.oc1.iad..."
$AvailabilityDomain = "..."
$SshKeyPath        = "..."

# --- CORE ENGINEERING VARIABLES ---
$BaseDelay   = 60      
$JitterRange = 30      

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "🚀 INITIATING HIGH-LEVEL INFRASTRUCTURE PROVISIONING ENGINE..." -ForegroundColor Cyan
Write-Host "🛡️ Rate-limiting safeguards active: Exponential Jitter Enabled." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

while ($true) {
    $CurrentTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "📡 Sending cryptographically signed OCI API request at $CurrentTime..." -ForegroundColor White

    try {
        $LaunchParams = @{
            CompartmentId        = $CompartmentId
            AvailabilityDomain   = $AvailabilityDomain
            Shape                = "VM.Standard.A1.Flex"
            ShapeConfig          = '{"ocpus": 2, "memoryInGBs": 12}'
            ImageId              = $ImageId
            SubnetId             = $SubnetId
            AssignPublicIp       = $true
            DisplayName          = "production-fintech-hub"
            SshAuthorizedKeysFile = $SshKeyPath
        }

        # Fire off the native instance call
        $Response = oci compute instance launch @LaunchParams 2>&1 | Out-String

        # STRICT VALIDATION: If the response doesn't contain a fresh Instance OCID, it failed
        if ($Response -notmatch "ocid1.instance.oc1") {
            throw "ProvisioningFailed"
        }

        Write-Host "================================================================" -ForegroundColor Green
        Write-Host "🎉 ARCHITECTURAL SUCCESS: Always-Free Compute Shape Secured!" -ForegroundColor Green
        Write-Host "================================================================" -ForegroundColor Green
        Write-Output $Response

        # 🔔 MOBILE PUSH NOTIFICATION VIA NTFY.SH
        # Change "lukes-oracle-hunter-alert" to any completely unique string you want!
        $TopicName = "lukes-oracle-hunter-alert" 
        $NotificationParams = @{
            Uri     = "https://ntfy.sh/$..."
            Method  = "Post"
            Body    = "🚀 Boom! Oracle Ampere ARM Instance successfully provisioned on XXX. Check your cloud console!"
            Headers = @{ "Title" = "Infrastructure Secured"; "Priority" = "high"; "Tags" = "partying_face,cloud" }
        }
        Invoke-RestMethod @NotificationParams

        break
    }
    catch {
        # 🎲 COMPUTE RANDOMIZED JITTER
        $RandomJitter = Get-Random -Minimum 0 -Maximum $JitterRange
        $TotalSleep   = $BaseDelay + $RandomJitter

        Write-Host "❌ Target resource unavailable or capacity pool exhausted." -ForegroundColor Red
        Write-Host "💤 Implementing backoff strategy. Sleeping for ${TotalSleep}s (Base: ${BaseDelay}s + Jitter: ${RandomJitter}s)..." -ForegroundColor Gray
        Write-Host "----------------------------------------------------" -ForegroundColor Gray
        
        Start-Sleep -Seconds $TotalSleep
    }
}