[CmdletBinding()]
param(
  [string]$SourceRepo = "https://github.com/Madcow333/StarPilot.git",
  [string]$SourceBranch = "StarPilot",
  [string]$SourceRemote = "origin",
  [string]$InstallerRepo = "https://github.com/Madcow333/openpilot.git",
  [string]$InstallerBranch = "StarPilot",
  [string]$InstallerRemote = "installer",
  [string]$AdbPath = "",
  [string]$DevicePath = "/data/openpilot",
  [string]$BackupPath = "/data/openpilot.backup.previous",
  [string]$ContinuePath = "/data/continue.sh",
  [string]$BundleBranch = "",
  [string]$DeviceBundlePath = "/data/starpilot-install.bundle",
  [string]$DeviceScriptPath = "/data/install-starpilot-bundle.sh",
  [switch]$SkipPush,
  [switch]$ForcePush,
  [switch]$SkipSourcePush,
  [switch]$SkipInstallerPush,
  [switch]$SkipDeviceInstall,
  [switch]$CheckAdbOnly,
  [switch]$SkipReboot,
  [switch]$AllowAnyBase,
  [switch]$KeepBundle,
  [int]$AdbCommandTimeoutSeconds = 90,
  [int]$AdbPushTimeoutSeconds = 600,
  [int]$AdbChunkTimeoutSeconds = 180,
  [int]$AdbChunkSizeMiB = 128,
  [int]$AdbInstallTimeoutSeconds = 600,
  [int]$AdbRestartTimeoutSeconds = 60,
  [int]$AdbProbeTimeoutSeconds = 15
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

function ConvertTo-ProcessArgument {
  param([AllowNull()][string]$Argument)

  if ($null -eq $Argument -or $Argument -eq "") {
    return '""'
  }

  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }

  $result = New-Object System.Text.StringBuilder
  [void]$result.Append('"')
  $backslashes = 0

  foreach ($char in $Argument.ToCharArray()) {
    if ($char -eq '\') {
      $backslashes += 1
      continue
    }
    if ($char -eq '"') {
      if ($backslashes -gt 0) {
        [void]$result.Append(('\' * ($backslashes * 2)))
      }
      [void]$result.Append('\"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$result.Append(('\' * $backslashes))
      $backslashes = 0
    }
    [void]$result.Append($char)
  }

  if ($backslashes -gt 0) {
    [void]$result.Append(('\' * ($backslashes * 2)))
  }

  [void]$result.Append('"')
  return $result.ToString()
}

function Join-ProcessArguments {
  param([string[]]$Arguments)
  return (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Argument $_ }) -join " ")
}

function Invoke-AdbProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $AdbPath
  $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $timeoutMilliseconds = [Math]::Max(1, $TimeoutSeconds) * 1000

  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutMilliseconds)) {
      try {
        $process.Kill()
      } catch {
      }
      throw "adb $($Arguments -join ' ') timed out after $TimeoutSeconds second(s)"
    }

    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    if ($process.ExitCode -ne 0) {
      $details = (($stdoutText, $stderrText) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) -join "`n"
      if ($details) {
        throw "adb $($Arguments -join ' ') failed with exit code $($process.ExitCode): $details"
      }
      throw "adb $($Arguments -join ' ') failed with exit code $($process.ExitCode)"
    }

    return [pscustomobject]@{
      Stdout = $stdoutText
      Stderr = $stderrText
    }
  } finally {
    $process.Dispose()
  }
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
  if ($result.Stdout -and $result.Stdout.Trim()) {
    Write-Host $result.Stdout.TrimEnd()
  }
  if ($result.Stderr -and $result.Stderr.Trim()) {
    Write-Host $result.Stderr.TrimEnd()
  }
}

function Get-AdbOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
  )

  $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
  return $result.Stdout.Trim()
}

