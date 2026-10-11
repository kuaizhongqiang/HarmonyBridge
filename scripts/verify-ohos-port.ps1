# verify-ohos-port.ps1 -- build the OHOS Go port from scratch and run the acceptance checks.
#
# WHAT THIS PROVES (and what it does not)
# =======================================
# This script drives the *whole* loop on a Windows host:
#
#   1. bootstrap-build the patched Go tree (make.bat)                 -> a real toolchain
#   2. `go tool dist list` must contain openharmony/arm64            -> target is registered
#   3. build a 10-line -buildmode=c-shared library with the OHOS NDK -> the toolchain works
#   4. llvm-readelf on that library must show PT_TLS and a
#      R_AARCH64_TLSDESC relocation                                  -> the TLS model is right
#
# Step 4 is the decisive one. It is the same criterion docs/06 section 4 and docs/07 P2
# use, and it is the difference between "it links" and "musl/OHOS can actually resolve
# the Go runtime's thread-local storage".
#
# It does NOT prove the artifact runs: there is still no OHOS device in this project
# (see AGENT.md section 1 and TODO.md). Passing this script means the toolchain-level
# acceptance criteria are met, nothing more.
#
# PREREQUISITES
#   - A Go >= 1.26 bootstrap toolchain           (default: $env:GOROOT_BOOTSTRAP)
#   - The OHOS NDK (clang + llvm-readelf)        (default: the DevEco install)
#   - A C compiler for the *host* build is not needed; make.bat uses the bootstrap Go.
#
# USAGE
#   pwsh -File scripts/verify-ohos-port.ps1 `
#       -GoTree  C:\path\to\patched\go `
#       -BootstrapGo C:\path\to\go1.26.x `
#       -Ndk C:\ohndk
#
# -Ndk must be a path WITHOUT SPACES: Go on Windows truncates CC at the first space.
# If your NDK lives under "D:\Harmony\DevEco Studio\...", make a junction first:
#   cmd /c mklink /J C:\ohndk "D:\Harmony\DevEco Studio\sdk\default\openharmony\native"

[CmdletBinding()]
param(
    # Root of the patched Go source tree (the one containing src\, bin\, VERSION).
    [Parameter(Mandatory = $true)][string]$GoTree,

    # A Go toolchain used to bootstrap the build (go1.26.x).
    [Parameter(Mandatory = $true)][string]$BootstrapGo,

    # OHOS NDK root, containing llvm\bin\clang.exe and sysroot\. NO SPACES.
    [Parameter(Mandatory = $true)][string]$Ndk,

    # Scratch directory for the smoke test.
    [string]$Scratch = (Join-Path $env:TEMP 'ohos-port-smoke'),

    # Use an isolated GOCACHE for the smoke test. Keep this on unless you have a
    # reason not to: it is a correctness guard, not just hygiene.
    [bool]$IsolateBuildCache = $true,

    # Skip the make.bat rebuild (use an already-built $GoTree).
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

# WHY $IsolateBuildCache EXISTS (measured during development, not theoretical)
# ----------------------------------------------------------------------------
# The go build cache is shared across GOROOT trees by default, and in this port the
# cached object for package "runtime" can be reused even when the assembler changed.
# Symptom seen: after correcting the R_ARM64_TLS_GD relocation size, a build inside a
# *pristine* tree still failed with
#
#     runtime.load_g: bad reloc size 0x10 for runtime.tls_g
#
# because the build served a runtime object compiled by the earlier assembler.
# Same tree, same command, fresh GOCACHE -> passed. A stale answer here is
# indistinguishable from a broken port, so the smoke test gets its own cache.

function Step([string]$name) { Write-Host "`n=== $name ===" -ForegroundColor Cyan }
function Pass([string]$msg) { Write-Host "  PASS  $msg" -ForegroundColor Green }
function Fail([string]$msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red; $failures.Add($msg) }
function Info([string]$msg) { Write-Host "        $msg" }

$go = Join-Path $GoTree 'bin\go.exe'
$clang = Join-Path $Ndk 'llvm\bin\clang.exe'
$readelf = Join-Path $Ndk 'llvm\bin\llvm-readelf.exe'
$nm = Join-Path $Ndk 'llvm\bin\llvm-nm.exe'
$sysroot = (Join-Path $Ndk 'sysroot') -replace '\\', '/'

Step 'Preconditions'
if ($Ndk -match ' ') {
    Fail "the NDK path contains a space ($Ndk); Go truncates CC at the first space. Use a junction."
} else { Pass "NDK path has no spaces" }
foreach ($p in @($BootstrapGo, $clang, $readelf, $nm)) {
    if (Test-Path $p) { Pass "found $p" } else { Fail "missing $p" }
}
if ($failures.Count -gt 0) { Write-Host "`nAborting: prerequisites not met." -ForegroundColor Red; exit 2 }

Step '1. Build the toolchain (make.bat)'
if ($SkipBuild) {
    Info '-SkipBuild given; using the existing $GoTree'
} else {
    $env:GOROOT_BOOTSTRAP = $BootstrapGo
    $prevPath = $env:PATH
    try {
        Push-Location (Join-Path $GoTree 'src')
        & cmd /c "make.bat 2>&1" | ForEach-Object { Write-Host "        $_" }
        if ($LASTEXITCODE -ne 0) { Fail "make.bat exited $LASTEXITCODE" } else { Pass 'make.bat succeeded' }
    } finally {
        Pop-Location
        $env:PATH = $prevPath
    }
}
if (-not (Test-Path $go)) { Fail "no go binary at $go"; exit 2 }
Info (& $go version)

Step '2. go tool dist list must include openharmony/arm64'
$dist = & $go tool dist list
$target = $dist | Where-Object { $_ -eq 'openharmony/arm64' }
if ($target) { Pass 'openharmony/arm64 is a known target' } else { Fail 'openharmony/arm64 missing from go tool dist list' }
$distJson = & $go tool dist list -json | Out-String
if ($distJson -match '"GOOS": "openharmony"[\s\S]{0,120}"CgoSupported": true') {
    Pass 'openharmony/arm64 reports CgoSupported: true'
} else {
    Fail 'openharmony/arm64 does not report CgoSupported: true (cgo builds would be refused)'
}

Step '3. Build a minimal -buildmode=c-shared library for openharmony/arm64'
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
if ($IsolateBuildCache) {
    $env:GOCACHE = Join-Path $Scratch 'gocache'
    Info "isolated GOCACHE=$env:GOCACHE (avoids reusing a runtime object built by a different assembler)"
}
# Write without a BOM: PowerShell 5.1 Set-Content -Encoding UTF8 adds one, and go.mod
# rejects a BOM ('unexpected input character \ufeff').
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $Scratch 'go.mod'), "module smoke`n`ngo 1.26`n", $utf8NoBom)
$mainSrc = @'
package main

