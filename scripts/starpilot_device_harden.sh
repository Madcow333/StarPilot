#!/usr/bin/env bash
# StarPilot post-install harden for stock AGNOS (esp. 17.x / comma mici).
#
# Fixes that otherwise show up as:
#   - UI "system booting" (native pandad/camerad cannot load libcapnp-1.0.2)
#   - UI "start the car to use openpilot" with ignition on (stale msgq / no deviceState)
#   - "Speed Error: nan" / posenet invalid (camerad not executable → no modelV2)
#
# Safe to re-run. Expects openpilot tree at DEVICE_PATH (default /data/openpilot).
set -euo pipefail

DEVICE_PATH="${DEVICE_PATH:-/data/openpilot}"
CAP_PKG="${CAP_PKG:-/usr/local/venv/lib/python3.12/site-packages/capnproto/install}"
CAPNP_OUT="${DEVICE_PATH}/third_party/capnp_lib"
CLEAR_MSGQ="${CLEAR_MSGQ:-1}"
SKIP_CAPNP_BUILD="${SKIP_CAPNP_BUILD:-0}"

log() { echo "[starpilot-harden] $*"; }

if [ ! -d "$DEVICE_PATH" ]; then
  echo "ERROR: DEVICE_PATH not found: $DEVICE_PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) prebuilt marker — skip on-device scons (missing headers on stock AGNOS)
# ---------------------------------------------------------------------------
if [ ! -f "${DEVICE_PATH}/prebuilt" ]; then
  echo 1 > "${DEVICE_PATH}/prebuilt"
  log "created prebuilt marker"
else
  log "prebuilt marker present"
fi

# ---------------------------------------------------------------------------
# 2) executable bits (Windows/git deploys often drop +x)
# ---------------------------------------------------------------------------
BINS=(
  launch_openpilot.sh
  launch_chffrplus.sh
  launch_env.sh
  system/manager/manager.py
  system/manager/build.py
  system/camerad/camerad
  selfdrive/pandad/pandad
  system/loggerd/loggerd
  system/loggerd/encoderd
  starpilot/navigation/mapd
  starpilot/system/environment_variables
)
for rel in "${BINS[@]}"; do
  f="${DEVICE_PATH}/${rel}"
  if [ -f "$f" ]; then
    chmod a+x "$f" || true
  fi
done
log "chmod +x native launch/binaries"

# ---------------------------------------------------------------------------
# 3) launch_env: LD_LIBRARY_PATH + BOARDD_SKIP_FW_CHECK (idempotent)
# ---------------------------------------------------------------------------
LAUNCH_ENV="${DEVICE_PATH}/launch_env.sh"
if [ -f "$LAUNCH_ENV" ]; then
  if ! grep -q 'third_party/capnp_lib' "$LAUNCH_ENV" 2>/dev/null; then
    cat >> "$LAUNCH_ENV" << 'EOF'

# --- starpilot-harden: stock AGNOS native binary libs ---
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
export BOARDD_SKIP_FW_CHECK=1
# --- end starpilot-harden ---
EOF
    log "appended capnp LD_LIBRARY_PATH block to launch_env.sh"
  else
    log "launch_env.sh already references capnp_lib"
  fi
  if ! grep -q 'BOARDD_SKIP_FW_CHECK' "$LAUNCH_ENV" 2>/dev/null; then
    echo 'export BOARDD_SKIP_FW_CHECK=1' >> "$LAUNCH_ENV"
    log "appended BOARDD_SKIP_FW_CHECK to launch_env.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 4) AGNOS version pin (avoid updater gate on boot)
