# Disable Driver Monitoring On This StarPilot Branch

This documents the StarPilot-specific DMS and no-cloud patch set, plus the install flow that keeps `Madcow333/StarPilot` and `Madcow333/openpilot` `StarPilot` aligned.

## Target Baseline

- Source repo: `https://github.com/Madcow333/StarPilot`
- Installer repo: `https://github.com/Madcow333/openpilot`
- Installer branch: `StarPilot`
- Upstream repo: `https://github.com/firestar5683/StarPilot`
- Local working branch for this port: `codex/starpilot-dms-system`

Required baseline on this fork:

- DMS disabled
- `manage_athenad` disabled
- `uploader` disabled

## What This Patch Set Changes

The required StarPilot baseline now includes all of the following:

- `dmonitoringmodeld` disabled
- `dmonitoringd` disabled
- `manage_athenad` disabled
- `uploader` disabled
- `selfdrived` no longer depends on `driverMonitoringState`
- `controlsd` no longer uses `driverMonitoringState.awarenessStatus`
- `modeld` no longer reads `driverMonitoringState.isRHD`
- driver monitoring alerts short-circuited in `helpers.py`
- seatbelt event disabled to match the fork behavior you used on the other branches
- `starpilot.common.starpilot_utilities.wait_for_no_driver()` patched so it does not hang when `dmonitoringd` is disabled

## Exact Files Changed

### 1. `system/manager/process_config.py`

Set the required background processes to `enabled=False`:

```python
DaemonProcess("manage_athenad", "system.athena.manage_athenad", "AthenadPid", enabled=False),
PythonProcess("dmonitoringmodeld", "selfdrive.modeld.dmonitoringmodeld", driverview, enabled=False),
PythonProcess("dmonitoringd", "selfdrive.monitoring.dmonitoringd", driverview, enabled=False),
PythonProcess("uploader", "system.loggerd.uploader", allow_uploads, enabled=False),
```

### 2. `selfdrive/selfdrived/selfdrived.py`

Remove the driver camera dependency and stop subscribing to DMS state:

```python
self.camera_packets = ["roadCameraState", "wideRoadCameraState"]
```

Remove `driverMonitoringState` from the `SubMaster` list and drop the event ingestion call:

```python
if not self.CP.notCar:
  self.events.add_from_msg(self.sm['driverMonitoringState'].events)
```

That block is removed entirely in the patched build.

### 3. `selfdrive/controls/controlsd.py`

Remove `driverMonitoringState` from the `SubMaster` list and keep only StarPilot's own coast logic:

```python
cs.forceDecel = bool((self.sm['selfdriveState'].state == State.softDisabling) or self.sm["starpilotCarState"].forceCoast)
```

### 4. `selfdrive/modeld/modeld.py`

Remove `driverMonitoringState` from the `SubMaster` list and hardcode left-hand drive:

```python
is_rhd = False  # DM is disabled on this fork; default to LHD.
```

If the target vehicle is right-hand drive, hardcode `True` instead.

### 5. `selfdrive/monitoring/helpers.py`

Short-circuit the alert path:

```python
def _update_events(self, driver_engaged, op_engaged, standstill, wrong_gear, car_speed):
  self._reset_events()
  # Driver monitoring alerts are disabled on this fork.
  self._reset_awareness()
  return
```

### 6. `selfdrive/car/car_specific.py`

Disable the seatbelt event:

```python
# Seatbelt warning disabled to match the DMS-disabled branch behavior.
# if CS.seatbeltUnlatched:
#   events.add(EventName.seatbeltNotLatched)
```

### 7. `starpilot/common/starpilot_utilities.py`

`wait_for_no_driver()` previously waited forever for `dmonitoringd` to start and also reset its timer forever when `driverMonitoringState` was not alive. The patched version only waits for DM when the process is actually expected to run.

That extra StarPilot-specific patch is required so the no-driver door-lock flow still completes cleanly on a DMS-disabled build.

## Future Install Command

Use the StarPilot bundle sync script:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_starpilot_to_comma.ps1
```

That one command:

1. Pushes the current committed `HEAD` to `Madcow333/StarPilot` `StarPilot`
2. Pushes the same commit to `Madcow333/openpilot` `StarPilot`
3. Builds a local git bundle
4. Pushes the bundle to the device over ADB
5. Installs it into `/data/openpilot`
6. Recreates `/data/continue.sh`
7. Reboots and verifies the running branch and commit

## Verification

Compile the edited Python files:

```powershell
python -m compileall system/manager/process_config.py selfdrive/selfdrived/selfdrived.py selfdrive/controls/controlsd.py selfdrive/modeld/modeld.py selfdrive/monitoring/helpers.py selfdrive/car/car_specific.py starpilot/common/starpilot_utilities.py
```

After install, verify the deployed repo:

```powershell
C:\platform-tools\adb.exe shell "git -c safe.directory=/data/openpilot -C /data/openpilot branch --show-current"
C:\platform-tools\adb.exe shell "git -c safe.directory=/data/openpilot -C /data/openpilot rev-parse --short HEAD"
```

Verify the disabled processes are not running:

```powershell
C:\platform-tools\adb.exe shell "ps -A | grep -E 'athena|uploader|dmonitoring' || true"
```

## Related Docs

- `docs/how-to/install-madcow333-starpilot.md`
- `docs/how-to/connect-to-comma.md`
