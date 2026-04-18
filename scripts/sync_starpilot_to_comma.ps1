[CmdletBinding()]
param(
  [string]$SourceRepo = "https://github.com/Madcow333/StarPilot.git",
  [string]$SourceBranch = "StarPilot",
  [string]$SourceRemote = "origin",
  [string]$InstallerRepo = "https://github.com/Madcow333/openpilot.git",
  [string]$InstallerBranch = "StarPilot",
  [string]$InstallerRemote = "installer",
  [string]$AdbPath = "C:\platform-tools\adb.exe",
  [string]$DevicePath = "/data/openpilot",
  [string]$BackupPath = "/data/openpilot.backup.previous",
  [string]$ContinuePath = "/data/continue.sh",
  [string]$BundleBranch = "",
  [string]$DeviceBundlePath = "/data/starpilot-install.bundle",
  [string]$DeviceScriptPath = "/data/install-starpilot-bundle.sh",
  [switch]$SkipPush,
  [switch]$SkipSourcePush,
  [switch]$SkipInstallerPush,
  [switch]$SkipDeviceInstall,
  [switch]$SkipReboot,
  [switch]$AllowAnyBase,
  [switch]$KeepBundle
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-GitOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return ($output | Out-String).Trim()
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & $AdbPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Get-AdbOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & $AdbPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return ($output | Out-String).Trim()
}

function Wait-ForBootCompleted {
  param([int]$TimeoutSeconds = 360)

  Invoke-Adb -Arguments @("wait-for-device")

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $bootCompleted = (Get-AdbOutput -Arguments @("shell", "getprop", "sys.boot_completed")).Trim()
    if ($bootCompleted -eq "1") {
      return
    }
  }

  throw "Timed out waiting for sys.boot_completed=1"
}