import "C"

import "fmt"

//export Hello
func Hello() *C.char { return C.CString("hi " + fmt.Sprint(42)) }

func main() {}
'@
[System.IO.File]::WriteAllText((Join-Path $Scratch 'main.go'), $mainSrc, $utf8NoBom)

$so = Join-Path $Scratch 'libsmoke.so'
Remove-Item $so -ErrorAction SilentlyContinue
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:CGO_ENABLED = '1'
$env:GOTOOLCHAIN = 'local'
$env:CC = $clang
$env:CXX = (Join-Path $Ndk 'llvm\bin\clang++.exe')
$env:AR = (Join-Path $Ndk 'llvm\bin\llvm-ar.exe')
$env:CGO_CFLAGS = "--target=aarch64-linux-ohos --sysroot=$sysroot"
$env:CGO_LDFLAGS = "--target=aarch64-linux-ohos --sysroot=$sysroot -fuse-ld=lld"
$env:GOWORK = 'off'
$env:GOFLAGS = ''
$env:PATH = (Split-Path $go -Parent) + ';' + $env:PATH
Push-Location $Scratch
try {
    & $go build -buildmode=c-shared -o $so . 2>&1 | ForEach-Object { Write-Host "        $_" }
    if ($LASTEXITCODE -ne 0) { Fail "c-shared build exited $LASTEXITCODE" } else { Pass 'c-shared build produced an object' }
} finally { Pop-Location }

if (-not (Test-Path $so)) { Fail 'libsmoke.so was not produced'; }
else {
    Info ("libsmoke.so = {0:N0} bytes" -f (Get-Item $so).Length)

    Step '4. Acceptance: ELF shape, PT_TLS, R_AARCH64_TLSDESC'
    $hdr = & $readelf -h $so | Out-String
    if ($hdr -match 'ELF64') { Pass 'ELF64' } else { Fail 'not ELF64' }
    if ($hdr -match 'DYN') { Pass 'DYN (shared object)' } else { Fail 'not a shared object' }
    if ($hdr -match 'AArch64') { Pass 'AArch64' } else { Fail 'not AArch64' }

    $prog = & $readelf -l $so | Out-String
    if ($prog -match '(?m)^\s*TLS\s') { Pass 'PT_TLS segment present' } else { Fail 'no PT_TLS segment' }

    $dyn = & $readelf -r $so | Out-String
    if ($dyn -match 'R_AARCH64_TLSDESC') { Pass 'R_AARCH64_TLSDESC relocation present' }
    else { Fail 'no R_AARCH64_TLSDESC relocation (TLS model is not the general-dynamic one)' }

    $syms = & $nm -D --defined-only $so 2>$null | Out-String
    if ($syms -match '(?m)\bHello$' -or $syms -match '\sHello\s') { Pass 'cgo-exported symbol "Hello" is visible' }
    else { Fail 'exported symbol "Hello" not found in the dynamic symbol table' }
}

Step 'Summary'
if ($failures.Count -eq 0) {
    Write-Host '  ALL CHECKS PASSED' -ForegroundColor Green
    Write-Host '  Toolchain-level acceptance is met. Runtime behaviour on a real OHOS device is still unverified.'
    exit 0
} else {
    Write-Host "  $($failures.Count) CHECK(S) FAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