function Get-DeviceFileSize {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RemotePath
  )

  $command = "stat -c %s '$RemotePath' 2>/dev/null || echo 0"
  $output = (Get-AdbOutput -Arguments @("shell", $command) -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  [long]$size = 0
  if (-not [long]::TryParse(($output -split "\r?\n")[-1], [ref]$size)) {
    throw "Could not parse device file size for $RemotePath`: $output"
  }
  return $size
}

function Wait-ForDeviceFileSize {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,
    [Parameter(Mandatory = $true)]
    [long]$ExpectedSize,
    [int]$Attempts = 3
  )

  [long]$size = 0
  for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    $size = Get-DeviceFileSize -RemotePath $RemotePath
    if ($size -eq $ExpectedSize) {
      return $size
    }
    if ($attempt -lt $Attempts) {
      Start-Sleep -Seconds 2
    }
  }
  return $size
}

function Push-AdbFileChunked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,
    [Parameter(Mandatory = $true)]
    [string]$ResumeKey
  )

  $file = Get-Item -LiteralPath $LocalPath
  $chunkSize = [long]$AdbChunkSizeMiB * 1MB
  if ($chunkSize -le 0) {
    throw "AdbChunkSizeMiB must be greater than zero"
  }

  if ($file.Length -le $chunkSize) {
    Invoke-Adb -Arguments @("push", $LocalPath, $RemotePath) -TimeoutSeconds $AdbPushTimeoutSeconds
    return
  }

  $remotePartsPath = "$RemotePath.parts-$ResumeKey"
  $localPartsPath = Join-Path $file.DirectoryName "$($file.Name).parts-$ResumeKey"
  New-Item -ItemType Directory -Path $localPartsPath -Force | Out-Null
  Invoke-Adb -Arguments @("shell", "mkdir", "-p", $remotePartsPath) -TimeoutSeconds $AdbCommandTimeoutSeconds

  $inputStream = [System.IO.File]::OpenRead($file.FullName)
  $buffer = New-Object byte[] (4MB)
  $partIndex = 0
  try {
    while ($inputStream.Position -lt $inputStream.Length) {
      $partLength = [Math]::Min($chunkSize, $inputStream.Length - $inputStream.Position)
      $partName = "part-{0:D5}" -f $partIndex
      $localPartPath = Join-Path $localPartsPath $partName
      $remotePartPath = "$remotePartsPath/$partName"
      $remotePartLength = Get-DeviceFileSize -RemotePath $remotePartPath

      if ($remotePartLength -eq $partLength) {
        Write-Host "Reusing verified device chunk $partName ($partLength bytes)"
        [void]$inputStream.Seek($partLength, [System.IO.SeekOrigin]::Current)
      } else {
        $outputStream = $null
        try {
          $outputStream = [System.IO.File]::Create($localPartPath)
          [long]$remaining = $partLength
          while ($remaining -gt 0) {
            $toRead = [int][Math]::Min($buffer.Length, $remaining)
            $read = $inputStream.Read($buffer, 0, $toRead)
            if ($read -le 0) {
              throw "Unexpected end of file while creating $partName"
            }
            $outputStream.Write($buffer, 0, $read)
            $remaining -= $read
          }
        } finally {
          if ($null -ne $outputStream) {
            $outputStream.Dispose()
          }
        }

        Write-Host "Pushing chunk $($partIndex + 1) of $([Math]::Ceiling($file.Length / $chunkSize)) ($partLength bytes)"
        Invoke-Adb -Arguments @("push", $localPartPath, $remotePartPath) -TimeoutSeconds $AdbChunkTimeoutSeconds
        # Some comma devices leave the first shell after a large push stale. The
        # shared ADB helper resets that session; retry against the recovered daemon.
        $remotePartLength = Wait-ForDeviceFileSize -RemotePath $remotePartPath -ExpectedSize $partLength
        if ($remotePartLength -ne $partLength) {
          throw "Device chunk $partName has $remotePartLength bytes; expected $partLength"
        }
        Remove-Item -LiteralPath $localPartPath -Force
      }

      $partIndex += 1
    }
  } finally {
    $inputStream.Dispose()
    Remove-Item -LiteralPath $localPartsPath -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Reassembling $partIndex verified chunks on the device"
  $assembleCommand = "rm -f '$RemotePath' && cat '$remotePartsPath'/part-* > '$RemotePath'"
  Invoke-Adb -Arguments @("shell", $assembleCommand) -TimeoutSeconds $AdbPushTimeoutSeconds
  $remoteLength = Wait-ForDeviceFileSize -RemotePath $RemotePath -ExpectedSize $file.Length
  if ($remoteLength -ne $file.Length) {
    throw "Reassembled device file has $remoteLength bytes; expected $($file.Length)"
  }
  Invoke-Adb -Arguments @("shell", "rm", "-rf", $remotePartsPath) -TimeoutSeconds $AdbCommandTimeoutSeconds
}

