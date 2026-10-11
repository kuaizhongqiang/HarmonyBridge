#Requires -Version 5.1
<#
.SYNOPSIS
    Environment diagnostic for the HarmonyBridge (HarmonyOS / ArkTS) project.

.DESCRIPTION
    Detects and reports every tool the project needs, printing the exact paths and
    versions found. Answers the single question "can I build here?".

    Every item is reported as OK / WARN / FAIL. The script never throws on a
    missing tool -- it degrades to a report -- and exits non-zero only when a
    *hard* requirement is unmet, so it is safe to call from bootstrap.ps1 and CI.

    Hard failures (exit 1):
      * DevEco Studio install directory not found
      * HarmonyOS SDK directory not found
      * project build-profile.json5 missing / not parseable
      * git missing, or the current directory is not a git work tree
      * node missing or older than 18
      * NDK clang / llvm-config missing
      * ohpm and hvigorw missing from BOTH PATH and the DevEco install

    Warnings (exit 0, reported):
      * git-lfs missing or `git lfs` not initialised for this clone
      * go missing (only the native core workstream needs it)
      * java missing (only needed for hap-sign-tool.jar / the release signing step)

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory.

.PARAMETER DevEcoHome
    DevEco Studio install directory. Defaults to, in order: $env:DEVECO_HOME,
    $env:DEVECO_STUDIO_HOME, the registry, then well-known locations.

.PARAMETER SdkHome
    HarmonyOS SDK root. Defaults to <DevEcoHome>\sdk\default\openharmony.

.PARAMETER Json
    Emit the whole report as a single JSON object instead of human text.

.PARAMETER RequireGo
    Treat a missing `go` toolchain as a hard failure. Intended for the native
    core CI job, not for day-to-day work.

.PARAMETER RequireJava
    Treat a missing JDK/JBR as a hard failure. Intended for the release
    signing job.

.EXAMPLE
    pwsh -NoProfile -File scripts/check-env.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-env.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/check-env.ps1 -Json
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $DevEcoHome,
    [string] $SdkHome,
    [switch] $Json,
    [switch] $RequireGo,
    [switch] $RequireJava
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
# Do not let a stray stderr line from a native tool abort the run.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ---------------------------------------------------------------------------
# Result collection
# ---------------------------------------------------------------------------
$script:Results = New-Object System.Collections.ArrayList

# Windows PowerShell 5.1 has no $IsWindows; decide once, from the path separator.
$IsWindowsEquivalent = ($true)
if ([System.IO.Path]::DirectorySeparatorChar -eq '/') { $IsWindowsEquivalent = $false }
$Script:PathSeparator = ';'
if (-not $IsWindowsEquivalent) { $Script:PathSeparator = ':' }

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string] $Status,
        [string] $Value = '',
        [string] $Detail = ''
    )
    $null = $script:Results.Add([pscustomobject]@{
            Name   = $Name
            Status = $Status
            Value  = $Value
            Detail = $Detail
        })
}

# ---------------------------------------------------------------------------
# Small process helpers (Windows PowerShell 5.1 / PowerShell 7 compatible)
# ---------------------------------------------------------------------------

# Read the first non-empty line of a native command's combined output.
function Get-CommandLine {
    param(
        [Parameter(Mandatory = $true)][string] $Exe,
        [string[]] $Arguments = @()
    )
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    $global:LASTEXITCODE = 0
    $output = $null
    try {
        $output = & $Exe @Arguments 2>&1
    }
    catch {
        return $null
    }
    foreach ($line in @($output)) {
        $text = [string] $line
        if ($text.Trim().Length -gt 0) { return $text.Trim() }
    }
    return $null
}