if (-not (Test-Path -LiteralPath $AdbPath)) {
  throw "ADB not found at $AdbPath"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location -LiteralPath $repoRoot

Write-Step "Checking repository state"
$insideRepo = Get-GitOutput -Arguments @("rev-parse", "--is-inside-work-tree")
if ($insideRepo -ne "true") {
  throw "$repoRoot is not a git repository"
}

$headCommitShort = Get-GitOutput -Arguments @("rev-parse", "--short", "HEAD")
$currentBranch = Get-GitOutput -Arguments @("branch", "--show-current")
$statusShort = Get-GitOutput -Arguments @("status", "--short")
$bundleSourceBranch = if ($BundleBranch) { $BundleBranch } else { $currentBranch }

if ($statusShort) {
  Write-Warning "Working tree is not clean. This script syncs committed HEAD only; uncommitted changes will not be included."
}

if (-not $bundleSourceBranch) {
  throw "Could not determine a branch name for bundle creation. Check out a branch or pass -BundleBranch."
}

$remotes = @((Get-GitOutput -Arguments @("remote")) -split "\r?\n" | Where-Object { $_ })
if ($InstallerRemote -notin $remotes) {
  Write-Step "Adding installer remote $InstallerRemote"
  Invoke-Git -Arguments @("remote", "add", $InstallerRemote, $InstallerRepo)
} else {
  Write-Step "Refreshing installer remote $InstallerRemote"
  Invoke-Git -Arguments @("remote", "set-url", $InstallerRemote, $InstallerRepo)
}

if ($SourceRemote -notin $remotes) {
  Write-Step "Adding source remote $SourceRemote"
  Invoke-Git -Arguments @("remote", "add", $SourceRemote, $SourceRepo)
} else {
  Write-Step "Refreshing source remote $SourceRemote"
  Invoke-Git -Arguments @("remote", "set-url", $SourceRemote, $SourceRepo)
}

Write-Step "Fetching installer branch metadata"
Invoke-Git -Arguments @("fetch", $InstallerRemote, $InstallerBranch)

if (-not $AllowAnyBase) {
  & git merge-base --is-ancestor "refs/remotes/$InstallerRemote/$InstallerBranch" "HEAD"
  if ($LASTEXITCODE -ne 0) {
    throw @"
HEAD is not based on $InstallerRemote/$InstallerBranch.

This flow expects a StarPilot branch derived from the current installer branch.
Check out the installer branch first, or rerun with -AllowAnyBase if you really want to override that guard.
"@
  }
}

if (-not $SkipPush) {
  if (-not $SkipSourcePush) {
    Write-Step "Pushing $headCommitShort to $SourceRemote/$SourceBranch"
    Invoke-Git -Arguments @("push", $SourceRemote, "HEAD:refs/heads/$SourceBranch")
  } else {
    Write-Step "Skipping source repo push"
  }

  if (-not $SkipInstallerPush) {
    Write-Step "Pushing $headCommitShort to $InstallerRemote/$InstallerBranch"
    Invoke-Git -Arguments @("push", $InstallerRemote, "HEAD:refs/heads/$InstallerBranch")
  } else {
    Write-Step "Skipping installer repo push"
  }
} else {
  Write-Step "Skipping git push"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "starpilot-sync-$headCommitShort"
$bundlePath = Join-Path $tempDir "starpilot-$headCommitShort.bundle"
$localInstallScriptPath = Join-Path $tempDir "install-starpilot-bundle.sh"
$tmpPath = "/data/tmppilot"

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
  Write-Step "Creating local git bundle"
  Invoke-Git -Arguments @("bundle", "create", $bundlePath, $bundleSourceBranch)

  if ($SkipDeviceInstall) {
    Write-Step "Skipping device install"
    Write-Host "Source repo:      $SourceRepo branch $SourceBranch"
    Write-Host "Installer target: $InstallerRepo branch $InstallerBranch"
    if ($KeepBundle) {
      Write-Host "Local bundle kept at: $bundlePath"
    }
    exit 0
  }

  Write-Step "Checking adb connection"
  $devices = Get-AdbOutput -Arguments @("devices")
  $onlineDevices = @(
    $devices -split "\r?\n" |
      Where-Object { $_ -match "^\S+\s+device$" }
  )
  if ($onlineDevices.Count -eq 0) {
    throw "No adb device detected"
  }

  $deviceInstallScript = @'
set -e

rm -rf __TMP_PATH__
git clone -b __BUNDLE_BRANCH__ __DEVICE_BUNDLE_PATH__ __TMP_PATH__
git -C __TMP_PATH__ branch -M __INSTALLER_BRANCH__
git -C __TMP_PATH__ remote set-url origin __INSTALLER_REPO__

rm -rf __BACKUP_PATH__
if [ -d __DEVICE_PATH__ ]; then
  mv __DEVICE_PATH__ __BACKUP_PATH__
fi
mv __TMP_PATH__ __DEVICE_PATH__

cat >__CONTINUE_PATH__ <<'EOF'
#!/usr/bin/env bash

cd __DEVICE_PATH__
exec ./launch_openpilot.sh
EOF

chmod +x __CONTINUE_PATH__
chown comma:comma __CONTINUE_PATH__
chown -R comma:comma __DEVICE_PATH__
rm -f __DEVICE_BUNDLE_PATH__
rm -f __DEVICE_SCRIPT_PATH__
sync
'@

  $deviceInstallScript = $deviceInstallScript.Replace("__TMP_PATH__", $tmpPath)
  $deviceInstallScript = $deviceInstallScript.Replace("__BUNDLE_BRANCH__", $bundleSourceBranch)
  $deviceInstallScript = $deviceInstallScript.Replace("__DEVICE_BUNDLE_PATH__", $DeviceBundlePath)
  $deviceInstallScript = $deviceInstallScript.Replace("__INSTALLER_BRANCH__", $InstallerBranch)
  $deviceInstallScript = $deviceInstallScript.Replace("__INSTALLER_REPO__", $InstallerRepo)
  $deviceInstallScript = $deviceInstallScript.Replace("__BACKUP_PATH__", $BackupPath)
  $deviceInstallScript = $deviceInstallScript.Replace("__DEVICE_PATH__", $DevicePath)
  $deviceInstallScript = $deviceInstallScript.Replace("__CONTINUE_PATH__", $ContinuePath)
  $deviceInstallScript = $deviceInstallScript.Replace("__DEVICE_SCRIPT_PATH__", $DeviceScriptPath)

  $deviceInstallScript = $deviceInstallScript.Replace("`r`n", "`n")
  [System.IO.File]::WriteAllText($localInstallScriptPath, $deviceInstallScript, [System.Text.UTF8Encoding]::new($false))

  Write-Step "Pushing bundle and install script over adb"
  Invoke-Adb -Arguments @("push", $bundlePath, $DeviceBundlePath)
  Invoke-Adb -Arguments @("push", $localInstallScriptPath, $DeviceScriptPath)

  Write-Step "Installing committed local repo to the device"
  Invoke-Adb -Arguments @("shell", "sh", $DeviceScriptPath)

  if (-not $SkipReboot) {
    Write-Step "Rebooting and waiting for the device"
    Invoke-Adb -Arguments @("reboot")
    Wait-ForBootCompleted
  } else {
    Write-Step "Skipping reboot"
  }

  Write-Step "Verifying deployed branch"
  $safeDirectory = "safe.directory=$DevicePath"
  $deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "branch", "--show-current")).Trim()
  $deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "--short", "HEAD")).Trim()
  $deviceRemote = Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "remote", "-v")

  Write-Host ""
  Write-Host "Sync complete." -ForegroundColor Green
  Write-Host "Local branch:     $currentBranch"
  Write-Host "Local commit:     $headCommitShort"
  Write-Host "Device branch:    $deviceBranch"
  Write-Host "Device commit:    $deviceCommit"
  Write-Host "Source repo:      $SourceRepo"
  Write-Host "Installer repo:   $InstallerRepo"
  Write-Host "Remote state:"
  Write-Host $deviceRemote
} finally {
  if (-not $KeepBundle) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