function Request-DeviceReboot {
  $rebootAttempts = @(
    @{ Label = "device shell reboot"; Args = @("shell", "reboot") },
    @{ Label = "device powerctl reboot"; Args = @("shell", "setprop", "sys.powerctl", "reboot") },
    @{ Label = "adb reboot"; Args = @("reboot") }
  )

  foreach ($attempt in $rebootAttempts) {
    try {
      Write-Host "Using reboot method: $($attempt.Label)"
      Invoke-Adb -Arguments $attempt.Args -TimeoutSeconds $AdbRestartTimeoutSeconds
      return
    } catch {
      Write-Warning "$($attempt.Label) failed: $($_.Exception.Message)"
    }
  }

  throw "Unable to request a device reboot over adb"
}

function Wait-ForAdbDevice {
  param([int]$TimeoutSeconds = 90)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $resetAttempted = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
      $onlineDevices = @(
        $devices -split "\r?\n" |
          Where-Object { $_ -match "^\S+\s+device$" }
      )
      if ($onlineDevices.Count -gt 0) {
        if (Get-Command Reset-AdbDaemon -ErrorAction SilentlyContinue) {
          Reset-AdbDaemon -AdbPath $AdbPath
        }
        return
      }
    } catch {
      if (-not $resetAttempted -and (Get-Command Reset-AdbDaemon -ErrorAction SilentlyContinue)) {
        $resetAttempted = $true
        try { Reset-AdbDaemon -AdbPath $AdbPath } catch { }
      }
    }

    Start-Sleep -Seconds 2
  }

  throw "Timed out waiting for an adb device after $TimeoutSeconds second(s)."
}

