<#
.SYNOPSIS
    Cross-compile the Go proxy core (libcore.so) for OHOS arm64 on Windows.

.DESCRIPTION
    Windows counterpart of scripts/build-core.sh. Same proven recipe, same
    output location (entry/libs/arm64-v8a/libcore.so).

    WHY GOOS=android
    ================
    Go has no `ohos` target. `GOOS=android GOARCH=arm64` is the closest
    non-glibc port and works against OHOS's musl libc. Consequence: Go compiles
    its android runtime branches, and proxy/tun selects tun_android.go (whose
    build tag is plain `android`) rather than tun_linux.go (tagged
    `linux && !android`). Whether the android tun backend is correct on OHOS is
    UNVERIFIED - see docs/design/core.md.

    HONEST STATUS OF THE WINDOWS-HOST PATH
    ======================================
    Measured on this machine, not assumed. The cross-compile currently FAILS,
    and this script reports precisely where rather than pretending otherwise.
    Three distinct obstacles were isolated, in the order they are hit:

    1. SPACES IN THE NDK PATH (fatal, and silent-looking).
       Go cannot handle a space in CC/CFLAGS on Windows. With
       `CC=D:\Harmony\DevEco Studio\...\clang.exe` the cgo error is
       `C compiler "D:\\Harmony\\DevEco" not found` - Go truncates at the
       space. Quoting CC only moves the failure: `--sysroot` and the
       `llvm-config --cflags` include paths then break instead. 8.3 short
       names are NOT a workaround here (short-name generation is disabled on
       this volume: `%~sI` returns the long name unchanged).
       The only working remedy found was a space-free junction, e.g.
       `mklink /J %LOCALAPPDATA%\ohos-ndk-nospace "<ndk>"`, and pointing the
       toolchain at that. This script refuses to silently create artifacts
       outside the repository; instead it detects the space and says so.

    2. `android/log.h` IS MISSING FROM THE OHOS SYSROOT (fatal by default).
       Go's `runtime/cgo/gcc_android.c` (selected because GOOS=android)
       includes `<android/log.h>` for its fatalf() path. OHOS has no liblog
       and no such header. A two-declaration shim header (__android_log_vprint
       as a no-op + ANDROID_LOG_FATAL) added via `-I` clears this step.

    3. `socklen_t` TYPE MISMATCH IN GO'S OWN net PACKAGE (the real blocker).
       After the shim, the build dies in the standard library:

           C:\Program Files\Go\src\net\cgo_resold.go:20:76:
           cannot use _Ctype_size_t(len(b)) (value of type _Ctype_size_t)
           as _Ctype_socklen_t value in argument to _C2func_getnameinfo

       Cause: OHOS musl declares `typedef unsigned socklen_t;` while Go's
       android port expects Android bionic's socklen_t to be the same width as
       the `size_t` it passes. Fixing it requires patching the Go standard
       library (a cast), not a flag. This is a genuine
       `GOOS=android` vs OHOS-headers incompatibility and it is the reason the
       Windows-host (and any-host) path does not produce libcore.so today.

    A capability probe still runs below, because it cheaply rules out the
    obvious objection and it validates the toolchain before a long build. It
    does NOT imply the full build will succeed; obstacle 3 is not visible to a
    single-file compile.

    The supported route remains a Linux host (or WSL / container) with the
    Linux OHOS NDK, where obstacle 1 disappears and obstacles 2/3 can be
    tackled with a patched-or-shimmed toolchain.

.PARAMETER NdkHome
    Path to the OHOS NDK. Defaults to $env:OHOS_NDK_HOME, then to the DevEco
    Studio install location on this machine.

.PARAMETER Clean
    Delete a previous libcore.so/libcore.h before building.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-core.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-core.ps1 -NdkHome "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"