# Resolve an executable on PATH, then in a fixed set of fallback directories.
# On Windows the .bat/.cmd/.exe launcher is preferred over the extensionless
# POSIX shell script that ships next to it (ohpm, hvigorw), because only the
# former can be invoked directly from PowerShell.
function Resolve-Tool {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string[]] $Fallbacks = @()
    )
    $preferredExtensions = @('', '.bat', '.cmd', '.exe', '.ps1')
    if ($IsWindowsEquivalent) {
        $preferredExtensions = @('.bat', '.cmd', '.exe', '.ps1', '')
    }

    $pathDirs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:PATH)) { $pathDirs = $env:PATH -split [regex]::Escape($Script:PathSeparator) }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        $source = $cmd.Source
        if ([string]::IsNullOrEmpty($source)) { $source = $cmd.Definition }
        $looksLikeShim = $false
        if ($IsWindowsEquivalent -and $null -ne $source) {
            $looksLikeShim = (-not ($source -match '\.(bat|cmd|exe|ps1)$'))
        }
        if (-not $looksLikeShim) {
            return [pscustomobject]@{ Name = $Name; Path = $source; Origin = 'PATH' }
        }
    }

    $searchDirs = @()
    $searchDirs += $pathDirs
    $searchDirs += $Fallbacks
    foreach ($dir in $searchDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($ext in $preferredExtensions) {
            $candidate = Join-Path $dir ($Name + $ext)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $origin = 'PATH'
                if ($Fallbacks -contains $dir) { $origin = 'DevEco' }
                return [pscustomobject]@{ Name = $Name; Path = $candidate; Origin = $origin }
            }
        }
    }
    return $null
}

# Very small "extract the string value of a JSON5 key" helper. build-profile.json5
# and the SDK manifests are strict JSON in practice, but they may carry comments,
# so a regex is safer here than a strict parser and enough for scalar values.
function Get-Json5Scalar {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Key
    )
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

