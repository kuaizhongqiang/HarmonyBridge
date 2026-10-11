#Requires -Version 5.1
<#
.SYNOPSIS
    Fresh clone -> ready to work, for the HarmonyBridge HarmonyOS project.

.DESCRIPTION
    The one command a new contributor (or a self-hosted CI runner) runs after
    `git clone`. Steps, all idempotent so the script is safe to re-run at any
    time:

      1. verify `git` and `git-lfs` are installed
      2. `git lfs install`                    -- enables the LFS filters declared
                                                 in .gitattributes for this clone
      3. `git submodule update --init --depth 1`
                                              -- materialises third_party/v2rayN
                                                 (read-only reference only)
      4. delegate to scripts/check-env.ps1    -- report whether this machine can
                                                 actually build the project

    Step 4 is delegated rather than duplicated on purpose: check-env.ps1 is the
    single source of truth for "can I build here?" and is what CI runs too.

    NOTE on --recursive: it is deliberately NOT the default. third_party/v2rayN
    carries a nested submodule (GlobalHotKeys) that has nothing to do with this
    project; fetching it wastes time and bandwidth. Pass -Recursive if you
    actually need the whole reference tree. See AGENT.md section 5.1.

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory.

.PARAMETER SkipSubmodules
    Do not touch submodules (useful in an offline environment or when the
    reference submodule is not needed).

.PARAMETER Recursive
    Also fetch nested submodules of the reference submodules.

.PARAMETER SkipEnvCheck
    Stop after the clone preparation steps; do not run check-env.ps1.

.PARAMETER Depth
    Shallow-clone depth for submodules. Defaults to 1. Pass 0 for a full clone.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $SkipSubmodules,
    [switch] $Recursive,
    [switch] $SkipEnvCheck,
    [int] $Depth = 1
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$script:HardFailure = $false

function Write-Step {
    param([string] $Text)
    Write-Host ''
    Write-Host ('==> ' + $Text) -ForegroundColor Cyan
}

function Write-Ok {
    param([string] $Text)
    Write-Host ('    [ OK ] ' + $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string] $Text)
    Write-Host ('    [WARN] ' + $Text) -ForegroundColor Yellow
}

function Write-Err {
    param([string] $Text)
    Write-Host ('    [FAIL] ' + $Text) -ForegroundColor Red
    $script:HardFailure = $true
}

function Invoke-Native {
    <#
        Run a native command with inherited stdout (so the user sees exactly what
        git prints), returning $true when it exits 0. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Exe,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    $global:LASTEXITCODE = 0
    try {
        & $Exe @Arguments
    }
    catch {
        Write-Warn ($Exe + ' threw: ' + $_.Exception.Message)
        return $false
    }
    return ($LASTEXITCODE -eq 0)
}

