<#
.SYNOPSIS
    Preflight check for the HarmonyOS build/release path.

.DESCRIPTION
    Answers one question: "can this machine actually run hvigorw right now?"
    It exists so the release job fails with a specific, actionable message
    instead of a confusing downstream error.

    Checks, in order:
      1. DevEco Studio install directory (DEVECO_HOME, else the default path)
      2. tools/hvigor/bin/hvigorw.bat
      3. tools/ohpm/bin/ohpm.bat
      4. the HarmonyOS SDK directory (DEVECO_SDK_HOME, else <dev>/sdk)
      5. a Java runtime for hap-sign-tool / hvigor (JAVA_HOME)
      6. this is actually the HarmonyBridge repository

    Exit codes: 0 = ready, 1 = not ready (with reasons printed).

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory, so the script
    does not depend on the caller's working directory.

.PARAMETER RequireDeveco
    Fail (instead of warn) when DevEco Studio is absent. The release job passes
    this; a local developer running it out of curiosity does not have to.

.PARAMETER Json
    Emit a machine-readable report.

.EXAMPLE
    pwsh -File scripts/release-preflight.ps1 -RequireDeveco
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $RequireDeveco,
    [switch] $Json
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# Windows PowerShell 5.1 reads files using the ANSI code page (GBK on this
# machine), which garbles the UTF-8 Chinese strings in release-metadata.json and
# makes ConvertFrom-Json fail. Read explicitly as UTF-8 instead of relying on
# the host default.
function Read-Utf8AllText {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$script:Checks = New-Object System.Collections.ArrayList

function Add-Check {
    param(
        [string] $Name,
        [bool]   $Ok,
        [string] $Detail,
        [switch] $Fatal
    )
    $null = $script:Checks.Add([pscustomobject]@{
            Name   = $Name
            Ok     = $Ok
            Detail = $Detail
            Fatal  = [bool] $Fatal
        })
}

# Persist a resolved path for the STEPS THAT FOLLOW. Under GitHub Actions each
# step is a fresh process, so a variable this script computed is gone by the
# next step unless it is handed to GITHUB_ENV. Without this, a workflow could
# successfully preflight the default DevEco path and then fail in the next step
# with `Join-Path : Cannot bind argument to parameter 'Path' because it is null`
# -- which is exactly what happened on the first real release run.
$script:Exported = New-Object System.Collections.ArrayList

function Export-Env {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string] $Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $null = $script:Exported.Add("$Name=$Value")
    if ($env:GITHUB_ENV) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Value "$Name=$Value" -Encoding utf8
    }
}

# ---------------------------------------------------------------------------
# 1. DevEco Studio
# ---------------------------------------------------------------------------
$deveco = $env:DEVECO_HOME
if ([string]::IsNullOrWhiteSpace($deveco)) {
    $deveco = 'D:\Harmony\DevEco Studio'
}
$devecoPresent = Test-Path -LiteralPath $deveco -PathType Container
Add-Check -Name 'DevEco Studio' -Ok $devecoPresent `
    -Detail "$deveco$(if ($devecoPresent) { '' } else { ' (not found; set $env:DEVECO_HOME)' })" `
    -Fatal:$RequireDeveco

# ---------------------------------------------------------------------------
# 2/3. hvigorw + ohpm
# ---------------------------------------------------------------------------
$hvigorw = if ($devecoPresent) { Join-Path $deveco 'tools\hvigor\bin\hvigorw.bat' } else { $null }
$hvigorOk = $hvigorw -and (Test-Path -LiteralPath $hvigorw -PathType Leaf)
Add-Check -Name 'hvigorw' -Ok $hvigorOk -Detail "$hvigorw" -Fatal:$RequireDeveco

$ohpm = if ($devecoPresent) { Join-Path $deveco 'tools\ohpm\bin\ohpm.bat' } else { $null }
$ohpmOk = $ohpm -and (Test-Path -LiteralPath $ohpm -PathType Leaf)
Add-Check -Name 'ohpm' -Ok $ohpmOk -Detail "$ohpm" -Fatal:$RequireDeveco

# ---------------------------------------------------------------------------
# 4. HarmonyOS SDK
# ---------------------------------------------------------------------------
$sdk = $env:DEVECO_SDK_HOME
if ([string]::IsNullOrWhiteSpace($sdk) -and $devecoPresent) {
    $sdk = Join-Path $deveco 'sdk'
}
$sdkOk = $sdk -and (Test-Path -LiteralPath $sdk -PathType Container)
Add-Check -Name 'HarmonyOS SDK' -Ok ([bool] $sdkOk) `
    -Detail "$sdk$(if ($sdkOk) { '' } else { " (not found; hvigor reports 'Invalid value of DEVECO_SDK_HOME')" })" `
    -Fatal:$RequireDeveco