#>
[CmdletBinding()]
param(
    [string]$NdkHome = "",
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Locate the repository
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
$GoDir     = Join-Path $RepoRoot 'entry\src\main\golang'
$OutDir    = Join-Path $RepoRoot 'entry\libs\arm64-v8a'
$OutSo     = Join-Path $OutDir 'libcore.so'

function Write-Info($msg) { Write-Host "==> $msg" }
function Die($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Resolve the NDK
# ---------------------------------------------------------------------------
function Resolve-Ndk {
    param([string]$Explicit)

    $candidates = @()
    if ($Explicit)          { $candidates += $Explicit }
    if ($env:OHOS_NDK_HOME) { $candidates += $env:OHOS_NDK_HOME }
    $candidates += @(
        'D:\Harmony\DevEco Studio\sdk\default\openharmony\native',
        'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native',
        (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk\default\openharmony\native')
    )

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        # Accept either the native dir or the sdk root containing it.
        $direct = Join-Path $candidate 'llvm\bin\clang.exe'
        if (Test-Path $direct) { return (Resolve-Path $candidate).Path }
        $nested = Join-Path $candidate 'native\llvm\bin\clang.exe'
        if (Test-Path $nested) { return (Resolve-Path (Join-Path $candidate 'native')).Path }
    }
    return $null
}

$NdkHome = Resolve-Ndk -Explicit $NdkHome
if (-not $NdkHome) {
    Die @"
OHOS NDK not found.
Searched: -NdkHome, `$env:OHOS_NDK_HOME, and the default DevEco Studio SDK paths.
Pass it explicitly, e.g.:
  powershell -File scripts\build-core.ps1 -NdkHome "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"
"@
}

$ToolBin = Join-Path $NdkHome 'llvm\bin'
$Sysroot = Join-Path $NdkHome 'sysroot'

Write-Info "NDK:      $NdkHome"
Write-Info "sysroot:  $Sysroot"
Write-Info "Go dir:   $GoDir"
Write-Info "output:   $OutSo"

# ---------------------------------------------------------------------------
# Obstacle 1: a space in the NDK path breaks cgo on Windows (see the header).
# Detect it up front instead of surfacing a confusing truncated-path error.
# ---------------------------------------------------------------------------
if ($NdkHome -match ' ') {
    Write-Host ""
    Write-Host "WARNING: the NDK path contains a space." -ForegroundColor Yellow
    Write-Host "  Go cannot handle a space in CC/CFLAGS on Windows; the build will fail" -ForegroundColor Yellow
    Write-Host "  with a truncated path such as 'C compiler \"D:\\Harmony\\DevEco\" not found'." -ForegroundColor Yellow
    Write-Host "  8.3 short names do not help when short-name generation is disabled." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Workaround: create a space-free junction and pass it as -NdkHome:" -ForegroundColor Yellow
    Write-Host "    cmd /c mklink /J `"$env:LOCALAPPDATA\ohos-ndk-nospace`" `"$NdkHome`"" -ForegroundColor Gray
    Write-Host "    powershell -File scripts\build-core.ps1 -NdkHome `"$env:LOCALAPPDATA\ohos-ndk-nospace`"" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  (This is necessary but NOT sufficient - see obstacle 3 in the script header.)" -ForegroundColor Yellow
    Write-Host ""
}

if (-not (Test-Path $Sysroot)) { Die "missing sysroot: $Sysroot" }
if (-not (Test-Path $GoDir))   { Die "missing Go source directory: $GoDir" }

# ---------------------------------------------------------------------------
# Verify every tool we are about to hand to cgo
# ---------------------------------------------------------------------------
$tools = @{
    # key = env var name, value = file under llvm\bin
    'CC'         = 'clang.exe'
    'CXX'        = 'clang++.exe'
    'AR'         = 'llvm-ar.exe'
    'AS'         = 'llvm-as.exe'
    'LD'         = 'ld.lld.exe'
    'STRIP'      = 'llvm-strip.exe'
    'RANLIB'     = 'llvm-ranlib.exe'
    'OBJDUMP'    = 'llvm-objdump.exe'
    'OBJCOPY'    = 'llvm-objcopy.exe'
    'NM'         = 'llvm-nm.exe'
    'LLVMCONFIG' = 'llvm-config.exe'
}

$missing = @()
foreach ($entry in $tools.GetEnumerator()) {
    $full = Join-Path $ToolBin $entry.Value
    if (Test-Path $full) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $full
    } else {
        $missing += $full
    }
}
if ($missing.Count -gt 0) {
    Die ("missing required tool(s):`n  " + ($missing -join "`n  ") + "`nThe OHOS NDK layout may have changed; inspect $ToolBin.")
}

# ---------------------------------------------------------------------------
# Probe: can this Windows clang actually target aarch64-linux-ohos?
# ---------------------------------------------------------------------------
$clangVersion = (& $env:CC --version 2>&1 | Select-Object -First 1)
Write-Info "clang:    $clangVersion"

# The probe is a one-line compile to /dev/null-equivalent, so we learn about a
# broken toolchain before spending minutes on the real build.
$probeFile = Join-Path $env:TEMP ("ohos-probe-" + [guid]::NewGuid().ToString('N') + ".c")
$probeOut  = Join-Path $env:TEMP ("ohos-probe-" + [guid]::NewGuid().ToString('N') + ".o")
Set-Content -Path $probeFile -Value "int probe(void){return 0;}" -Encoding ascii
$probeArgs = @(
    '-target', 'aarch64-linux-ohos',
    "--sysroot=$Sysroot",
    '-D__MUSL__',
    '-c', $probeFile,
    '-o', $probeOut
)
Write-Info "probe:    $($env:CC) $($probeArgs -join ' ')"
$probeOutput = & $env:CC @probeArgs 2>&1
$probeOk = ($LASTEXITCODE -eq 0) -and (Test-Path $probeOut)
Remove-Item -Force $probeFile, $probeOut -ErrorAction SilentlyContinue

if ($probeOk) {
    Write-Info "probe:    OK - this clang can target aarch64-linux-ohos"
    Write-Info "          (this does NOT guarantee the cgo build succeeds; see obstacle 3)"
} else {
    Write-Host "probe output: $probeOutput" -ForegroundColor Yellow
    Write-Host ""
    Die @"
The Windows Host clang CANNOT target aarch64-linux-ohos.
This is the expected failure mode for the Windows-host path, and it is why
scripts/build-core.sh (Linux / WSL / container) is the supported route.

Workaround: run the shell script inside WSL with the Linux OHOS NDK:
  wsl -- bash scripts/build-core.sh /mnt/d/ohos-sdk/native
"@
}

# ---------------------------------------------------------------------------
# Cross-compile environment (the proven recipe)
# ---------------------------------------------------------------------------
$env:CFLAGS   = "-target aarch64-linux-ohos --sysroot=$Sysroot -D__MUSL__"
$env:CXXFLAGS = $env:CFLAGS

$env:CGO_ENABLED = '1'
$env:GOOS        = 'android'
$env:GOARCH      = 'arm64'

$llvmCflags = (& $env:LLVMCONFIG --cflags 2>&1) -join ' '
$env:CGO_CFLAGS = "-g -O2 $llvmCflags --target=aarch64-linux-ohos --sysroot=$Sysroot"
# The three OHOS NDK libs are required by Go's android runtime port.
$env:CGO_LDFLAGS = "--target=aarch64-linux-ohos -fuse-ld=lld -lohcommonevent -lhilog_ndk.z -ltime_service_ndk"

# -mod=mod so a missing go.sum entry is repaired instead of failing the build.
$env:GOFLAGS = '-mod=mod'

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    Die "'go' is not on PATH. Install Go 1.26+ (xray-core requires it)."
}
Write-Info "Go:       $(go version)"

Push-Location $GoDir
try {
    if (-not (Test-Path 'go.sum')) {
        Write-Info "go.sum missing; running 'go mod tidy' to populate the module graph"
        go mod tidy
        if ($LASTEXITCODE -ne 0) { Die "go mod tidy failed (exit $LASTEXITCODE)" }
    }

    if ($Clean) {
        Write-Info "cleaning previous libcore.so/libcore.h"
        Remove-Item -Force 'libcore.so', 'libcore.h' -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $goArgs = @(
        'build',
        '-tags', 'fts5 timetzdata',
        '-ldflags', '-s -w',
        '-buildmode=c-shared',
        '-o', 'libcore.so',
        '.'
    )
    Write-Info "go $($goArgs -join ' ')"
    $buildOutput = & go @goArgs 2>&1
    $buildCode = $LASTEXITCODE
    # Show the tail: cgo failures print their real cause in the middle.
    $buildOutput | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    if ($buildCode -ne 0) {
        Die "go build failed with exit code $buildCode. See the output above."
    }
} finally {
    Pop-Location
}

$builtSo = Join-Path $GoDir 'libcore.so'
if (-not (Test-Path $builtSo)) { Die "go build reported success but libcore.so is missing" }

# libcore.h is the cgo-generated header; nothing includes it.
Remove-Item -Force (Join-Path $GoDir 'libcore.h') -ErrorAction SilentlyContinue

Copy-Item -Force $builtSo $OutSo

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$sizeMb = [math]::Round((Get-Item $OutSo).Length / 1MB, 1)
Write-Info "size:     $sizeMb MB"
Write-Info "done:     $OutSo"

# Confirm the architecture rather than assuming it.
$readelf = Join-Path $ToolBin 'llvm-readelf.exe'
if (Test-Path $readelf) {
    $machine = (& $readelf -h $OutSo 2>&1 | Select-String -Pattern 'Machine|Class' | ForEach-Object { $_.Line.Trim() }) -join '; '
    Write-Info "arch:     $machine"
}

Write-Host ""
Write-Host "Reminder: libcore.so is gitignored on purpose. Do not commit it."