function Wait-ForDeviceReady {
  param([int]$TimeoutSeconds = 360)

  Wait-ForAdbDevice -TimeoutSeconds $TimeoutSeconds

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5

    foreach ($bootProbe in @(
      @{ Args = @("shell", "getprop", "sys.boot_completed"); ReadyValue = "1" },
      @{ Args = @("shell", "getprop", "dev.bootcomplete"); ReadyValue = "1" },
      @{ Args = @("shell", "getprop", "service.bootanim.exit"); ReadyValue = "1" }
    )) {
      try {
        $probeValue = (Get-AdbOutput -Arguments $bootProbe.Args -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
        if ($probeValue -eq $bootProbe.ReadyValue) {
          return
        }
      } catch {
      }
    }

    try {
      $gitHead = (Get-AdbOutput -Arguments @("shell", "git", "-c", "safe.directory=$DevicePath", "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
      if ($gitHead) {
        return
      }
    } catch {
    }

    try {
      $launchScriptReady = (Get-AdbOutput -Arguments @("shell", "test -x $DevicePath/launch_openpilot.sh && echo ready") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
      if ($launchScriptReady -eq "ready") {
        return
      }
    } catch {
    }
  }

  throw @"
Timed out waiting for the device to come back online after reboot.

Some comma units can boot into a USB recovery/adb mode when the data cable stays connected during restart.
If that happens, disconnect the USB data cable, boot the comma on power only, then reconnect data after the normal boot screen appears.
"@
}

function Invoke-StarPilotDeviceHarden {
  param(
    [switch]$ClearMsgq
  )

  # Prefer the host-managed harden script so deploys always get latest fixes,
  # even if the installed branch is older than Fork Manager.
  $hostHarden = Join-Path $PSScriptRoot "starpilot_device_harden.sh"
  if (-not (Test-Path -LiteralPath $hostHarden)) {
    $hostHarden = Join-Path (Split-Path -Parent $PSScriptRoot) "..\scripts\starpilot_device_harden.sh"
    $hostHarden = [System.IO.Path]::GetFullPath($hostHarden)
  }
  if (-not (Test-Path -LiteralPath $hostHarden)) {
    # Fall back to in-tree path relative to this repo when script lives under StarPilot/scripts
    $hostHarden = Join-Path $PSScriptRoot "starpilot_device_harden.sh"
  }

  if (-not (Test-Path -LiteralPath $hostHarden)) {
    Write-Warning "starpilot_device_harden.sh not found next to deploy script; skipping device harden."
    return
  }

  $remoteHarden = "/data/starpilot_device_harden.sh"
  Write-Step "Hardening StarPilot on device (capnp libs, +x bins, msgq, pandad)"
  Invoke-Adb -Arguments @("push", $hostHarden, $remoteHarden) -TimeoutSeconds $AdbPushTimeoutSeconds
  $clearFlag = if ($ClearMsgq) { "1" } else { "0" }
  $cmd = "sed -i 's/\r$//' $remoteHarden; chmod +x $remoteHarden; DEVICE_PATH=$DevicePath CLEAR_MSGQ=$clearFlag bash $remoteHarden"
  Invoke-Adb -Arguments @("shell", $cmd) -TimeoutSeconds $AdbInstallTimeoutSeconds
}

function Start-InstalledSoftware {
  # Stop openpilot, clear stale msgq (fork switches corrupt deviceState), re-harden, start.
  $deviceStartScript = @'
set -e
pkill -9 -f 'launch_chffrplus.sh|system/manager/manager.py|./manager.py|system.updated.updated|selfdrive.pandad.pandad|./pandad|selfdrive.ui.ui|system/ui/text.py|spinner.py|build.py|starpilot\.|the_pond|device_syncd|mapd_wrapper|starpilot_process|galaxy|system\.hardware|camerad|modeld' || true
sleep 1
# Stale /dev/shm/msgq_* after fork switch leaves UI on "start the car" with ignition on.
rm -f /dev/shm/msgq_*
if [ -x /data/starpilot_device_harden.sh ]; then
  DEVICE_PATH=__DEVICE_PATH__ CLEAR_MSGQ=0 bash /data/starpilot_device_harden.sh || true
elif [ -x __DEVICE_PATH__/scripts/starpilot_device_harden.sh ]; then
  DEVICE_PATH=__DEVICE_PATH__ CLEAR_MSGQ=0 bash __DEVICE_PATH__/scripts/starpilot_device_harden.sh || true
fi
rm -f /tmp/fork-switch-launch.log
# Prefer systemd comma.service when present (sets up tmux + env correctly).
if systemctl list-unit-files comma.service >/dev/null 2>&1; then
  systemctl restart comma.service || systemctl start comma.service || true
  sleep 2
  if systemctl is-active --quiet comma.service; then
    exit 0
  fi
fi
sudo -u comma bash -lc 'cd __DEVICE_PATH__ && nohup ./launch_openpilot.sh >/tmp/fork-switch-launch.log 2>&1 &'
'@

  $deviceStartScript = $deviceStartScript.Replace("__DEVICE_PATH__", $DevicePath)
  $deviceStartScript = $deviceStartScript.Replace("`r`n", "`n")
  Invoke-Adb -Arguments @("shell", $deviceStartScript) -TimeoutSeconds $AdbRestartTimeoutSeconds
}

function Wait-ForSoftwareReady {
  param([int]$TimeoutSeconds = 120)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5

    try {
      $procSummary = Get-AdbOutput -Arguments @("shell", "pgrep -af 'manager.py|build.py|spinner.py|text.py|selfdrive.ui.ui|selfdrive.pandad.pandad|./pandad' || true") -TimeoutSeconds $AdbProbeTimeoutSeconds
    } catch {
      continue
    }

    if ($procSummary -match 'manager\.py|build\.py|spinner\.py|selfdrive\.ui\.ui|selfdrive\.pandad\.pandad|\.\/pandad') {
      return $true
    }

    if ($procSummary -match 'text\.py') {
      return $false
    }
  }

  return $false
}

function Get-DevicePandaCounts {
  $probe = @'
import sys
sys.path.insert(0, "/data/openpilot")
from panda import Panda, PandaDFU
print(f"{len(Panda.list())},{len(PandaDFU.list())}")
'@

  $localProbePath = Join-Path ([System.IO.Path]::GetTempPath()) ("panda-visibility-" + [guid]::NewGuid().ToString("N") + ".py")
  $remoteProbePath = "/data/panda-visibility-$([guid]::NewGuid().ToString('N')).py"

  try {
    [System.IO.File]::WriteAllText($localProbePath, $probe, [System.Text.UTF8Encoding]::new($false))
    Invoke-Adb -Arguments @("push", $localProbePath, $remoteProbePath) -TimeoutSeconds $AdbPushTimeoutSeconds
    $output = Get-AdbOutput -Arguments @("shell", "cd /data/openpilot && PYTHONPATH=/data/openpilot /usr/local/venv/bin/python3 $remoteProbePath") -TimeoutSeconds $AdbCommandTimeoutSeconds
  } finally {
    Remove-Item -LiteralPath $localProbePath -Force -ErrorAction SilentlyContinue
    try {
      Invoke-Adb -Arguments @("shell", "rm", "-f", $remoteProbePath) -TimeoutSeconds $AdbProbeTimeoutSeconds
    } catch {
    }
  }

  $parts = (($output | Out-String).Trim()) -split ","
  if ($parts.Count -ne 2) {
    throw "Unexpected panda visibility probe output: $output"
  }

  return @{
    PandaCount = [int]$parts[0]
    DfuCount = [int]$parts[1]
  }
}

if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
  $adbCandidates = @(
    (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "tools\platform-tools\adb.exe"),
    "C:\platform-tools\adb.exe"
  )
  foreach ($candidate in $adbCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      $AdbPath = (Resolve-Path -LiteralPath $candidate).Path
      break
    }
  }
  if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
    $adbCommand = Get-Command adb -ErrorAction SilentlyContinue
    if ($adbCommand) {
      $AdbPath = $adbCommand.Source
    }
  }
}
if (-not $AdbPath -or -not (Test-Path -LiteralPath $AdbPath)) {
  throw "ADB not found. Pass -AdbPath, run Fork_Manager.bat setup adb, or put adb.exe on PATH."
}

