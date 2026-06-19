#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers OciProvisioner.ps1 as a Windows Scheduled Task that runs at system
    startup, so provisioning survives reboots and power drops.

.DESCRIPTION
    The provisioning loop can run for hours or days while waiting for Always Free
    capacity. Wiring it into a startup Scheduled Task means it restarts automatically
    after an unattended reboot.

    By default the task runs as NT AUTHORITY\SYSTEM (no password, always available).
    SECURITY / CORRECTNESS NOTES for the SYSTEM mode:
      * SYSTEM can run arbitrary code at boot, so make sure ONLY administrators can write
        to this repo folder (the script + config.json are loaded by relative path).
      * The OCI CLI looks for its config in the *running user's* profile. As SYSTEM it will
        NOT find the ~/.oci/config you created with 'oci setup config'. Set
        "OciCliConfigPath" in config.json to the absolute path of that file.

    Prefer least privilege? Use -RunAsCurrentUser to register the task under your own
    account ("run whether logged on or not"), which avoids both caveats above.

    Run this script ONCE from an elevated (Administrator) PowerShell prompt. It is
    idempotent — re-running it updates the existing task in place.

.PARAMETER TaskName
    Name of the scheduled task. Defaults to 'OCI-Instance-Provisioner'.

.PARAMETER RunAsCurrentUser
    Register the task under the current user account (S4U logon) instead of SYSTEM.
    Recommended unless you specifically need SYSTEM.

.EXAMPLE
    # Default (SYSTEM), from an elevated PowerShell prompt in the repo folder:
    .\Register-ScheduledTask.ps1

.EXAMPLE
    # Least-privilege: run under your own account.
    .\Register-ScheduledTask.ps1 -RunAsCurrentUser

.NOTES
    To inspect, run, or remove the task afterwards:
      Get-ScheduledTask   -TaskName 'OCI-Instance-Provisioner'
      Start-ScheduledTask -TaskName 'OCI-Instance-Provisioner'
      Unregister-ScheduledTask -TaskName 'OCI-Instance-Provisioner' -Confirm:$false
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'OCI-Instance-Provisioner',
    [switch]$RunAsCurrentUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve the absolute path to the provisioner that sits beside this script.
$ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'OciProvisioner.ps1'
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Could not find OciProvisioner.ps1 next to this script ($PSScriptRoot)."
}

# Guard against registering a task with no configuration in place.
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'config.json'))) {
    Write-Warning "config.json not found yet. The task will be created, but provisioning will exit until you create config.json (copy config.json.example)."
}

# Launch powershell.exe hidden, bypassing execution policy for this one file only.
$Action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"" `
    -WorkingDirectory $PSScriptRoot

# Fire at every system startup (no interactive logon required).
$Trigger = New-ScheduledTaskTrigger -AtStartup

# Choose the security principal: least-privilege current user (S4U) or SYSTEM.
if ($RunAsCurrentUser) {
    $userId = "$env:USERDOMAIN\$env:USERNAME"
    # S4U = "run whether the user is logged on or not", no stored password required.
    $Principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $RunAsLabel = $userId
}
else {
    # SYSTEM with highest privileges so it survives reboots and needs no password.
    $Principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $RunAsLabel = 'NT AUTHORITY\SYSTEM'
}

# Keep retrying across transient conditions; don't let Windows kill a long run.
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $Action `
    -Trigger     $Trigger `
    -Principal   $Principal `
    -Settings    $Settings `
    -Description 'Autonomous OCI Always Free instance provisioner (retries until capacity is available).' `
    -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered to run at startup as $RunAsLabel." -ForegroundColor Green
if (-not $RunAsCurrentUser) {
    Write-Host "Reminder: as SYSTEM, set 'OciCliConfigPath' in config.json so the OCI CLI finds your credentials." -ForegroundColor Yellow
}
Write-Host "Start it now with:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
Write-Host "Watch progress in:  $(Join-Path $PSScriptRoot 'provisioner.log')" -ForegroundColor Cyan
Write-Host "Once your instance lands, remove the task:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false" -ForegroundColor Cyan
