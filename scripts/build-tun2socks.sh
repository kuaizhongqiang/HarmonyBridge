#!/usr/bin/env bash
#
# build-tun2socks.sh - cross-compile hev-socks5-tunnel for OHOS arm64.
#
# Linux / macOS / WSL counterpart of scripts/build-tun2socks.ps1. The supported
# route for this recipe is a Linux host: upstream recurses into
# third-part/{yaml,lwip,hev-task-system}, and a POSIX build environment avoids
# the space-in-path and shell-quoting problems the Windows script warns about.
#
# Produces entry/libs/arm64-v8a/libhevsocks5tun.so, which libbridge.so loads with
# dlopen (entry/src/main/cpp/tun2socks_bridge.cpp), sitting next to libcore.so.
#
# WHY hev: pure C (no Go fork -> sidesteps B2) and MIT (keeps the repository's
# MIT + Xray-core MPL-2.0 boundary). See scripts/build-tun2socks.ps1 for the full
# rationale.
#
# HONEST STATUS: THIS RECIPE HAS NEVER BEEN RUN. It is assembled from upstream's
# Makefile and the OHOS NDK layout. Known open points:
#   1. upstream's source list comes from build.mk (`-include build.mk`); whether
#      it ships in the repo or is generated is not confirmed;
#   2. third-part/lwip may not cross-compile for OHOS musl;
#   3. upstream CCFLAGS carries -Werror; -Wno-error is appended to defuse it.
# Report what breaks instead of working around it silently.
#
# Usage:
#   bash scripts/build-tun2socks.sh /path/to/ohos-ndk/native
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/entry/libs/arm64-v8a"
ARTIFACT_NAME="libhevsocks5tun.so"
UPSTREAM_URL="https://github.com/heiher/hev-socks5-tunnel"

NDK_HOME="${1:-${OHOS_NDK_HOME:-}}"
SOURCE_DIR="${SOURCE_DIR:-${HOME}/.cache/harmonybridge-deps/hev-socks5-tunnel}"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

if [[ -z "${NDK_HOME}" ]]; then
    die "OHOS NDK not found. Pass it as \$1 or set OHOS_NDK_HOME, e.g.
  bash scripts/build-tun2socks.sh /path/to/ohos-ndk/native"
fi

TOOL_BIN="${NDK_HOME}/llvm/bin"
SYSROOT="${NDK_HOME}/sysroot"
CLANG="${TOOL_BIN}/clang"
AR="${TOOL_BIN}/llvm-ar"
STRIP="${TOOL_BIN}/llvm-strip"

for tool in "${CLANG}" "${AR}" "${STRIP}"; do
    [[ -x "${tool}" ]] || die "missing required tool: ${tool}"
done
[[ -d "${SYSROOT}" ]] || die "missing sysroot: ${SYSROOT}"

info "NDK:       ${NDK_HOME}"
info "sysroot:   ${SYSROOT}"
info "source:    ${SOURCE_DIR}"
info "output:    ${OUT_DIR}/${ARTIFACT_NAME}"

# ---------------------------------------------------------------------------
# Fetch upstream (outside the repository: the project is MIT and must not vendor
# third-party sources into the tree - AGENT.md §6).
# ---------------------------------------------------------------------------
if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    command -v git >/dev/null 2>&1 || die "'git' is not installed"
    info "cloning ${UPSTREAM_URL} (with submodules)"
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --recursive "${UPSTREAM_URL}" "${SOURCE_DIR}"
else
    info "reusing existing checkout (delete it to re-clone)"
fi

[[ -f "${SOURCE_DIR}/Makefile" ]] || die "no Makefile under ${SOURCE_DIR}"

# ---------------------------------------------------------------------------
# Cross-compile.
#
# Upstream defines CC as `$(CROSS_PREFIX)gcc` - a recursively expanded variable -
# so a command-line CC= override wins. That is how the OHOS clang gets in without
# a CROSS_PREFIX upstream would understand.
# ---------------------------------------------------------------------------
CFLAGS="--target=aarch64-linux-ohos --sysroot=${SYSROOT} -D__MUSL__ -O2 -fPIC -Wno-error"
LFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld --sysroot=${SYSROOT}"

info "make shared CC=${CLANG} ..."
if ! make -C "${SOURCE_DIR}" shared \
        CC="${CLANG}" AR="${AR}" STRIP="${STRIP}" \
        CFLAGS="${CFLAGS}" LFLAGS="${LFLAGS}"; then
    cat >&2 <<'EOF'

make failed. This is EXPECTED on the first attempt - see HONEST STATUS at the
top of this script. Most likely causes, in order:
  1. build.mk is missing, so SRCFILES is empty ("no input files").
  2. third-part/lwip does not cross-compile for OHOS musl.
Please report which one it is; do not paper over it.
EOF
    exit 1
fi

BUILT_SO="${SOURCE_DIR}/bin/libhev-socks5-tunnel.so"
[[ -f "${BUILT_SO}" ]] || die "make succeeded but ${BUILT_SO} is missing"

mkdir -p "${OUT_DIR}"
cp -f "${BUILT_SO}" "${OUT_DIR}/${ARTIFACT_NAME}"
info "done: ${OUT_DIR}/${ARTIFACT_NAME}"

# Confirm the architecture and the symbols libbridge resolves.
if [[ -x "${TOOL_BIN}/llvm-readelf" ]]; then
    info "arch: $("${TOOL_BIN}/llvm-readelf" -h "${OUT_DIR}/${ARTIFACT_NAME}" | grep -E 'Class|Machine' | tr -d '\r' | paste -sd'; ' -)"
fi
if [[ -x "${TOOL_BIN}/llvm-nm" ]]; then
    info "symbols:"
    "${TOOL_BIN}/llvm-nm" -D --defined-only "${OUT_DIR}/${ARTIFACT_NAME}" \
        | grep hev_socks5_tunnel || echo "  (none found - check the build)"
fi

echo
echo "Reminder: .so files are gitignored on purpose. Do not commit them."