# ---------------------------------------------------------------------------
if [ -r /VERSION ] && [ -f "$LAUNCH_ENV" ]; then
  device_agnos="$(tr -d '\n\r' < /VERSION)"
  if grep -q 'export AGNOS_VERSION=' "$LAUNCH_ENV"; then
    sed -i "s/export AGNOS_VERSION=\"[^\"]*\"/export AGNOS_VERSION=\"${device_agnos}\"/" "$LAUNCH_ENV" || true
  fi
  if grep -q 'export AGNOS_ACCEPTED_VERSIONS=' "$LAUNCH_ENV"; then
    sed -i "s/export AGNOS_ACCEPTED_VERSIONS=\"[^\"]*\"/export AGNOS_ACCEPTED_VERSIONS=\"${device_agnos}\"/" "$LAUNCH_ENV" || true
  fi
  log "AGNOS pin: $device_agnos"
fi

# ---------------------------------------------------------------------------
# 5) Build libcapnp-1.0.2.so / libkj-1.0.2.so from pycapnp static archives
# ---------------------------------------------------------------------------
need_capnp=1
if [ "$SKIP_CAPNP_BUILD" = "1" ]; then
  need_capnp=0
elif [ -f "${CAPNP_OUT}/libcapnp-1.0.2.so" ] && [ -f "${CAPNP_OUT}/libkj-1.0.2.so" ]; then
  export LD_LIBRARY_PATH="${CAPNP_OUT}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  if ldd "${DEVICE_PATH}/selfdrive/pandad/pandad" 2>/dev/null | grep -q 'libcapnp-1.0.2.so => /'; then
    # quick load test — undefined symbols print immediately then exit
    load_out="$(timeout 2 env LD_LIBRARY_PATH="${CAPNP_OUT}" "${DEVICE_PATH}/selfdrive/pandad/pandad" 2>&1 || true)"
    if echo "$load_out" | grep -q 'symbol lookup error\|cannot open shared object'; then
      need_capnp=1
      log "existing capnp libs fail load; rebuilding"
    else
      need_capnp=0
      log "capnp libs already resolve for pandad"
    fi
  fi
fi

if [ "$need_capnp" = "1" ]; then
  if [ ! -f "${CAP_PKG}/lib/libcapnp.a" ] || [ ! -f "${CAP_PKG}/lib/libkj.a" ]; then
    log "WARNING: ${CAP_PKG}/lib missing static archives — cannot build shared capnp"
  elif ! command -v g++ >/dev/null 2>&1; then
    log "WARNING: g++ not found — cannot build shared capnp"
  else
    log "building capnp shared libs into ${CAPNP_OUT}"
    mkdir -p "$CAPNP_OUT"
    cd "$CAPNP_OUT"

    cat > typeinfo_stubs.cc << 'EOF'
namespace kj {
struct ReadableFile { virtual ~ReadableFile(); };
ReadableFile::~ReadableFile() {}
struct File : ReadableFile { virtual ~File(); };
File::~File() {}
struct Directory { virtual ~Directory(); };
Directory::~Directory() {}
}
EOF

    cat > tryTransferTo_stub.cc << 'EOF'
namespace kj {
class PathPtr { char _pad; };
enum class WriteMode : unsigned char {};
enum class TransferMode : unsigned char {};
class Directory {
public:
  bool tryTransferTo(Directory const&, PathPtr, WriteMode, PathPtr, TransferMode) const;
};
bool Directory::tryTransferTo(Directory const&, PathPtr, WriteMode, PathPtr, TransferMode) const {
  return false;
}
}
EOF

    python3 - << 'PY'
syms = [
  "_ZN2kj15newInMemoryFileERKNS_5ClockE",
  "_ZN2kj20newInMemoryDirectoryERKNS_5ClockE",
  "_ZN2kj4Path5parseENS_9StringPtrE",
  "_ZN2kj4PathC1ENS_9StringPtrE",
  "_ZN2kj4PathC2ENS_9StringPtrE",
  "_ZNK2kj4File4copyEmRKNS_12ReadableFileEmm",
  "_ZNK2kj7PathPtr6parentEv",
  "_ZNK2kj7PathPtr8basenameEv",
  "_ZNK2kj7PathPtr8toStringEb",
  "_ZNK2kj9Directory11tryTransferENS_7PathPtrENS_9WriteModeERKS0_S1_NS_12TransferModeE",
]
lines = [
  ".section .text",
  ".macro ABORT_STUB name",
  "  .global \\name",
  "  .type \\name, %function",
  "\\name:",
  "  brk #1",
  "  .size \\name, .-\\name",
  ".endm",
]
for s in syms:
  lines.append(f"ABORT_STUB {s}")
