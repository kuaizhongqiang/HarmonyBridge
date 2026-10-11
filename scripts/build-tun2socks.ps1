<#
.SYNOPSIS
    Cross-compile hev-socks5-tunnel (the tun2socks data plane) for OHOS arm64.

.DESCRIPTION
    Produces entry/libs/arm64-v8a/libhevsocks5tun.so, which libbridge.so loads at
    runtime with dlopen (entry/src/main/cpp/tun2socks_bridge.cpp). It sits next to
    libcore.so in the same folder, so the sibling lookup finds it.

    WHY hev
    =======
    heiher/hev-socks5-tunnel is a pure-C, MIT-licensed tun2socks:
      * pure C -> needs no Go toolchain fork, so it sidesteps the whole B2
                  question (Go has no GOOS=ohos target; the header of
                  scripts/build-core.ps1 documents what that costs today);
      * MIT    -> the repository stays MIT + Xray-core (MPL-2.0). A GPL-licensed
                  tun2socks would have broken that boundary
                  (docs/00-技术路线可行性.md §9 step 3).
    The data path is: TUN fd -> tun2socks -> 127.0.0.1:SOCKS -> libcore.so
    (frozen contract: docs/design/ipc-contract.md §2).

    HONEST STATUS - READ THIS
    =========================
    THIS RECIPE HAS NEVER BEEN RUN. It is assembled from upstream's Makefile and
    the local OHOS NDK layout, not from a successful build. Known open points:

      1. upstream's source list comes from build.mk (`-include build.mk`).
         Whether that file ships in the repo or is generated is NOT confirmed
         here. If the build reports "no input files", this is why.
      2. the build recurses into third-part/{yaml,lwip,hev-task-system}.
         Whether lwip cross-compiles for OHOS musl is unknown.
      3. upstream's CCFLAGS contains -Werror, which turns cross-compile warnings
         into hard failures. -Wno-error is appended to defuse that.
      4. this machine's NDK path contains a space; make and cgo both dislike
         that. The script warns instead of pretending.

    Expect a failure the first time. Report what breaks rather than working
    around it silently - that report is the deliverable.

    The upstream target is `shared` and the artifact is bin/libhev-socks5-tunnel.so.
    It is renamed on copy to libhevsocks5tun.so so it matches kLibName in
    tun2socks_bridge.cpp (the reference HarmonyOS client uses the same name).

.PARAMETER NdkHome
    Path to the OHOS NDK. Defaults to $env:OHOS_NDK_HOME, then to the DevEco
    Studio install location on this machine.

.PARAMETER SourceDir
    Where the upstream checkout lives. Defaults to
    $env:LOCALAPPDATA\harmonybridge-deps\hev-socks5-tunnel.

    It is deliberately OUTSIDE the repository: the project is MIT and must not
    vendor third-party sources into the tree (AGENT.md §6).

.PARAMETER Revision
    Git revision / tag to check out. Defaults to master.

.PARAMETER SkipClone
    Assume SourceDir is already populated (useful when iterating on the recipe).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-tun2socks.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build-tun2socks.ps1 -SkipClone
#>
[CmdletBinding()]
param(
    [string]$NdkHome = "",
    [string]$SourceDir = "",
    [string]$Revision = "master",
    [switch]$SkipClone
)

$ErrorActionPreference = 'Stop'

$UpstreamUrl = 'https://github.com/heiher/hev-socks5-tunnel'
# Upstream builds bin/libhev-socks5-tunnel.so; libbridge dlopen()s this name.
$ArtifactName = 'libhevsocks5tun.so'

# ---------------------------------------------------------------------------
# Locate the repository and the output directory
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
$OutDir    = Join-Path $RepoRoot 'entry\libs\arm64-v8a'
$OutSo     = Join-Path $OutDir $ArtifactName

function Write-Info($msg) { Write-Host "==> $msg" }
function Die($msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

if (-not $SourceDir) {
    $SourceDir = Join-Path $env:LOCALAPPDATA 'harmonybridge-deps\hev-socks5-tunnel'
}

# ---------------------------------------------------------------------------
# Resolve the NDK (same candidate list as build-core.ps1)
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
  powershell -File scripts\build-tun2socks.ps1 -NdkHome "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"
"@
}

$ToolBin = Join-Path $NdkHome 'llvm\bin'
$Sysroot = Join-Path $NdkHome 'sysroot'
$Clang   = Join-Path $ToolBin 'clang.exe'
$Ar      = Join-Path $ToolBin 'llvm-ar.exe'
$Strip   = Join-Path $ToolBin 'llvm-strip.exe'
$ReadElf = Join-Path $ToolBin 'llvm-readelf.exe'

foreach ($tool in @($Clang, $Ar, $Strip)) {
    if (-not (Test-Path $tool)) { Die "missing required tool: $tool" }
}
if (-not (Test-Path $Sysroot)) { Die "missing sysroot: $Sysroot" }

Write-Info "NDK:       $NdkHome"
Write-Info "sysroot:   $Sysroot"
Write-Info "source:    $SourceDir"
Write-Info "output:    $OutSo"