$adbSessionHelper = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts\adb_session.ps1"
if (Test-Path -LiteralPath $adbSessionHelper) {
  . $adbSessionHelper
  # Shared adb_session.ps1 overwrites Invoke-Adb with a different signature that
  # requires -AdbPath and returns a result object. Re-bind the deploy wrappers so
  # the rest of this script keeps using Invoke-AdbProcess (push/shell/timeouts).
  function Invoke-Adb {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Arguments,
      [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
    )

    $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.Stdout -and $result.Stdout.Trim()) {
      Write-Host $result.Stdout.TrimEnd()
    }
    if ($result.Stderr -and $result.Stderr.Trim()) {
      Write-Host $result.Stderr.TrimEnd()
    }
  }

  function Get-AdbOutput {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Arguments,
      [int]$TimeoutSeconds = $AdbCommandTimeoutSeconds
    )

    $result = Invoke-AdbProcess -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    return $result.Stdout.Trim()
  }
} else {
  Write-Warning "Shared ADB session helper missing: $adbSessionHelper"
}

if ($CheckAdbOnly) {
  Write-Step "Checking adb connection"
  if (Get-Command Ensure-AdbSession -ErrorAction SilentlyContinue) {
    $null = Ensure-AdbSession -AdbPath $AdbPath -ProbeShell
  }
  $devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
  $onlineDevices = @(
    $devices -split "\r?\n" |
      Where-Object { $_ -match "^\S+\s+device$" } |
      ForEach-Object { ($_ -split "\s+")[0] }
  )
  if ($onlineDevices.Count -eq 0) {
    throw "No adb device detected"
  }
  if ($onlineDevices.Count -gt 1 -and -not $env:ANDROID_SERIAL) {
    throw "Multiple adb devices detected ($($onlineDevices -join ', ')). Set ANDROID_SERIAL or disconnect the extra devices."
  }

  $deviceSerial = if ($env:ANDROID_SERIAL) { $env:ANDROID_SERIAL } else { $onlineDevices[0] }
  Write-Host "ADB device: $deviceSerial"

  try {
    $safeDirectory = "safe.directory=$DevicePath"
    $deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "branch", "--show-current") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
    $deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
    Write-Host "Device branch: $deviceBranch"
    Write-Host "Device commit: $deviceCommit"
  } catch {
    Write-Warning "ADB is connected, but $DevicePath could not be inspected: $($_.Exception.Message)"
  }

  if (Get-Command Finalize-AdbSession -ErrorAction SilentlyContinue) {
    Finalize-AdbSession -AdbPath $AdbPath
  }
  exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location -LiteralPath $repoRoot

