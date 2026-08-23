#!/usr/bin/env bash

export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export VECLIB_MAXIMUM_THREADS=1

# On AGNOS, prefer the managed venv runtime (has required Python deps like pyzmq).
if [ -x /usr/local/venv/bin/python3 ]; then
  export PATH="/usr/local/venv/bin:${PATH}"
fi

# models get lower priority than ui
# - ui is ~5ms
# - modeld is 20ms
# - DM is 10ms
# in order to run ui at 60fps (16.67ms), we need to allow
# it to preempt the model workloads. we have enough
# headroom for this until ui is moved to the CPU.
export QCOM_PRIORITY=12

# Prefer the OS already on this comma so fork installs do not force the AGNOS updater on boot.
if [ -z "$AGNOS_VERSION" ]; then
  if [ -r /VERSION ]; then
    export AGNOS_VERSION="$(tr -d '\n\r' < /VERSION)"
  else
    export AGNOS_VERSION="19.6.20"
  fi
fi

if [ -z "$AGNOS_ACCEPTED_VERSIONS" ]; then
  export AGNOS_ACCEPTED_VERSIONS="$AGNOS_VERSION"
fi

export STAGING_ROOT="/data/safe_staging"

# Vendor capnp for StarPilot native binaries (pandad/camerad) on stock AGNOS.
# StarPilot ships binaries linked against libcapnp-1.0.2 / libkj-1.0.2; stock
# AGNOS 17.x often only has pycapnp static archives. Device harden builds shared
# libs into third_party/capnp_lib. Without this path, UI sticks on "system booting".
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
_CAPNP_LIB=""
if [ -n "$_DIR" ] && [ -d "$_DIR/third_party/capnp_lib" ]; then
  _CAPNP_LIB="$_DIR/third_party/capnp_lib"
elif [ -d /data/openpilot/third_party/capnp_lib ]; then
  _CAPNP_LIB="/data/openpilot/third_party/capnp_lib"
fi
if [ -n "$_CAPNP_LIB" ]; then
  export LD_LIBRARY_PATH="${_CAPNP_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
unset _DIR _CAPNP_LIB

# Allow native pandad to run when panda FW signature differs slightly after
# device harden / mixed prebuilts (Python flash path still enforces FW).
export BOARDD_SKIP_FW_CHECK=1

# StarPilot variables (only available after StarPilot is installed to /data/openpilot)
if [ -x /data/openpilot/starpilot/system/environment_variables ]; then
  eval "$(/data/openpilot/starpilot/system/environment_variables)"
fi