function Get-FirstLine {
    param([string] $Exe, [string[]] $Arguments)
    $global:LASTEXITCODE = 0
    $out = $null
    try { $out = & $Exe @Arguments 2>&1 } catch { return $null }
    foreach ($line in @($out)) {
        $text = [string] $line
        if ($text.Trim().Length -gt 0) { return $text.Trim() }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 0. Locate the repository
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
}
elseif (Test-Path -LiteralPath $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

Write-Host ''
Write-Host '  HarmonyBridge bootstrap' -ForegroundColor White
Write-Host ('  repo: ' + $RepoRoot)

# ---------------------------------------------------------------------------
# 1. git and git-lfs must exist before anything else can work
# ---------------------------------------------------------------------------
Write-Step 'Checking git and git-lfs'

$git = Get-Command git -ErrorAction SilentlyContinue
$gitExe = $null
if ($null -ne $git) {
    $gitExe = $git.Source
    if ([string]::IsNullOrEmpty($gitExe)) { $gitExe = $git.Definition }
    Write-Ok ('git found: ' + $gitExe + ' -- ' + [string] (Get-FirstLine -Exe $gitExe -Arguments @('--version')))
}
else {
    Write-Err 'git not found on PATH. Install Git for Windows (https://git-scm.com/download/win) and re-run.'
}

$gitLfsOk = $false
if ($null -ne $gitExe) {
    $lfsVersion = Get-FirstLine -Exe $gitExe -Arguments @('lfs', 'version')
    if (-not [string]::IsNullOrWhiteSpace($lfsVersion)) {
        $gitLfsOk = $true
        Write-Ok ('git-lfs found: ' + [string] $lfsVersion)
    }
    else {
        Write-Warn 'git-lfs not available. Large binaries (*.so, *.p12) will not round-trip.'
        Write-Warn 'Install it from https://git-lfs.com and re-run this script.'
    }
}

if ($null -eq $gitExe) {
    Write-Host ''
    Write-Host '  Bootstrap stopped: git is a hard requirement.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Git LFS: `git lfs install` is idempotent and writes filter.lfs.* into
#    .git/config for this clone. We deliberately put the hooks in the shared
#    .githooks directory (via core.hooksPath) so git-lfs cannot clobber our own
#    pre-commit/pre-push hooks -- see .githooks/README.md.
# ---------------------------------------------------------------------------
Write-Step 'Initialising Git LFS for this clone'
if ($gitLfsOk) {
    if (Invoke-Native -Exe $gitExe -Arguments @('-C', $RepoRoot, 'lfs', 'install', '--local')) {
        Write-Ok 'git lfs install --local completed'
    }
    else {
        Write-Warn '`git lfs install --local` failed; LFS objects may not resolve.'
    }
}
else {
    Write-Warn 'skipped (git-lfs unavailable)'
}

# ---------------------------------------------------------------------------
# 3. Submodules: third_party/v2rayN is a READ-ONLY reference (GPL-3.0).
#    See CONTRIBUTING.md for the licensing rules that go with it.
# ---------------------------------------------------------------------------
if ($SkipSubmodules) {
    Write-Step 'Submodules skipped (-SkipSubmodules)'
}
else {
    Write-Step 'Updating submodules (depth ' + $Depth + ')'
    $subArgs = @('-C', $RepoRoot, 'submodule', 'update', '--init')
    if ($Recursive) { $subArgs += '--recursive' }
    if ($Depth -gt 0) { $subArgs += @('--depth', [string] $Depth) }
    if (Invoke-Native -Exe $gitExe -Arguments $subArgs) {
        Write-Ok 'submodules up to date'
    }
    else {
        Write-Warn 'submodule update failed. Offline? Re-run later, or use -SkipSubmodules.'
        Write-Warn 'The reference submodule is not required to compile the app.'
    }

    # Report submodule state so the contributor knows what they actually have.
    $subStatus = $null
    try { $subStatus = & $gitExe -C $RepoRoot submodule status 2>&1 } catch { }
    foreach ($line in @($subStatus)) {
        $text = [string] $line
        if ($text.Trim().Length -eq 0) { continue }
        if ($text.StartsWith('-')) {
            Write-Warn ('not initialised: ' + $text.Trim())
        }
        elseif ($text.StartsWith('+')) {
            Write-Warn ('checked out at a different commit than the index: ' + $text.Trim())
        }
        else {
            Write-Ok $text.Trim()
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Delegate the environment report to check-env.ps1
# ---------------------------------------------------------------------------
if ($SkipEnvCheck) {
    Write-Host ''
    Write-Host '  Bootstrap complete (environment check skipped).' -ForegroundColor Green
    if ($script:HardFailure) { exit 1 }
    exit 0
}

Write-Step 'Running the environment check (scripts/check-env.ps1)'
$checkEnv = Join-Path $RepoRoot 'scripts\check-env.ps1'
if (-not (Test-Path -LiteralPath $checkEnv -PathType Leaf)) {
    Write-Err ('missing: ' + $checkEnv)
    exit 1
}

# Prefer PowerShell 7 (pwsh) when present -- it is roughly an order of magnitude
# faster than Windows PowerShell 5.1 for these scripts -- but fall back to the
# default powershell.exe, which always exists on Windows.
# NB: do NOT pipe Invoke-Native to Out-Null here -- the child's report is the
# whole point of this step, and Out-Null would swallow it.
function Resolve-Pwsh {
    $onPath = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $onPath) { return $onPath.Source }
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $null = $candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $null = $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe'))
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

$checkExit = 1
$pwshExe = Resolve-Pwsh
if ($null -ne $pwshExe) {
    $null = Invoke-Native -Exe $pwshExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checkEnv, '-RepoRoot', $RepoRoot)
    $checkExit = $LASTEXITCODE
}
else {
    $null = Invoke-Native -Exe 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checkEnv, '-RepoRoot', $RepoRoot)
    $checkExit = $LASTEXITCODE
}

Write-Host ''
if ($checkExit -eq 0) {
    Write-Host '  Bootstrap complete. The environment check passed.' -ForegroundColor Green
}
else {
    Write-Host '  Bootstrap finished, but the environment check reported hard failures.' -ForegroundColor Red
    Write-Host '  Fix the [FAIL] lines above, then re-run scripts/bootstrap.ps1.' -ForegroundColor Red
}

if ($script:HardFailure) { exit 1 }
exit $checkExit
