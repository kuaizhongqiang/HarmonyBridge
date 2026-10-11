#Requires -Version 5.1
<#
.SYNOPSIS
    Install (or uninstall) the HarmonyBridge git hooks.

.DESCRIPTION
    Points `core.hooksPath` at the versioned .githooks/ directory. That is the
    whole installation: nothing is copied into .git/hooks and no file needs the
    executable bit, which is what makes this work identically on Windows
    (Git for Windows runs hooks through its bundled bash), Linux and macOS.

    `git lfs install` also writes hooks into .git/hooks. Keeping ours under
    core.hooksPath means neither one clobbers the other -- see
    .githooks/README.md.

    Re-running is safe and idempotent.

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory.

.PARAMETER Uninstall
    Remove core.hooksPath (restoring Git's default .git/hooks lookup). If a
    previous value was recorded under harmonybridge.savedHooksPath, it is
    restored instead.

.PARAMETER Status
    Only report the current configuration; change nothing.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-hooks.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-hooks.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $Uninstall,
    [switch] $Status
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$hookPath = '.githooks'
$savedKey = 'harmonybridge.savedHooksPath'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
}
elseif (Test-Path -LiteralPath $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

function Invoke-Git {
    <# Run git with output swallowed; return @{ ExitCode = n; Text = '...' }. #>
    param([string[]] $Arguments)
    $global:LASTEXITCODE = 0
    $out = $null
    try { $out = & git @Arguments 2>$null } catch { return @{ ExitCode = 127; Text = '' } }
    $text = ''
    foreach ($line in @($out)) {
        $candidate = [string] $line
        if ($candidate.Trim().Length -gt 0) { $text = $candidate.Trim(); break }
    }
    return @{ ExitCode = $LASTEXITCODE; Text = $text }
}

function Get-GitConfigValue {
    param([string] $Key)
    $result = Invoke-Git -Arguments @('-C', $RepoRoot, 'config', '--local', '--get', $Key)
    if ($result.ExitCode -ne 0) { return '' }
    return $result.Text
}

function Set-GitConfigValue {
    param([string] $Key, [string] $Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return (Invoke-Git -Arguments @('-C', $RepoRoot, 'config', '--local', '--unset', $Key)).ExitCode -eq 0
    }
    return (Invoke-Git -Arguments @('-C', $RepoRoot, 'config', '--local', $Key, $Value)).ExitCode -eq 0
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'install-hooks: git not found on PATH.' -ForegroundColor Red
    exit 2
}

$probe = Invoke-Git -Arguments @('-C', $RepoRoot, 'rev-parse', '--is-inside-work-tree')
if ($probe.ExitCode -ne 0) {
    Write-Host ('install-hooks: ' + $RepoRoot + ' is not a git work tree.') -ForegroundColor Red
    exit 2
}

$current = Get-GitConfigValue -Key 'core.hooksPath'
$saved = Get-GitConfigValue -Key $savedKey

$currentLabel = '(unset -> .git/hooks)'
if (-not [string]::IsNullOrEmpty($current)) { $currentLabel = $current }
$savedLabel = '(none)'
if (-not [string]::IsNullOrEmpty($saved)) { $savedLabel = $saved }

if ($Status) {
    Write-Host ''
    Write-Host ('  repo:            ' + $RepoRoot)
    Write-Host ('  core.hooksPath:  ' + $currentLabel)
    Write-Host ('  saved previous:  ' + $savedLabel)
    Write-Host ''
    exit 0
}

if ($Uninstall) {
    if ([string]::IsNullOrEmpty($current)) {
        Write-Host 'install-hooks: core.hooksPath is already unset; nothing to do.'
        exit 0
    }
    if ([string]::IsNullOrEmpty($saved)) {
        $null = Set-GitConfigValue -Key 'core.hooksPath' -Value ''
        Write-Host 'install-hooks: core.hooksPath removed (Git now uses .git/hooks).' -ForegroundColor Green
    }
    else {
        $null = Set-GitConfigValue -Key 'core.hooksPath' -Value $saved
        Write-Host ('install-hooks: core.hooksPath restored to ' + $saved) -ForegroundColor Green
    }
    $null = Set-GitConfigValue -Key $savedKey -Value ''
    exit 0
}

# --- install ---------------------------------------------------------------
$hooksDir = Join-Path $RepoRoot $hookPath
if (-not (Test-Path -LiteralPath $hooksDir -PathType Container)) {
    Write-Host ('install-hooks: ' + $hooksDir + ' does not exist.') -ForegroundColor Red
    exit 2
}

$missing = @()
foreach ($hook in @('pre-commit', 'commit-msg')) {
    if (-not (Test-Path -LiteralPath (Join-Path $hooksDir $hook) -PathType Leaf)) { $missing += $hook }
}
if ($missing.Count -gt 0) {
    Write-Host ('install-hooks: missing hook file(s): ' + ($missing -join ', ')) -ForegroundColor Yellow
}

# Record the previous value once, so -Uninstall can put it back.
if ([string]::IsNullOrEmpty($saved) -and -not [string]::IsNullOrEmpty($current) -and $current -ne $hookPath) {
    if (Set-GitConfigValue -Key $savedKey -Value $current) {
        Write-Host ('install-hooks: saved the previous core.hooksPath (' + $current + ') for -Uninstall.') -ForegroundColor DarkGray
    }
}

if ($current -eq $hookPath) {
    Write-Host ('install-hooks: already installed (core.hooksPath = ' + $hookPath + ').') -ForegroundColor Green
}
elseif (Set-GitConfigValue -Key 'core.hooksPath' -Value $hookPath) {
    Write-Host ('install-hooks: core.hooksPath = ' + $hookPath) -ForegroundColor Green
}
else {
    Write-Host 'install-hooks: failed to write core.hooksPath into .git/config.' -ForegroundColor Red
    exit 1
}

# --- self-test: prove the hook is reachable, without committing anything ----
Write-Host ''
Write-Host '  Verifying the hooks are wired up:'

function Resolve-GitBash {
    <#
        Find a POSIX shell that can actually see this checkout's paths. On
        Windows `Get-Command bash` usually resolves to the WSL launcher
        (C:\Windows\system32\bash.exe), whose filesystem view is *not* the
        Windows one -- using it here would silently produce a false warning.
        So Git's bundled bash, which understands /d/... paths, wins.
    #>
    $candidates = New-Object System.Collections.ArrayList
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $gitCmd) {
        $gitExePath = $gitCmd.Source
        if ([string]::IsNullOrEmpty($gitExePath)) { $gitExePath = $gitCmd.Definition }
        if (-not [string]::IsNullOrEmpty($gitExePath)) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $gitExePath)
            $null = $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
            $null = $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
        }
    }
    foreach ($guess in @('D:\Git\bin\bash.exe', 'C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
        $null = $candidates.Add($guess)
    }
    $pathBash = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $pathBash) { $null = $candidates.Add($pathBash.Source) }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        # Git for Windows always ships cygpath next to bash.
        $binDir = Split-Path -Parent $candidate
        if ((Test-Path -LiteralPath (Join-Path $binDir 'cygpath.exe')) -or
            (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $binDir) 'usr\bin\cygpath.exe'))) {
            return $candidate
        }
    }
    return $null
}

