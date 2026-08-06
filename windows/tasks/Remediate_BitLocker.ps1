<#
.SYNOPSIS
    Enable BitLocker on the system drive (C:) and ensure recovery key is backed up and printed.

.DESCRIPTION
    Remediates BitLocker policy failures where:
    - BitLocker is off (enables it with TPM + recovery password).
    - BitLocker is on but "No Recovery Keys Found" (adds recovery password protector,
      backs up to Azure AD when possible, and prints the recovery password for RMM capture).

    Actions:
    1. Enable BitLocker on C: if not already enabled (TPM + RecoveryPassword).
    2. If BitLocker is on but no recovery password exists, add a RecoveryPassword protector.
    3. Back up recovery key to Azure AD (BackupToAAD-BitLockerKeyProtector) when available.
    4. Output the recovery password so RMM/scripts can capture it.

    Designed for N-Sight RMM. Aligns with checks that require BitLocker on and recovery key present.

    Prerequisite: The OS drive must have a proper EFI system partition (UEFI/GPT install).
    If Enable-BitLocker fails with "Value does not fall within the expected range", the
    drive likely lacks this partition (e.g. MBR or legacy install). This script checks
    for it first and exits with a clear message if missing.

.EXECUTION
    Windows (local):  iex (Get-Content ".\Remediate_BitLocker.ps1" -Raw)
    Or:              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remediate_BitLocker.ps1"
    Windows (repo):  iex (irm "https://raw.githubusercontent.com/nirl-droid/n-sight_scripts/main/windows/tasks/Remediate_BitLocker.ps1")
.NOTES
    Author: IT Admin
    Version: 1.2
    Requires: Administrator
    Platform: Windows 10/11, Windows Server 2016+
    Exit: 0 = Success, 1002 = Critical
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Stop"
$LogDir = "C:\logs\$(Get-Date -Format 'yyyyMMdd')"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
$LogFile = Join-Path $LogDir "Remediate_BitLocker_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$SystemDrive = (Get-Item env:SystemDrive).Value + "\"   # e.g. C:\

$EXIT_SUCCESS = 0
$EXIT_CRITICAL = 1002

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogFile -Value $LogEntry -ErrorAction SilentlyContinue
}