# ---------------------------------------------------------------------------
# 0. Repository root
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
}
elseif (Test-Path -LiteralPath $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

# ---------------------------------------------------------------------------
# 1. DevEco Studio install directory
# ---------------------------------------------------------------------------
$devEcoCandidates = New-Object System.Collections.ArrayList
foreach ($v in @($DevEcoHome, $env:DEVECO_HOME, $env:DEVECO_STUDIO_HOME, $env:DEVECO_SDK_HOME)) {
    if (-not [string]::IsNullOrWhiteSpace($v)) { $null = $devEcoCandidates.Add($v) }
}
# Registry: DevEco Studio records its install location under this key on Windows.
foreach ($hive in @('HKLM:\SOFTWARE\Huawei\DevEcoStudio', 'HKCU:\SOFTWARE\Huawei\DevEcoStudio')) {
    try {
        $key = Get-ItemProperty -Path $hive -ErrorAction Stop
        foreach ($prop in @('InstallLocation', 'InstallDir', 'Path', 'Home')) {
            if ($null -ne $key.$prop) { $null = $devEcoCandidates.Add([string] $key.$prop) }
        }
    }
    catch { }
}
foreach ($v in @('D:\Harmony\DevEco Studio', 'C:\Program Files\Huawei\DevEco Studio', 'D:\DevEco Studio', 'C:\DevEco Studio')) {
    $null = $devEcoCandidates.Add($v)
}

$resolvedDevEco = $null
foreach ($candidate in $devEcoCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $resolvedDevEco = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

if ($null -ne $resolvedDevEco) {
    $version = $null
    $productInfoPath = Join-Path $resolvedDevEco 'product-info.json'
    if (Test-Path -LiteralPath $productInfoPath) {
        $version = Get-Json5Scalar -Text (Get-Content -LiteralPath $productInfoPath -Raw) -Key 'version'
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        $buildTxt = Join-Path $resolvedDevEco 'build.txt'
        if (Test-Path -LiteralPath $buildTxt) { $version = (Get-Content -LiteralPath $buildTxt -Raw).Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }
    Add-Check -Name 'DevEco Studio' -Status 'OK' -Value $resolvedDevEco -Detail ("version " + $version)
}
else {
    Add-Check -Name 'DevEco Studio' -Status 'FAIL' -Value '(not found)' `
        -Detail 'set -DevEcoHome or $env:DEVECO_HOME'
}

# ---------------------------------------------------------------------------
# 2. HarmonyOS SDK
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SdkHome) -and $null -ne $resolvedDevEco) {
    $SdkHome = Join-Path $resolvedDevEco 'sdk\default\openharmony'
}

if (-not [string]::IsNullOrWhiteSpace($SdkHome) -and (Test-Path -LiteralPath $SdkHome -PathType Container)) {
    $SdkHome = (Resolve-Path -LiteralPath $SdkHome).Path
    $apiVersion = $null
    $platformVersion = $null
    $sdkManifest = Join-Path $SdkHome 'native\oh-uni-package.json'
    if (Test-Path -LiteralPath $sdkManifest) {
        $manifestText = Get-Content -LiteralPath $sdkManifest -Raw
        $apiVersion = Get-Json5Scalar -Text $manifestText -Key 'apiVersion'
        $platformVersion = Get-Json5Scalar -Text $manifestText -Key 'platformVersion'
    }
    $sdkDetail = @()
    if (-not [string]::IsNullOrWhiteSpace($apiVersion)) { $sdkDetail += ('native apiVersion ' + $apiVersion) }
    if (-not [string]::IsNullOrWhiteSpace($platformVersion)) { $sdkDetail += ('platformVersion ' + $platformVersion) }
    Add-Check -Name 'HarmonyOS SDK' -Status 'OK' -Value $SdkHome -Detail ($sdkDetail -join ', ')
}
else {
    Add-Check -Name 'HarmonyOS SDK' -Status 'FAIL' -Value '(not found)' `
        -Detail 'expected <DevEcoHome>\sdk\default\openharmony (or pass -SdkHome)'
}

# ---------------------------------------------------------------------------
# 3. Project SDK levels, parsed out of build-profile.json5
# ---------------------------------------------------------------------------
$buildProfile = Join-Path $RepoRoot 'build-profile.json5'
$compatibleSdkVersion = $null
$targetSdkVersion = $null
if (Test-Path -LiteralPath $buildProfile) {
    $profileText = Get-Content -LiteralPath $buildProfile -Raw
    $compatibleSdkVersion = Get-Json5Scalar -Text $profileText -Key 'compatibleSdkVersion'
    $targetSdkVersion = Get-Json5Scalar -Text $profileText -Key 'targetSdkVersion'
    if ([string]::IsNullOrWhiteSpace($compatibleSdkVersion) -and [string]::IsNullOrWhiteSpace($targetSdkVersion)) {
        Add-Check -Name 'build-profile.json5' -Status 'FAIL' -Value $buildProfile `
            -Detail 'found neither compatibleSdkVersion nor targetSdkVersion'
    }
    else {
        Add-Check -Name 'build-profile.json5' -Status 'OK' -Value $buildProfile `
            -Detail ('compatibleSdkVersion=' + $compatibleSdkVersion + ' targetSdkVersion=' + $targetSdkVersion)
    }
}
else {
    Add-Check -Name 'build-profile.json5' -Status 'FAIL' -Value $buildProfile -Detail 'file missing'
}

# Cross-check the SDK on disk against the API level the project asks for.
$projectApiLevel = $null
if (-not [string]::IsNullOrWhiteSpace($compatibleSdkVersion)) {
    $apiMatch = [regex]::Match($compatibleSdkVersion, '\((\d+)\)')
    if ($apiMatch.Success) { $projectApiLevel = $apiMatch.Groups[1].Value }
}
if (-not [string]::IsNullOrWhiteSpace($projectApiLevel)) {
    if ($projectApiLevel -eq $apiVersion) {
        Add-Check -Name 'SDK / project API match' -Status 'OK' `
            -Value ('api ' + $projectApiLevel) -Detail 'compatibleSdkVersion matches the installed SDK'
    }
    else {
        Add-Check -Name 'SDK / project API match' -Status 'WARN' `
            -Value ('project api ' + $projectApiLevel + ' vs sdk api ' + $apiVersion) `
            -Detail 'install the matching SDK from DevEco Studio -> SDK Manager if the build complains'
    }
}

# ---------------------------------------------------------------------------
# 4. Native toolchain (NDK clang + llvm-config + cmake)
# ---------------------------------------------------------------------------
$ndkLlvmBin = $null
if (-not [string]::IsNullOrWhiteSpace($SdkHome)) { $ndkLlvmBin = Join-Path $SdkHome 'native\llvm\bin' }

$clangPath = $null
$llvmConfigPath = $null
if (-not [string]::IsNullOrWhiteSpace($ndkLlvmBin) -and (Test-Path -LiteralPath $ndkLlvmBin)) {
    foreach ($name in @('clang.exe', 'clang')) {
        $probe = Join-Path $ndkLlvmBin $name
        if (Test-Path -LiteralPath $probe -PathType Leaf) { $clangPath = $probe; break }
    }
    foreach ($name in @('llvm-config.exe', 'llvm-config')) {
        $probe = Join-Path $ndkLlvmBin $name
        if (Test-Path -LiteralPath $probe -PathType Leaf) { $llvmConfigPath = $probe; break }
    }
}

$clangVersion = $null
if ($null -ne $clangPath) {
    $clangVersion = Get-CommandLine -Exe $clangPath -Arguments @('--version')
    Add-Check -Name 'NDK clang' -Status 'OK' -Value $clangPath -Detail ([string] $clangVersion)
}
else {
    Add-Check -Name 'NDK clang' -Status 'FAIL' -Value '(not found)' `
        -Detail ('expected ' + $ndkLlvmBin + '\clang.exe')
}

$llvmConfigVersion = $null
if ($null -ne $llvmConfigPath) {
    $llvmConfigVersion = Get-CommandLine -Exe $llvmConfigPath -Arguments @('--version')
    Add-Check -Name 'NDK llvm-config' -Status 'OK' -Value $llvmConfigPath -Detail ('llvm ' + $llvmConfigVersion)
}
else {
    Add-Check -Name 'NDK llvm-config' -Status 'FAIL' -Value '(not found)' `
        -Detail ('expected ' + $ndkLlvmBin + '\llvm-config.exe')
}

$cmakePath = $null
if (-not [string]::IsNullOrWhiteSpace($SdkHome)) {
    $sdkCmake = Join-Path $SdkHome 'native\build-tools\cmake\bin\cmake.exe'
    if (Test-Path -LiteralPath $sdkCmake -PathType Leaf) { $cmakePath = $sdkCmake }
}
if ($null -eq $cmakePath) {
    $cmakeCmd = Resolve-Tool -Name 'cmake'
    if ($null -ne $cmakeCmd) { $cmakePath = $cmakeCmd.Path }
}
if ($null -ne $cmakePath) {
    Add-Check -Name 'NDK cmake' -Status 'OK' -Value $cmakePath `
        -Detail ([string] (Get-CommandLine -Exe $cmakePath -Arguments @('--version')))
}
else {
    Add-Check -Name 'NDK cmake' -Status 'WARN' -Value '(not found)' `
        -Detail 'hvigor normally drives CMake itself; only needed for out-of-band native builds'
}

# ---------------------------------------------------------------------------
# 5. Node.js / npm
# ---------------------------------------------------------------------------
$nodeFallbacks = @()
if ($null -ne $resolvedDevEco) { $nodeFallbacks += (Join-Path $resolvedDevEco 'tools\node') }
$node = Resolve-Tool -Name 'node' -Fallbacks $nodeFallbacks
if ($null -ne $node) {
    $nodeVersion = Get-CommandLine -Exe $node.Path -Arguments @('--version')
    $nodeVersionText = [string] $nodeVersion
    $nodeMajor = 0
    $majorMatch = [regex]::Match($nodeVersionText, 'v?(\d+)')
    if ($majorMatch.Success) { $nodeMajor = [int] $majorMatch.Groups[1].Value }
    if ($nodeMajor -ge 18) {
        Add-Check -Name 'node' -Status 'OK' -Value $node.Path -Detail ($nodeVersionText + ' (' + $node.Origin + ')')
    }
    else {
        Add-Check -Name 'node' -Status 'FAIL' -Value $node.Path `
            -Detail ($nodeVersionText + ' is too old; hvigor and scripts/validate-json5.mjs need node >= 18')
    }
}
else {
    Add-Check -Name 'node' -Status 'FAIL' -Value '(not found)' -Detail 'install Node.js >= 18, or use the node bundled with DevEco Studio'
}

$npm = Resolve-Tool -Name 'npm' -Fallbacks $nodeFallbacks
if ($null -ne $npm) {
    Add-Check -Name 'npm' -Status 'OK' -Value $npm.Path `
        -Detail ([string] (Get-CommandLine -Exe $npm.Path -Arguments @('--version')))
}
else {
    Add-Check -Name 'npm' -Status 'WARN' -Value '(not found)' `
        -Detail 'not required: ohpm, not npm, manages the HarmonyOS dependencies'
}

# ---------------------------------------------------------------------------
# 6. ohpm / hvigorw (PATH first, then inside the DevEco install)
# ---------------------------------------------------------------------------
$devEcoFallbacks = @()
if ($null -ne $resolvedDevEco) {
    $devEcoFallbacks += (Join-Path $resolvedDevEco 'tools\ohpm\bin')
    $devEcoFallbacks += (Join-Path $resolvedDevEco 'tools\hvigor\bin')
}

$ohpm = Resolve-Tool -Name 'ohpm' -Fallbacks $devEcoFallbacks
if ($null -ne $ohpm) {
    $ohpmVersion = [string] (Get-CommandLine -Exe $ohpm.Path -Arguments @('-v'))
    if ([string]::IsNullOrWhiteSpace($ohpmVersion)) {
        $ohpmVersion = [string] (Get-CommandLine -Exe $ohpm.Path -Arguments @('--version'))
    }
    Add-Check -Name 'ohpm' -Status 'OK' -Value $ohpm.Path -Detail ($ohpmVersion + ' (' + $ohpm.Origin + ')')
}
else {
    Add-Check -Name 'ohpm' -Status 'FAIL' -Value '(not found)' `
        -Detail 'expected <DevEcoHome>\tools\ohpm\bin\ohpm.bat'
}

$hvigorw = Resolve-Tool -Name 'hvigorw' -Fallbacks $devEcoFallbacks
if ($null -ne $hvigorw) {
    $hvigorVersion = [string] (Get-CommandLine -Exe $hvigorw.Path -Arguments @('--version'))
    Add-Check -Name 'hvigorw' -Status 'OK' -Value $hvigorw.Path -Detail ($hvigorVersion + ' (' + $hvigorw.Origin + ')')
}
else {
    Add-Check -Name 'hvigorw' -Status 'FAIL' -Value '(not found)' `
        -Detail 'expected <DevEcoHome>\tools\hvigor\bin\hvigorw.bat'
}

# The project's own hvigor wrapper (created by `hvigorw` on first run) is what CI
# would call. Report whether it already exists so the diagnostic is honest about
# what is and is not in the tree.
$localWrapper = Join-Path $RepoRoot 'hvigorw.bat'
if (Test-Path -LiteralPath $localWrapper) {
    Add-Check -Name 'hvigorw (repo wrapper)' -Status 'OK' -Value $localWrapper -Detail 'present'
}
else {
    Add-Check -Name 'hvigorw (repo wrapper)' -Status 'WARN' -Value '(absent)' `
        -Detail 'not committed; generate with `hvigorw --version` inside the DevEco terminal'
}

# ---------------------------------------------------------------------------
# 7. Git and Git LFS
# ---------------------------------------------------------------------------
$git = Resolve-Tool -Name 'git'
if ($null -ne $git) {
    $gitVersion = [string] (Get-CommandLine -Exe $git.Path -Arguments @('--version'))
    Add-Check -Name 'git' -Status 'OK' -Value $git.Path -Detail $gitVersion

    $inWorkTree = $false
    try {
        $null = & git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -eq 0) { $inWorkTree = $true }
    }
    catch { }
    if ($inWorkTree) {
        Add-Check -Name 'git work tree' -Status 'OK' -Value $RepoRoot -Detail 'rev-parse succeeded'
    }
    else {
        Add-Check -Name 'git work tree' -Status 'FAIL' -Value $RepoRoot -Detail 'not a git work tree'
    }
}
else {
    Add-Check -Name 'git' -Status 'FAIL' -Value '(not found)' -Detail 'install Git for Windows'
}

$gitLfs = Resolve-Tool -Name 'git-lfs'
if ($null -ne $gitLfs) {
    Add-Check -Name 'git-lfs' -Status 'OK' -Value $gitLfs.Path `
        -Detail ([string] (Get-CommandLine -Exe $gitLfs.Path -Arguments @('version')))
}
else {
    $lfsHelp = $null
    if ($null -ne $git) { $lfsHelp = [string] (Get-CommandLine -Exe $git.Path -Arguments @('lfs', 'version')) }
    if (-not [string]::IsNullOrWhiteSpace($lfsHelp)) {
        Add-Check -Name 'git-lfs' -Status 'OK' -Value 'git lfs' -Detail $lfsHelp
    }
    else {
        Add-Check -Name 'git-lfs' -Status 'WARN' -Value '(not found)' `
            -Detail 'needed for the *.so / *.p12 LFS filters declared in .gitattributes'
    }
}

# Is `git lfs` initialised for THIS clone? `git lfs install` writes the local
# filter.lfs.* config entries; a fresh clone that has not run it will fail to
# smudge LFS objects.
$lfsLocalClean = $null
if ($null -ne $git) {
    try { $lfsLocalClean = [string] (& git -C $RepoRoot config --local --get filter.lfs.clean 2>$null) } catch { }
}
if (-not [string]::IsNullOrWhiteSpace($lfsLocalClean)) {
    Add-Check -Name 'git lfs initialised' -Status 'OK' -Value 'filter.lfs.clean set' -Detail $lfsLocalClean
}
else {
    Add-Check -Name 'git lfs initialised' -Status 'WARN' -Value 'not initialised for this clone' `
        -Detail 'run scripts/bootstrap.ps1 (or `git lfs install`) once per clone'
}

# ---------------------------------------------------------------------------
# 8. Go toolchain (native proxy core)
# ---------------------------------------------------------------------------
$go = Resolve-Tool -Name 'go'
if ($null -ne $go) {
    Add-Check -Name 'go' -Status 'OK' -Value $go.Path `
        -Detail ([string] (Get-CommandLine -Exe $go.Path -Arguments @('version')))
}
else {
    if ($RequireGo) {
        Add-Check -Name 'go' -Status 'FAIL' -Value '(not found)' `
            -Detail 'required here: install Go (see scripts/build-core.sh)'
    }
    else {
        Add-Check -Name 'go' -Status 'WARN' -Value '(not found)' `
            -Detail 'only needed to build the native proxy core (see docs/design/ci.md)'
    }
}

# ---------------------------------------------------------------------------
# 9. Java / JBR (hap-sign-tool.jar)
# ---------------------------------------------------------------------------
$javaHome = $null
if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { $javaHome = $env:JAVA_HOME }
if ([string]::IsNullOrWhiteSpace($javaHome) -and $null -ne $resolvedDevEco) {
    $jbr = Join-Path $resolvedDevEco 'jbr'
    if (Test-Path -LiteralPath $jbr) { $javaHome = $jbr }
}
$javaExe = $null
$java = Resolve-Tool -Name 'java' -Fallbacks @($(if (-not [string]::IsNullOrWhiteSpace($javaHome)) { Join-Path $javaHome 'bin' }))
if ($null -ne $java) { $javaExe = $java.Path }
if ($null -ne $javaExe) {
    $javaVersion = Get-CommandLine -Exe $javaExe -Arguments @('-version')
    Add-Check -Name 'java' -Status 'OK' -Value $javaExe -Detail ([string] $javaVersion)
}
else {
    if ($RequireJava) {
        Add-Check -Name 'java' -Status 'FAIL' -Value '(not found)' -Detail 'required for hap-sign-tool.jar'
    }
    else {
        Add-Check -Name 'java' -Status 'WARN' -Value '(not found)' `
            -Detail 'only needed to run hap-sign-tool.jar during a signed release build'
    }
}

# ---------------------------------------------------------------------------
# 10. PowerShell hosts. `pwsh` is not on PATH on a stock DevEco machine, which
#     matters because bootstrap.ps1 and the pre-commit hook both prefer it.
# ---------------------------------------------------------------------------
$psHost = $PSVersionTable.PSVersion.ToString()
# NB: do not name this $psEdition -- PowerShell variable names are
# case-insensitive and $PSEdition is a read-only automatic variable.
$hostEdition = 'Windows PowerShell'
if ($PSVersionTable.PSEdition -eq 'Core') { $hostEdition = 'PowerShell (Core)' }
Add-Check -Name 'powershell (this host)' -Status 'OK' -Value ('v' + $psHost) -Detail $hostEdition

$pwshPath = $null
$pwshCmd = Resolve-Tool -Name 'pwsh' -Fallbacks @(
    $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'PowerShell\7' })
)
if ($null -ne $pwshCmd) { $pwshPath = $pwshCmd.Path }
if ($null -ne $pwshPath) {
    Add-Check -Name 'pwsh (PowerShell 7+)' -Status 'OK' -Value $pwshPath -Detail 'preferred by bootstrap.ps1 and the pre-commit hook'
}
else {
    Add-Check -Name 'pwsh (PowerShell 7+)' -Status 'WARN' -Value '(not found)' `
        -Detail 'optional: Windows PowerShell 5.1 is used instead (slower, same results)'
}

# ---------------------------------------------------------------------------
# 11. Signing toolchain (location only -- never look for key material here)
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($SdkHome)) {
    $signTool = Join-Path $SdkHome 'toolchains\lib\hap-sign-tool.jar'
    if (Test-Path -LiteralPath $signTool -PathType Leaf) {
        Add-Check -Name 'hap-sign-tool.jar' -Status 'OK' -Value $signTool -Detail 'present (signing material deliberately not probed)'
    }
    else {
        Add-Check -Name 'hap-sign-tool.jar' -Status 'WARN' -Value '(not found)' `
            -Detail ('expected ' + $signTool)
    }
}
else {
    Add-Check -Name 'hap-sign-tool.jar' -Status 'SKIP' -Value '(sdk unknown)' -Detail 'cannot probe without the SDK path'
}