# ---------------------------------------------------------------------------
# 5. Java
# ---------------------------------------------------------------------------
$java = $env:JAVA_HOME
if ([string]::IsNullOrWhiteSpace($java) -and $devecoPresent) {
    $candidate = Join-Path $deveco 'jbr'
    if (Test-Path -LiteralPath $candidate -PathType Container) { $java = $candidate }
}
# Without JAVA_HOME, hvigor fails with "spawn java ENOENT".
$javaOk = $false
if ($java -and (Test-Path -LiteralPath (Join-Path $java 'bin') -PathType Container)) {
    $javaOk = $true
} elseif (Get-Command java -ErrorAction SilentlyContinue) {
    $javaOk = $true
    $java = (Get-Command java).Source
}
Add-Check -Name 'Java runtime' -Ok $javaOk `
    -Detail "$java$(if ($javaOk) { '' } else { ' (not found; hvigor reports "spawn java ENOENT")' })" `
    -Fatal:$RequireDeveco

# ---------------------------------------------------------------------------
# Export the resolved paths for the following steps (see Export-Env).
# ---------------------------------------------------------------------------
if ($devecoPresent) { Export-Env -Name 'DEVECO_HOME' -Value $deveco }
if ($sdkOk) { Export-Env -Name 'DEVECO_SDK_HOME' -Value $sdk }
if ($javaOk -and $java -and (Test-Path -LiteralPath (Join-Path $java 'bin') -PathType Container)) {
    Export-Env -Name 'JAVA_HOME' -Value $java
}

# ---------------------------------------------------------------------------
# 6. Repository sanity
# ---------------------------------------------------------------------------
$metadataPath = Join-Path (Join-Path $RepoRoot 'scripts') 'release-metadata.json'
$metadataPresent = Test-Path -LiteralPath $metadataPath -PathType Leaf
$metadata = $null
if ($metadataPresent) {
    try {
        $metadata = Read-Utf8AllText -Path $metadataPath | ConvertFrom-Json
    } catch {
        Write-Host "release-preflight: could not parse $metadataPath -- $($_.Exception.Message)"
        $metadataPresent = $false
    }
}
Add-Check -Name 'release-metadata.json' -Ok $metadataPresent `
    -Detail "$metadataPath$(if ($metadataPresent) { '' } else { ' (unreadable or missing)' })" -Fatal

if ($metadataPresent -and $metadata) {
    $unsignedHap = Join-Path $RepoRoot $metadata.paths.unsignedHap
    $outputsDir = Split-Path -Parent $unsignedHap
    Add-Check -Name 'HAP output directory' -Ok (Test-Path -LiteralPath $outputsDir -PathType Container) `
        -Detail "$outputsDir$(if (Test-Path -LiteralPath $outputsDir -PathType Container) { '' } else { ' (not built yet; this is expected before assembleHap)' })"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$fatal = @($script:Checks | Where-Object { -not $_.Ok -and $_.Fatal })
$failed = @($script:Checks | Where-Object { -not $_.Ok })

if ($Json) {
    [pscustomobject]@{
        repoRoot  = $RepoRoot
        ready     = ($failed.Count -eq 0)
        failures  = @($failed | ForEach-Object { $_.Name })
        exported  = @($script:Exported)
        checks    = $script:Checks
    } | ConvertTo-Json -Depth 5
} else {
    Write-Host 'release-preflight:'
    foreach ($check in $script:Checks) {
        $mark = if ($check.Ok) { 'OK  ' } else { 'MISS' }
        Write-Host ("  [{0}] {1,-24} {2}" -f $mark, $check.Name, $check.Detail)
    }
    if ($script:Exported.Count -gt 0) {
        Write-Host ''
        Write-Host '  resolved for subsequent steps:'
        foreach ($line in $script:Exported) { Write-Host "    $line" }
        if (-not $env:GITHUB_ENV) {
            Write-Host '    (not running under GitHub Actions: nothing was written to GITHUB_ENV)'
        }
    }
}

if ($fatal.Count -gt 0) {
    Write-Host ''
    foreach ($check in $fatal) {
        Write-Host "::error::release preflight failed: $($check.Name) -- $($check.Detail)"
    }
    Write-Host 'This machine cannot build a HAP. See docs/design/ci.md -> "自托管 HarmonyOS runner".'
    exit 1
}

if (-not $Json) {
    Write-Host ''
    if ($failed.Count -eq 0) {
        Write-Host 'release-preflight: ready to build.'
    } else {
        Write-Host "release-preflight: $($failed.Count) non-fatal gap(s); build may still work."
    }
}
exit 0