Write-Step "Checking repository state"
$insideRepo = Get-GitOutput -Arguments @("rev-parse", "--is-inside-work-tree")
if ($insideRepo -ne "true") {
  throw "$repoRoot is not a git repository"
}

$currentBranch = Get-GitOutput -Arguments @("branch", "--show-current")
$statusShort = Get-GitOutput -Arguments @("status", "--short")
$bundleSourceBranch = if ($BundleBranch) { $BundleBranch } else { $currentBranch }
$sourceRef = "HEAD"

if (-not $bundleSourceBranch) {
  throw "Could not determine a branch name for bundle creation. Check out a branch or pass -BundleBranch."
}

if ($bundleSourceBranch) {
  $branchRef = "refs/heads/$bundleSourceBranch"
  try {
    Get-GitOutput -Arguments @("rev-parse", "--verify", $branchRef) | Out-Null
    $sourceRef = $branchRef
  } catch {
    if ($BundleBranch) {
      throw "BundleBranch '$BundleBranch' was not found locally. Create it first or check out the branch you want to install."
    }
  }
}

$headCommit = Get-GitOutput -Arguments @("rev-parse", $sourceRef)
$headCommitShort = Get-GitOutput -Arguments @("rev-parse", "--short", $sourceRef)

if ($statusShort) {
  if ($BundleBranch -and $BundleBranch -ne $currentBranch) {
    Write-Warning "Working tree is not clean. This run is deploying committed branch $BundleBranch, so uncommitted changes on $currentBranch will not be included."
  } else {
    Write-Warning "Working tree is not clean. This script syncs committed HEAD only; uncommitted changes will not be included."
  }
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
  & git merge-base --is-ancestor "refs/remotes/$InstallerRemote/$InstallerBranch" $sourceRef
  if ($LASTEXITCODE -ne 0) {
    throw @"
$bundleSourceBranch is not based on $InstallerRemote/$InstallerBranch.

This flow expects a StarPilot branch derived from the current installer branch.
Check out the installer branch first, or rerun with -AllowAnyBase if you really want to override that guard.
"@
  }
}

