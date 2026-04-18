# Install Madcow333 StarPilot On comma 4

This is the recommended guide for future installs from this repo to the comma 4.

This fork's supported baseline includes the required no-cloud DMS build: `manage_athenad` and `uploader` are disabled as part of the baseline, not optional extras.

## What Actually Gets Installed

The install flow keeps two GitHub targets aligned:

- Source repo: `https://github.com/Madcow333/StarPilot`
- Source branch: `StarPilot`
- Installer repo: `https://github.com/Madcow333/openpilot`
- Installer branch: `StarPilot`

For the built-in custom software UI, the string to use is:

```text
Madcow333/StarPilot
```

That points at the `Madcow333/openpilot` installer repo on branch `StarPilot`.

This repo also sets StarPilot's built-in setup default to `https://installer.comma.ai/Madcow333/StarPilot`, so the stock StarPilot selection points at your fork instead of upstream.

## Why This Flow Exists

The reliable install path is not just "push a branch and hope the device can clone it."

The problems this flow avoids are:

- the device failing to reach GitHub cleanly
- the installed branch and the source fork drifting apart
- local committed changes not matching what actually lands on the device
- losing the last working install during recovery

## Recommended Future Install Command

From this repo on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1
```

The script will:

1. Verify the current repo and branch state.
2. Confirm `HEAD` is based on `installer/StarPilot` unless you override it.
3. Push the current committed `HEAD` to `Madcow333/StarPilot` branch `StarPilot`.
4. Push the same commit to `Madcow333/openpilot` branch `StarPilot`.
5. Build a local git bundle of the committed repo state.
6. Push that bundle to the connected device over ADB.
7. Install the bundle into `/data/openpilot`.
8. Recreate `/data/continue.sh`.
9. Reboot the device.
10. Verify the booted branch and commit.

Why this is the preferred future install flow:

- it installs the exact committed local repo, not just whatever the device can fetch
- it does not depend on the comma being able to resolve GitHub correctly
- it copies docs and helper scripts to the device with the code
- it keeps `/data/openpilot.backup.previous` as a rollback copy

## Useful Flags

```powershell
# Push only, do not touch the device
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -SkipDeviceInstall

# Reinstall on the device without pushing first
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -SkipPush

# Skip only the source repo push
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -SkipSourcePush

# Skip only the installer repo push
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -SkipInstallerPush

# Skip the reboot step
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -SkipReboot

# Override the installer ancestry safety check
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -AllowAnyBase

# Keep the local git bundle after the sync
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1 -KeepBundle
```

## Future Install Workflow

When you want to install a new StarPilot change later:

1. Start from `installer/StarPilot` or a branch based on it.
2. Make and commit your changes locally.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1
```

4. Wait for the reboot and verification output.

That one command updates both GitHub branches and syncs the same committed repo to the device over ADB.

## Recommended Branch Workflow

Before making comma 4 targeted changes, start from the installer branch:

```powershell
git fetch installer StarPilot
git checkout -B StarPilot installer/StarPilot
```

Then branch from there for your changes:

```powershell
git checkout -b my-fix
```

That keeps future installs aligned with the real installer branch.

## Related Docs

- `docs/how-to/disable-driver-monitoring-starpilot.md`
  Exact DMS-disable and required cloud-disable patch that was applied to this StarPilot build, including the extra `wait_for_no_driver()` fix.
- `docs/how-to/connect-to-comma.md`
  ADB and SSH setup details.

## Legacy Path

The built-in custom software UI can still be used for normal installs, but the ADB bundle sync script is the preferred recovery-safe path for future work on this fork.
