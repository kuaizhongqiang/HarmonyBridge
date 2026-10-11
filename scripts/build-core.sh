#!/usr/bin/env bash
#
# build-core.sh - cross-compile the Go proxy core (libcore.so) for OHOS arm64.
#
# This is the PROVEN recipe (validated against a shipping HarmonyOS Xray
# client): Xray-core compiled with Go as a C shared library targeting
# aarch64-linux-ohos, then copied to entry/libs/arm64-v8a/.
#
# The one non-obvious decision is explained here because it looks like a bug:
#
#   GOOS=android, not GOOS=ohos.
#
# Go has no `ohos` target. Its `android/arm64` port is the closest non-glibc
# port, and it works against OHOS's musl libc. The consequences are documented
# in entry/src/main/golang/README.md ("交叉编译的坑"); the important one is that
# proxy/tun compiles its *android* backend, not its linux one.
#
# Usage:
#   scripts/build-core.sh [path-to-OHOS-NDK] [--clean]
#
# OHOS_NDK_HOME resolution order:
#   1. first positional argument
#   2. $OHOS_NDK_HOME
#   3. a few well-known DevEco Studio locations
#
# Exits non-zero with an actionable message when the NDK or Go is missing.
# Never commits anything: libcore.so is a gitignored build artifact.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the repository
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GO_DIR="${REPO_ROOT}/entry/src/main/golang"
OUT_DIR="${REPO_ROOT}/entry/libs/arm64-v8a"
OUT_SO="${OUT_DIR}/libcore.so"

CLEAN=0
NDK_ARG=""
for arg in "$@"; do
  case "${arg}" in
    --clean) CLEAN=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) NDK_ARG="${arg}" ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Resolve OHOS_NDK_HOME and verify the toolchain
# ---------------------------------------------------------------------------
resolve_ndk() {
  local candidates=()
  [ -n "${NDK_ARG}" ] && candidates+=("${NDK_ARG}")
  [ -n "${OHOS_NDK_HOME:-}" ] && candidates+=("${OHOS_NDK_HOME}")
  # DevEco Studio default install locations on each platform.
  candidates+=(
    "${HOME}/Library/Huawei/Sdk/default/openharmony/native"
    "${HOME}/OpenHarmony/Sdk/default/openharmony/native"
    "/opt/ohos-sdk/default/openharmony/native"
    "/usr/local/ohos-sdk/default/openharmony/native"
  )

  for candidate in "${candidates[@]}"; do
    if [ -x "${candidate}/llvm/bin/clang" ]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

OHOS_NDK_HOME="$(resolve_ndk || true)"
[ -n "${OHOS_NDK_HOME}" ] || die "OHOS NDK not found.
Looked in:
  \$1, \$OHOS_NDK_HOME, and the usual DevEco Studio SDK paths.
Pass it explicitly, e.g.:
  scripts/build-core.sh /path/to/sdk/default/openharmony/native
Expected to find <NDK>/llvm/bin/clang."

# Accept either the sdk root (.../openharmony) or the native dir itself.
if [ ! -x "${OHOS_NDK_HOME}/llvm/bin/clang" ] && [ -x "${OHOS_NDK_HOME}/native/llvm/bin/clang" ]; then
  OHOS_NDK_HOME="${OHOS_NDK_HOME}/native"
fi

TOOLBIN="${OHOS_NDK_HOME}/llvm/bin"
SYSROOT="${OHOS_NDK_HOME}/sysroot"

info "NDK:      ${OHOS_NDK_HOME}"
info "sysroot:  ${SYSROOT}"
info "Go dir:   ${GO_DIR}"
info "output:   ${OUT_SO}"

# A space in the NDK path breaks cgo's CC handling. This is mainly a Windows
# problem, but a spaced *nix path would break the unquoted $CFLAGS expansion
# below in exactly the same way, so warn loudly here too.
case "${OHOS_NDK_HOME}" in
  *" "*)
    echo "warning: the NDK path contains a space; cgo's CC/CFLAGS handling will break." >&2
    echo "         Move the SDK to a space-free path (e.g. /opt/ohos-sdk) before building." >&2
    ;;
esac

for tool in clang clang++ llvm-ar ld.lld llvm-strip llvm-config; do
  [ -x "${TOOLBIN}/${tool}" ] || die "missing required tool: ${TOOLBIN}/${tool}
The OHOS NDK layout may have changed; inspect ${TOOLBIN} and adjust this script."
done
[ -d "${SYSROOT}" ] || die "missing sysroot: ${SYSROOT}"
[ -d "${GO_DIR}" ] || die "missing Go source directory: ${GO_DIR}"

command -v go >/dev/null 2>&1 || die "'go' is not on PATH. Install Go 1.26+ (xray-core requires it)."

info "Go:       $(go version)"

# ---------------------------------------------------------------------------
# Cross-compile environment (the proven recipe)
# ---------------------------------------------------------------------------
export CC="${TOOLBIN}/clang"
export CXX="${TOOLBIN}/clang++"
export AR="${TOOLBIN}/llvm-ar"
export AS="${TOOLBIN}/llvm-as"
export LD="${TOOLBIN}/ld.lld"
export STRIP="${TOOLBIN}/llvm-strip"
export RANLIB="${TOOLBIN}/llvm-ranlib"
export OBJDUMP="${TOOLBIN}/llvm-objdump"
export OBJCOPY="${TOOLBIN}/llvm-objcopy"
export NM="${TOOLBIN}/llvm-nm"
export LLVMCONFIG="${TOOLBIN}/llvm-config"

# -D__MUSL__ is load-bearing: OHOS's libc is musl and some dependencies switch
# implementations on it. Omitting it yields runtime crashes, not build errors.
export CFLAGS="-target aarch64-linux-ohos --sysroot=${SYSROOT} -D__MUSL__"
export CXXFLAGS="${CFLAGS}"

export CGO_ENABLED=1
export GOOS=android
export GOARCH=arm64

export CGO_CFLAGS="-g -O2 $("${LLVMCONFIG}" --cflags) --target=aarch64-linux-ohos --sysroot=${SYSROOT}"
# The three OHOS NDK libs are required by Go's android runtime port.
export CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"

# -mod=mod so a missing go.sum entry is repaired instead of failing the build.
export GOFLAGS="-mod=mod"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
cd "${GO_DIR}"

if [ ! -f go.sum ]; then
  info "go.sum missing; running 'go mod tidy' to populate the module graph"
  go mod tidy
fi

[ "${CLEAN}" -eq 1 ] && { info "cleaning previous libcore.so/.h"; rm -f libcore.so libcore.h; }

mkdir -p "${OUT_DIR}"

info "go build -buildmode=c-shared ..."
go build \
  -tags "fts5 timetzdata" \
  -ldflags "-s -w" \
  -buildmode=c-shared \
  -v \
  -o libcore.so \
  .

# libcore.h is the cgo-generated header. Nothing includes it (the NAPI shim
# declares the two symbols itself), so it is build noise.
rm -f libcore.h

[ -f libcore.so ] || die "go build reported success but libcore.so is missing"

cp -f libcore.so "${OUT_SO}"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if command -v file >/dev/null 2>&1; then
  info "artifact: $(file -b "${OUT_SO}" || true)"
fi
info "size:     $(du -h "${OUT_SO}" | cut -f1)"
info "done:     ${OUT_SO}"
echo
echo "Reminder: libcore.so is gitignored on purpose. Do not commit it."