if ($NdkHome -match ' ') {
    Write-Host ""
    Write-Host "WARNING: the NDK path contains a space." -ForegroundColor Yellow
    Write-Host "  make and the upstream sub-makes may mangle paths with spaces." -ForegroundColor Yellow
    Write-Host "  Workaround (same as build-core.ps1): create a space-free junction" -ForegroundColor Yellow
    Write-Host "    cmd /c mklink /J `"$env:LOCALAPPDATA\ohos-ndk-nospace`" `"$NdkHome`"" -ForegroundColor Gray
    Write-Host "    ... -NdkHome `"$env:LOCALAPPDATA\ohos-ndk-nospace`"" -ForegroundColor Gray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Fetch the upstream source (outside the repository on purpose)
# ---------------------------------------------------------------------------
if (-not $SkipClone) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "'git' is not on PATH; cannot fetch $UpstreamUrl"
    }
    if (Test-Path (Join-Path $SourceDir '.git')) {
        Write-Info "updating existing checkout"
        Push-Location $SourceDir
        try {
            git fetch --all --recurse-submodules
            if ($LASTEXITCODE -ne 0) { Die "git fetch failed (exit $LASTEXITCODE)" }
            git checkout $Revision
            if ($LASTEXITCODE -ne 0) { Die "git checkout $Revision failed (exit $LASTEXITCODE)" }
            git submodule update --init --recursive
            if ($LASTEXITCODE -ne 0) { Die "git submodule update failed (exit $LASTEXITCODE)" }
        } finally {
            Pop-Location
        }
    } else {
        Write-Info "cloning $UpstreamUrl (with submodules)"
        $parent = Split-Path -Parent $SourceDir
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        git clone --recursive --branch $Revision $UpstreamUrl $SourceDir
        if ($LASTEXITCODE -ne 0) { Die "git clone failed (exit $LASTEXITCODE)" }
    }
}

if (-not (Test-Path (Join-Path $SourceDir 'Makefile'))) {
    Die "no Makefile under $SourceDir - is this the hev-socks5-tunnel checkout?"
}

# ---------------------------------------------------------------------------
# Cross-compile
#
# The upstream Makefile defines CC as `$(CROSS_PREFIX)gcc`, a recursively
# expanded variable, so a command-line CC= override wins. That is how the OHOS
# clang is injected without a CROSS_PREFIX that upstream would understand.
# ---------------------------------------------------------------------------
$CFlags = @(
    '--target=aarch64-linux-ohos'
    "--sysroot=$Sysroot"
    '-D__MUSL__'
    '-O2'
    '-fPIC'
    # Upstream's CCFLAGS already carries -Werror; a later -Wno-error defuses it.
    '-Wno-error'
) -join ' '

$LFlags = @(
    '--target=aarch64-linux-ohos'
    "-fuse-ld=lld"
    "--sysroot=$Sysroot"
) -join ' '

$makeArgs = @(
    'shared'
    "CC=$Clang"
    "AR=$Ar"
    "STRIP=$Strip"
    "CFLAGS=$CFlags"
    "LFLAGS=$LFlags"
)

Write-Info "make $($makeArgs -join ' ')"
Push-Location $SourceDir
try {
    & make @makeArgs 2>&1 | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
    $makeCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($makeCode -ne 0) {
    Write-Host ""
    Write-Host "make failed with exit code $makeCode." -ForegroundColor Red
    Write-Host "This is EXPECTED on the first attempt - see HONEST STATUS in this script's header." -ForegroundColor Yellow
    Write-Host "Most likely causes, in order:" -ForegroundColor Yellow
    Write-Host "  1. build.mk is missing, so SRCFILES is empty ('no input files')." -ForegroundColor Yellow
    Write-Host "  2. third-part/lwip does not cross-compile for OHOS musl." -ForegroundColor Yellow
    Write-Host "  3. the space in the NDK path." -ForegroundColor Yellow
    Write-Host "Please report which one it is; do not paper over it." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Install into the repository's native library folder
# ---------------------------------------------------------------------------
$builtSo = Join-Path $SourceDir 'bin\libhev-socks5-tunnel.so'
if (-not (Test-Path $builtSo)) { Die "make succeeded but $builtSo is missing" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item -Force $builtSo $OutSo

$sizeMb = [math]::Round((Get-Item $OutSo).Length / 1MB, 2)
Write-Info "size:      $sizeMb MB"
Write-Info "done:      $OutSo"

# Confirm the architecture rather than assuming it.
if (Test-Path $ReadElf) {
    $machine = (& $ReadElf -h $OutSo 2>&1 | Select-String -Pattern 'Machine|Class' | ForEach-Object { $_.Line.Trim() }) -join '; '
    Write-Info "arch:      $machine"
}

# Confirm the three symbols libbridge resolves are actually exported.
$nm = Join-Path $ToolBin 'llvm-nm.exe'
if (Test-Path $nm) {
    $syms = (& $nm -D --defined-only $OutSo 2>&1 | Select-String -Pattern 'hev_socks5_tunnel' | ForEach-Object { $_.Line.Trim() })
    if ($syms) {
        Write-Info "symbols:"
        $syms | ForEach-Object { Write-Host "             $_" }
    } else {
        Write-Host "WARNING: no hev_socks5_tunnel* symbols found; did the build export them?" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Reminder: .so files are gitignored on purpose. Do not commit them."