open("asm_stubs.S", "w").write("\n".join(lines) + "\n")
PY

    g++ -c -fPIC -O2 typeinfo_stubs.cc -o typeinfo_stubs.o
    g++ -c -fPIC -O2 tryTransferTo_stub.cc -o tryTransferTo_stub.o
    as -o asm_stubs.o asm_stubs.S

    g++ -shared -fPIC -Wl,-soname,libkj-1.0.2.so -o libkj-1.0.2.so \
      -Wl,--whole-archive "${CAP_PKG}/lib/libkj.a" -Wl,--no-whole-archive \
      typeinfo_stubs.o tryTransferTo_stub.o asm_stubs.o -lpthread

    g++ -shared -fPIC -Wl,-soname,libcapnp-1.0.2.so -o libcapnp-1.0.2.so \
      -Wl,--whole-archive "${CAP_PKG}/lib/libcapnp.a" -Wl,--no-whole-archive \
      -L. -lkj-1.0.2 -lpthread -Wl,-rpath,"${CAPNP_OUT}"

    ln -sfn libkj-1.0.2.so libkj.so
    ln -sfn libcapnp-1.0.2.so libcapnp.so
    chmod 755 libkj-1.0.2.so libcapnp-1.0.2.so
    chown -R comma:comma "$CAPNP_OUT" 2>/dev/null || true
    log "capnp shared libs built"
  fi
fi

export LD_LIBRARY_PATH="${CAPNP_OUT}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---------------------------------------------------------------------------
# 6) pandad.py: skip SPI reset hang + always BOARDD_SKIP_FW_CHECK + pass env
# ---------------------------------------------------------------------------
PANDAD_PY="${DEVICE_PATH}/selfdrive/pandad/pandad.py"
if [ -f "$PANDAD_PY" ]; then
  python3 - "$PANDAD_PY" << 'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
text = p.read_text()
orig = text

# Skip first_run panda.reset
text2, n = re.subn(
    r"if first_run:\n"
    r"([ \t]+)# reset panda to ensure we.re in a good state\n"
    r"([ \t]+)cloudlog\.info\(f\"Resetting panda \{panda\.get_usb_serial\(\)\}\"\)\n"
    r"([ \t]+)panda\.reset\(reconnect=True\)\n",
    "if first_run:\n"
    r"\1# Skip SPI reset on first run (mici can hang -> UI system booting)\n"
    r"\2cloudlog.info(f\"Skipping panda reset on first run {panda.get_usb_serial()} (mici/SPI stability)\")\n",
    text,
    count=1,
)
if n:
    text = text2
    print("patched: skip first_run panda.reset")
elif "Skipping panda reset on first run" in text:
    print("already: skip first_run panda.reset")
else:
    print("warn: first_run reset pattern not found")

# Always BOARDD_SKIP_FW_CHECK + pass env to native pandad
old = '''    if get_remote_start_boots_comma(params) or get_hkg_remote_start_boots_comma(params) or get_ignore_ignition_line(params):
      os.environ["BOARDD_SKIP_FW_CHECK"] = "1"
    else:
      os.environ.pop("BOARDD_SKIP_FW_CHECK", None)
    os.environ['MANAGER_DAEMON'] = 'pandad'
    process = subprocess.Popen(["./pandad", *panda_serials], cwd=os.path.join(BASEDIR, "selfdrive/pandad"))'''