# ---------------------------------------------------------------------------
# 12. Relevant environment variables (informational)
# ---------------------------------------------------------------------------
foreach ($name in @('DEVECO_SDK_HOME', 'DEVECO_HOME', 'DEVECO_STUDIO_HOME', 'JAVA_HOME', 'GOPATH', 'GOROOT', 'OHPM_HOME', 'NODE_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Add-Check -Name ('env ' + $name) -Status 'SKIP' -Value '(unset)'
    }
    else {
        Add-Check -Name ('env ' + $name) -Status 'OK' -Value $value
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$okCount = @($script:Results | Where-Object { $_.Status -eq 'OK' }).Count
$verdict = 'READY'
if ($failCount -gt 0) { $verdict = 'NOT READY' }
elseif ($warnCount -gt 0) { $verdict = 'READY (with warnings)' }

if ($Json) {
    $payload = [pscustomobject]@{
        repoRoot = $RepoRoot
        devEcoHome = $resolvedDevEco
        sdkHome = $SdkHome
        compatibleSdkVersion = $compatibleSdkVersion
        targetSdkVersion = $targetSdkVersion
        verdict = $verdict
        ok = $okCount
        warnings = $warnCount
        failures = $failCount
        checks = $script:Results
    }
    $payload | ConvertTo-Json -Depth 5
}
else {
    $width = 0
    foreach ($r in $script:Results) {
        if ($r.Name.Length -gt $width) { $width = $r.Name.Length }
    }
    Write-Host ''
    Write-Host '  HarmonyBridge environment check'
    Write-Host ('  repo: ' + $RepoRoot)
    Write-Host ('  ' + ('-' * 78))
    foreach ($r in $script:Results) {
        $label = $r.Name.PadRight($width)
        $statusText = $r.Status.PadRight(4)
        $line = '  [' + $statusText + '] ' + $label + '  ' + $r.Value
        if (-not [string]::IsNullOrWhiteSpace($r.Detail)) { $line += '  -- ' + $r.Detail }
        switch ($r.Status) {
            'FAIL' { Write-Host $line -ForegroundColor Red }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'SKIP' { Write-Host $line -ForegroundColor DarkGray }
            default { Write-Host $line }
        }
    }
    Write-Host ('  ' + ('-' * 78))
    Write-Host ('  OK: ' + $okCount + '   WARN: ' + $warnCount + '   FAIL: ' + $failCount)
    if ($failCount -gt 0) {
        Write-Host ('  VERDICT: ' + $verdict + ' -- fix the FAIL items above before building.') -ForegroundColor Red
    }
    else {
        Write-Host ('  VERDICT: ' + $verdict) -ForegroundColor Green
    }
    Write-Host ''
}

if ($failCount -gt 0) { exit 1 }
exit 0