function Get-BitLockerRecoveryPassword {
    param([string]$MountPoint = $SystemDrive.TrimEnd('\'))
    $vol = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue
    if (-not $vol) { return $null }
    $rp = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (-not $rp) { return $null }
    return $rp.RecoveryPassword
}

# EFI System Partition GUID (GPT)
$SCRIPT:EFI_SYSTEM_PARTITION_GUID = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

function Test-BitLockerSystemPartition {
    # BitLocker on OS drive requires a separate system partition (EFI or recovery). Without it, Enable-BitLocker fails with "Value does not fall within the expected range".
    $mountPoint = $SystemDrive.TrimEnd('\')
    try {
        $osPartition = Get-Partition -DriveLetter ($mountPoint -replace ':', '') -ErrorAction Stop
    } catch {
        Write-Log "Could not get partition for $mountPoint : $_" -Level "WARN"
        return $false
    }
    $diskNumber = $osPartition.DiskNumber
    $systemPartition = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.GptType -eq $SCRIPT:EFI_SYSTEM_PARTITION_GUID }
    $hasSystemPartition = ($null -ne $systemPartition -and ($systemPartition | Measure-Object).Count -ge 1)
    if (-not $hasSystemPartition) {
        Write-Log "No EFI system partition found on disk $diskNumber (drive $mountPoint). BitLocker requires a proper system/boot partition." -Level "WARN"
    }
    return $hasSystemPartition
}

function Test-TpmReadyForBitLocker {
    # OS drive BitLocker typically requires TPM present and ready. "Value does not fall within the expected range" can mean TPM missing/not ready or GPO conflict.
    try {
        $tpm = Get-Tpm -ErrorAction Stop
    } catch {
        Write-Log "Could not query TPM: $_" -Level "WARN"
        return $false
    }
    if (-not $tpm.TpmPresent) {
        Write-Log "TPM is not present. Enable TPM in BIOS/UEFI or use a machine that has a TPM." -Level "WARN"
        return $false
    }
    if (-not $tpm.TpmReady) {
        Write-Log "TPM is present but not ready (TpmReady=$($tpm.TpmReady)). Clear TPM in BIOS or run Clear-Tpm, then re-run this script." -Level "WARN"
        return $false
    }
    Write-Log "TPM is present and ready."
    return $true
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "BitLocker Remediation v1.2 - Enable and ensure recovery key"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "Drive: $SystemDrive"

try {
    $mountPoint = $SystemDrive.TrimEnd('\')   # C: for Get-BitLockerVolume
    $vol = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction SilentlyContinue

    # --- Step 1: Enable BitLocker if not on ---
    if (-not $vol -or $vol.ProtectionStatus -ne 'On') {
        Write-Log "BitLocker is not on. Checking for required system partition..."
        if (-not (Test-BitLockerSystemPartition)) {
            $msg = "Missing system partition. BitLocker on the OS drive requires a separate EFI system partition (small boot partition). This PC may have been installed without it (e.g. legacy/MBR style). Remediation: clean Windows install with UEFI/GPT, or use MBR2GPT and create the system partition; then re-run this script."
            Write-Log $msg -Level "ERROR"
            Write-Host ""
            Write-Host "FAIL: $msg"
            Write-Host "Computer: $env:COMPUTERNAME"
            exit $EXIT_CRITICAL
        }
        Write-Log "Checking TPM..."
        if (-not (Test-TpmReadyForBitLocker)) {
            $msg = "TPM is missing or not ready. BitLocker on the OS drive requires a present and ready TPM. Enable TPM in BIOS/UEFI; if already enabled, clear TPM ownership (Clear-Tpm) or check for TPM lockout (Unblock-Tpm), then re-run this script."
            Write-Log $msg -Level "ERROR"
            Write-Host ""
            Write-Host "FAIL: $msg"
            Write-Host "Computer: $env:COMPUTERNAME"
            exit $EXIT_CRITICAL
        }
        Write-Log "Enabling BitLocker on $mountPoint with TPM and Recovery Password..."
        # OS drive: use TpmProtector + RecoveryPasswordProtector; EncryptionMethod can be restricted by GPO
        Enable-BitLocker -MountPoint $mountPoint -TpmProtector -RecoveryPasswordProtector -UsedSpaceOnly -SkipHardwareTest
        Write-Log "BitLocker enable started. Volume may still be encrypting."
        $vol = Get-BitLockerVolume -MountPoint $mountPoint
    }
    else {
        Write-Log "BitLocker is already on for $mountPoint."
    }

    # --- Step 2: Ensure recovery password protector exists ---
    $recoveryProtector = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if (-not $recoveryProtector) {
        Write-Log "No recovery password found. Adding RecoveryPassword protector..."
        Add-BitLockerKeyProtector -MountPoint $mountPoint -RecoveryPasswordProtector
        $vol = Get-BitLockerVolume -MountPoint $mountPoint
        $recoveryProtector = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
        if (-not $recoveryProtector) {
            throw "Failed to add Recovery Password protector."
        }
        Write-Log "Recovery password protector added."
    }

    # --- Step 3: Backup to Azure AD if available ---
    try {
        BackupToAAD-BitLockerKeyProtector -MountPoint $mountPoint -KeyProtectorId $recoveryProtector.KeyProtectorId
        Write-Log "Recovery key backed up to Azure AD." -Level "INFO"
    }
    catch {
        Write-Log "Azure AD backup skipped or failed (not Azure AD joined or policy): $_" -Level "WARN"
    }

    # --- Step 4: Get and print recovery password for RMM ---
    $recoveryPassword = $recoveryProtector.RecoveryPassword
    if (-not $recoveryPassword) {
        $recoveryPassword = Get-BitLockerRecoveryPassword -MountPoint $mountPoint
    }
    if ($recoveryPassword) {
        Write-Log "Recovery key retrieved successfully."
        
        # Save to a persistent local path (not temp)
        $PersistentKeyFile = "C:\Windows\BitLocker-Recovery-Key.txt"
        $KeyContent = "Computer: $env:COMPUTERNAME`r`nDrive: $mountPoint`r`nRecovery Password: $recoveryPassword`r`nDate: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $KeyContent | Out-File -FilePath $PersistentKeyFile -Force
        Write-Log "Persistent backup saved to $PersistentKeyFile"

        Write-Host ""
        Write-Host "========== BITLOCKER RECOVERY PASSWORD (save this) =========="
        Write-Host "Computer: $env:COMPUTERNAME"
        Write-Host "Drive: $mountPoint"
        Write-Host "Recovery Password: $recoveryPassword"
        Write-Host "Persistent Backup: $PersistentKeyFile"
        Write-Host "=================================================================="
        Write-Host ""
        # Also set a variable RMM might read: some systems capture output variables
        $env:BitLockerRecoveryPassword = $recoveryPassword
    }
    else {
        Write-Log "Could not read recovery password (key may be TPM-only)." -Level "WARN"
    }

    Write-Log "Remediation completed successfully."
    Write-Host "SUCCESS: BitLocker is on for $mountPoint and recovery key is present (see above)."
    Write-Host "Re-run the BitLocker check to verify."
    exit $EXIT_SUCCESS
}
catch {
    Write-Log "Remediation failed: $_" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    Write-Host ""
    Write-Host "FAIL: BitLocker remediation failed - $_"
    if ($_.Exception.Message -match 'expected range|does not fall within') {
        Write-Host ""
        Write-Host "Most likely causes: (1) TPM not ready or locked - enable/clear TPM in BIOS and run Clear-Tpm or Unblock-Tpm if needed. (2) Group Policy conflict - check Computer Configuration > Administrative Templates > Windows Components > BitLocker. (3) Missing or wrong system partition - ensure UEFI/GPT install with EFI system partition."
    }
    Write-Host "Computer: $env:COMPUTERNAME"
    exit $EXIT_CRITICAL
}
