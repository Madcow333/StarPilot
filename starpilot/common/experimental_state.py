#!/usr/bin/env python3
from __future__ import annotations

from openpilot.common.params import Params

PERSIST_EXPERIMENTAL_STATE_PARAM = "PersistExperimentalState"
PERSISTED_CE_STATUS_PARAM = "PersistedCEStatus"
CE_STATUS_PARAM = "CEStatus"

CEStatus = {
  "OFF": 0,
  "USER_DISABLED": 1,
  "USER_OVERRIDDEN": 2,
  "CURVATURE": 3,
  "LEAD": 4,
  "SIGNAL": 5,
  "SPEED": 6,
  "SPEED_LIMIT": 7,
  "STOP_LIGHT": 8,
}

MANUAL_CE_STATUSES = {
  CEStatus["USER_DISABLED"],
  CEStatus["USER_OVERRIDDEN"],
}


def is_manual_ce_status(status: int) -> bool:
  return int(status) in MANUAL_CE_STATUSES


def normalize_persisted_ce_status(status: int) -> int:
  status = int(status)
  return status if status in MANUAL_CE_STATUSES else CEStatus["OFF"]


def get_persisted_ce_status(params: Params) -> int:
  return normalize_persisted_ce_status(params.get_int(PERSISTED_CE_STATUS_PARAM, default=CEStatus["OFF"]))


def set_persisted_ce_status(params: Params, status: int) -> int:
  normalized = normalize_persisted_ce_status(status)
  params.put_int(PERSISTED_CE_STATUS_PARAM, normalized)
  return normalized


def clear_persisted_ce_status(params: Params) -> None:
  params.put_int(PERSISTED_CE_STATUS_PARAM, CEStatus["OFF"])


def sync_persist_experimental_state(params: Params, params_memory: Params | None, enabled: bool) -> None:
  params.put_bool(PERSIST_EXPERIMENTAL_STATE_PARAM, enabled)
  if enabled:
    current_status = params_memory.get_int(CE_STATUS_PARAM, default=CEStatus["OFF"]) if params_memory is not None else CEStatus["OFF"]
    set_persisted_ce_status(params, current_status)
  else:
    clear_persisted_ce_status(params)


def sync_manual_ce_state(params: Params, status: int) -> int:
  return set_persisted_ce_status(params, status) if params.get_bool(PERSIST_EXPERIMENTAL_STATE_PARAM) else clear_and_return_off(params)


def clear_and_return_off(params: Params) -> int:
  clear_persisted_ce_status(params)
  return CEStatus["OFF"]


def next_manual_ce_status(current_status: int, experimental_mode: bool) -> int:
  if is_manual_ce_status(current_status):
    return CEStatus["OFF"]
  return CEStatus["USER_DISABLED"] if experimental_mode else CEStatus["USER_OVERRIDDEN"]


def requested_experimental_mode(params: Params, params_memory: Params | None = None) -> bool:
  if params.get_bool("SafeMode"):
    return False

  if params.get_bool("ConditionalExperimental"):
    status = params_memory.get_int(CE_STATUS_PARAM, default=CEStatus["OFF"]) if params_memory is not None else CEStatus["OFF"]
    if not is_manual_ce_status(status):
      status = get_persisted_ce_status(params)
    return status == CEStatus["USER_OVERRIDDEN"]

  return params.get_bool("ExperimentalMode")


def restore_persisted_ce_state(params: Params, params_memory: Params) -> int:
  current_status = params_memory.get_int(CE_STATUS_PARAM, default=CEStatus["OFF"])
  if is_manual_ce_status(current_status):
    sync_manual_ce_state(params, current_status)
    return current_status

  if not params.get_bool(PERSIST_EXPERIMENTAL_STATE_PARAM):
    return current_status

  restored_status = get_persisted_ce_status(params)
  if restored_status != CEStatus["OFF"]:
    params_memory.put_int(CE_STATUS_PARAM, restored_status)
    return restored_status

  return current_status