new = '''    os.environ["BOARDD_SKIP_FW_CHECK"] = "1"
    os.environ['MANAGER_DAEMON'] = 'pandad'
    process = subprocess.Popen(
      ["./pandad", *panda_serials],
      cwd=os.path.join(BASEDIR, "selfdrive/pandad"),
      env=os.environ.copy(),
    )'''
if old in text:
    text = text.replace(old, new, 1)
    print("patched: BOARDD_SKIP_FW_CHECK + Popen env")
elif 'env=os.environ.copy()' in text and 'BOARDD_SKIP_FW_CHECK"] = "1"' in text:
    print("already: BOARDD_SKIP_FW_CHECK + Popen env")
else:
    print("warn: Popen/BOARDD pattern not found (may already be source-patched)")

if text != orig:
    p.write_text(text)
    print("wrote", p)
else:
    print("pandad.py unchanged")
PY
  log "pandad.py harden applied"
fi

# ---------------------------------------------------------------------------
# 7) launch_chffrplus: skip prebuilt_runtime_compatible if still present
# ---------------------------------------------------------------------------
LAUNCH_CHFFR="${DEVICE_PATH}/launch_chffrplus.sh"
if [ -f "$LAUNCH_CHFFR" ] && grep -q 'prebuilt_runtime_compatible' "$LAUNCH_CHFFR"; then
  if ! grep -q 'if false && .*prebuilt_runtime_compatible' "$LAUNCH_CHFFR"; then
    sed -i 's/if \[ "\$USE_PREBUILT" = "1" \] && \[ -f \$DIR\/prebuilt \] && ! prebuilt_runtime_compatible; then/if false \&\& [ "$USE_PREBUILT" = "1" ] \&\& [ -f $DIR\/prebuilt ] \&\& ! prebuilt_runtime_compatible; then/' "$LAUNCH_CHFFR" || true
    log "disabled prebuilt_runtime_compatible gate in launch_chffrplus.sh"
  else
    log "prebuilt_runtime_compatible already disabled"
  fi
fi

# ---------------------------------------------------------------------------
# 8) Clear stale msgq (schema/binary swaps leave unreadable queues)
# ---------------------------------------------------------------------------
if [ "$CLEAR_MSGQ" = "1" ]; then
  # only safe when openpilot is stopped; caller should stop first when possible
  n=$(ls /dev/shm/msgq_* 2>/dev/null | wc -l || echo 0)
  rm -f /dev/shm/msgq_* 2>/dev/null || true
  log "cleared msgq segments (had ${n})"
fi

# ---------------------------------------------------------------------------
# 9) ownership
# ---------------------------------------------------------------------------
chown -R comma:comma "$DEVICE_PATH" 2>/dev/null || true
chmod +x "${DEVICE_PATH}/launch_openpilot.sh" "${DEVICE_PATH}/launch_chffrplus.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10) quick verification
# ---------------------------------------------------------------------------
export LD_LIBRARY_PATH="${CAPNP_OUT}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ -x "${DEVICE_PATH}/selfdrive/pandad/pandad" ]; then
  if ldd "${DEVICE_PATH}/selfdrive/pandad/pandad" 2>&1 | grep -q 'not found'; then
    log "WARNING: pandad still has unresolved deps:"
    ldd "${DEVICE_PATH}/selfdrive/pandad/pandad" 2>&1 | grep 'not found' || true
  else
    log "pandad dynamic deps OK"
  fi
fi
if [ -x "${DEVICE_PATH}/system/camerad/camerad" ]; then
  if ldd "${DEVICE_PATH}/system/camerad/camerad" 2>&1 | grep -q 'libcapnp.*not found'; then
    log "WARNING: camerad still missing capnp"
  else
    log "camerad dynamic deps OK (or static)"
  fi
else
  log "WARNING: camerad missing or not executable"
fi

log "done"