if (-not $SkipPush) {
  if (-not $SkipSourcePush) {
    Write-Step "Pushing $headCommitShort from $bundleSourceBranch to $SourceRemote/$SourceBranch"
    $sourcePushArgs = @("push", $SourceRemote, "$sourceRef`:refs/heads/$SourceBranch")
    if ($ForcePush) {
      $sourcePushArgs += "--force-with-lease"
    }
    Invoke-Git -Arguments $sourcePushArgs
  } else {
    Write-Step "Skipping source repo push"
  }

  if (-not $SkipInstallerPush) {
    Write-Step "Pushing $headCommitShort from $bundleSourceBranch to $InstallerRemote/$InstallerBranch"
    $installerPushArgs = @("push", $InstallerRemote, "$sourceRef`:refs/heads/$InstallerBranch")
    if ($ForcePush) {
      $installerPushArgs += "--force-with-lease"
    }
    Invoke-Git -Arguments $installerPushArgs
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
  Invoke-Git -Arguments @("bundle", "create", $bundlePath, $sourceRef)

  if ($SkipDeviceInstall) {
    Write-Step "Skipping device install"
    Write-Host "Source branch:     $bundleSourceBranch"
    Write-Host "Source commit:     $headCommitShort"
    Write-Host "Source repo:      $SourceRepo branch $SourceBranch"
    Write-Host "Installer target: $InstallerRepo branch $InstallerBranch"
    if ($KeepBundle) {
      Write-Host "Local bundle kept at: $bundlePath"
    }
    exit 0
  }

  Write-Step "Checking adb connection"
  # Do not ProbeShell here: a false hung-shell probe would kill-server right before
  # the multi-minute bundle push and brick the transfer.
  if (Get-Command Ensure-AdbSession -ErrorAction SilentlyContinue) {
    $null = Ensure-AdbSession -AdbPath $AdbPath
  }
  $devices = Get-AdbOutput -Arguments @("devices") -TimeoutSeconds $AdbProbeTimeoutSeconds
  $onlineDevices = @(
    $devices -split "\r?\n" |
      Where-Object { $_ -match "^\S+\s+device$" }
  )
  if ($onlineDevices.Count -eq 0) {
    throw "No adb device detected"
  }

  $deviceInstallScript = @'
set -e

pkill -9 -f 'launch_chffrplus.sh|system/manager/manager.py|./manager.py|system.updated.updated|selfdrive.pandad.pandad|./pandad|selfdrive.ui.ui|system/ui/text.py|starpilot\.' || true

if grep -q ' /data/safe_staging/merged ' /proc/mounts 2>/dev/null; then
  umount -l /data/safe_staging/merged || true
fi

rm -rf /data/safe_staging
rm -f /tmp/safe_staging_overlay.lock

rm -rf __TMP_PATH__
git clone -b __BUNDLE_BRANCH__ __DEVICE_BUNDLE_PATH__ __TMP_PATH__
git -C __TMP_PATH__ branch -M __INSTALLER_BRANCH__
git -C __TMP_PATH__ remote set-url origin __INSTALLER_REPO__

rm -rf __BACKUP_PATH__
if [ -d __DEVICE_PATH__ ]; then
  mv __DEVICE_PATH__ __BACKUP_PATH__
fi
mv __TMP_PATH__ __DEVICE_PATH__

# Align AGNOS startup gate with the OS already on this comma.
if [ -r /VERSION ]; then
  device_agnos="$(tr -d '\n\r' < /VERSION)"
  for launch_env in __DEVICE_PATH__/launch_env.sh __DEVICE_PATH__/sunnypilot/system/hardware/c3/launch_env.sh; do
    [ -f "$launch_env" ] || continue
    if grep -q 'export AGNOS_VERSION=' "$launch_env"; then
      sed -i "s/export AGNOS_VERSION=\"[^\"]*\"/export AGNOS_VERSION=\"${device_agnos}\"/" "$launch_env"
    fi
  done
fi

mkdir -p /data/params/d
printf '%s' '__INSTALLER_BRANCH__' > /data/params/d/UpdaterTargetBranch
printf '%s' 'idle' > /data/params/d/UpdaterState
rm -f /data/params/d/UpdaterNewDescription /data/params/d/UpdaterNewReleaseNotes /data/params/d/LastUpdateException
chown comma:comma /data/params/d/UpdaterTargetBranch /data/params/d/UpdaterState 2>/dev/null || true

cat >__CONTINUE_PATH__ <<'EOF'
#!/usr/bin/env bash

cd __DEVICE_PATH__
exec ./launch_openpilot.sh
EOF

chmod +x __CONTINUE_PATH__
chown comma:comma __CONTINUE_PATH__
chown -R comma:comma __DEVICE_PATH__

# In-tree harden if present (source-shipped). Host deploy also runs the latest
# host copy after this script so Fork Manager always applies current fixes.
if [ -x __DEVICE_PATH__/scripts/starpilot_device_harden.sh ]; then
  DEVICE_PATH=__DEVICE_PATH__ CLEAR_MSGQ=1 bash __DEVICE_PATH__/scripts/starpilot_device_harden.sh || true
fi

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
  Push-AdbFileChunked -LocalPath $bundlePath -RemotePath $DeviceBundlePath -ResumeKey $headCommitShort
  Invoke-Adb -Arguments @("push", $localInstallScriptPath, $DeviceScriptPath) -TimeoutSeconds $AdbPushTimeoutSeconds

  Write-Step "Installing committed local repo to the device"
  Invoke-Adb -Arguments @("shell", "sh", $DeviceScriptPath) -TimeoutSeconds $AdbInstallTimeoutSeconds

  $safeDirectory = "safe.directory=$DevicePath"
  $deviceCommitBeforeReboot = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  if ($deviceCommitBeforeReboot -ne $headCommit) {
    throw "Device install did not stage expected commit $headCommit before reboot. Device is still on $deviceCommitBeforeReboot."
  }

  # Always run host harden after install (capnp shared libs must be built on-device;
  # +x bits / msgq clear / pandad SPI hang fix).
  try {
    Invoke-StarPilotDeviceHarden -ClearMsgq
  } catch {
    Write-Warning "StarPilot device harden failed: $($_.Exception.Message)"
  }

  if (-not $SkipReboot) {
    Write-Step "Restarting software and waiting for it to start"
    $softwareRestarted = $false
    try {
      Start-InstalledSoftware
      $softwareRestarted = Wait-ForSoftwareReady
    } catch {
      Write-Warning "Soft restart failed, falling back to a full reboot."
    }

    if (-not $softwareRestarted) {
      Write-Step "Falling back to full device reboot"
      Request-DeviceReboot
      Wait-ForDeviceReady
    }
  } else {
    Write-Step "Skipping reboot"
  }

  Write-Step "Verifying deployed branch"
  $deviceBranch = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "branch", "--show-current") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  $deviceCommit = (Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "rev-parse", "--short", "HEAD") -TimeoutSeconds $AdbProbeTimeoutSeconds).Trim()
  $deviceRemote = Get-AdbOutput -Arguments @("shell", "git", "-c", $safeDirectory, "-C", $DevicePath, "remote", "-v") -TimeoutSeconds $AdbProbeTimeoutSeconds
  $pandaStatus = Get-DevicePandaCounts

  if (($pandaStatus.PandaCount + $pandaStatus.DfuCount) -eq 0) {
    Write-Warning @"
StarPilot is installed, but the device currently sees no panda hardware.

If the comma is booted only from USB power, or the harness/vehicle ignition is off, the UI can show "update required"
until the panda is visible again. Boot the comma on normal car/harness power, then reconnect USB data after the normal boot
screen appears if needed.
"@
  }

  Write-Host ""
  Write-Host "Sync complete." -ForegroundColor Green
  Write-Host "Local branch:     $bundleSourceBranch"
  Write-Host "Local commit:     $headCommitShort"
  Write-Host "Device branch:    $deviceBranch"
  Write-Host "Device commit:    $deviceCommit"
  Write-Host "Visible pandas:   $($pandaStatus.PandaCount)"
  Write-Host "DFU pandas:       $($pandaStatus.DfuCount)"
  Write-Host "Source repo:      $SourceRepo"
  Write-Host "Installer repo:   $InstallerRepo"
  Write-Host "Remote state:"
  Write-Host $deviceRemote
} finally {
  if (-not $KeepBundle) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Get-Command Finalize-AdbSession -ErrorAction SilentlyContinue) {
    Finalize-AdbSession -AdbPath $AdbPath
  }
}