$bash = Resolve-GitBash
if ($null -eq $bash) {
    Write-Host '    [SKIP] Git for Windows (or any POSIX shell) not found; cannot self-test the hooks here.' -ForegroundColor DarkGray
    Write-Host '           Git runs hooks through its own bash, so they still work under `git commit`.' -ForegroundColor DarkGray
}
else {
    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ('hb-commit-msg-' + [guid]::NewGuid().ToString('N') + '.txt')
    # Absolute path: the hook must be reachable regardless of the shell's cwd.
    $hookScript = (Join-Path $RepoRoot (Join-Path $hookPath 'commit-msg')) -replace '\\', '/'

    # Ask bash itself for the exit code. Capturing $LASTEXITCODE around an
    # invocation that also carries a redirection is unreliable in Windows
    # PowerShell 5.1, so the shell is made to report its own status. The command
    # string uses single quotes on purpose: in a PowerShell double-quoted string
    # `$?` would be expanded by PowerShell (to "True") before bash ever sees it.
    function Get-HookExitCode {
        param([string] $Message)
        Set-Content -LiteralPath $probeFile -Value $Message -Encoding ASCII
        $probeForBash = $probeFile -replace '\\', '/'
        $captured = & $bash -c 'bash "$1" "$2"; echo EXIT:$?' _ $hookScript $probeForBash
        $text = ($captured | Out-String)
        $match = [regex]::Match($text, 'EXIT:(\d+)')
        if ($match.Success) { return [int] $match.Groups[1].Value }
        Write-Host ('    [WARN] could not read the hook exit code (script=' + $hookScript + ' bash=' + $bash + ')') -ForegroundColor DarkGray
        return -1
    }

    try {
        $badExit = Get-HookExitCode -Message 'not a conventional commit'
        if ($badExit -eq 1) {
            Write-Host '    [ OK ] commit-msg rejects a non-conventional message' -ForegroundColor Green
        }
        else {
            Write-Host ('    [WARN] commit-msg returned ' + $badExit + ' for a bad message (expected 1)') -ForegroundColor Yellow
        }

        $goodExit = Get-HookExitCode -Message 'feat(hooks): wire up the conventional commit check'
        if ($goodExit -eq 0) {
            Write-Host '    [ OK ] commit-msg accepts a conventional message' -ForegroundColor Green
        }
        else {
            Write-Host ('    [WARN] commit-msg rejected a valid message (exit ' + $goodExit + ')') -ForegroundColor Yellow
        }

        # git resolves hooks through core.hooksPath; confirm that lookup works
        # from this checkout rather than only that the script is runnable.
        $hookLookup = Invoke-Git -Arguments @('-C', $RepoRoot, 'config', '--local', '--get', 'core.hooksPath')
        if ($hookLookup.Text -eq $hookPath) {
            Write-Host ('    [ OK ] git resolves hooks to ' + $hookPath) -ForegroundColor Green
        }
        else {
            Write-Host '    [WARN] core.hooksPath does not point at .githooks' -ForegroundColor Yellow
        }
    }
    finally {
        if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
Write-Host '  Done. `git commit` now runs .githooks/pre-commit and .githooks/commit-msg.'
Write-Host '  Bypass once with `git commit --no-verify` (CI runs the same gate anyway).'
Write-Host ''
exit 0
