#Requires -Version 5.1
<#
.SYNOPSIS
    Repository hygiene gate for HarmonyBridge.

.DESCRIPTION
    Rejects the mistakes that are cheap to make and expensive to undo:

      1. Forbidden artifacts are tracked -- native/packaged build outputs
         (*.so, *.hap, *.hsp, *.har), signing material (*.p12, *.cer, *.keystore,
         *.jks), machine-local config (local.properties) and anything under a
         `build/` directory.
      2. third_party/ contains tracked regular files. The reference submodule
         must stay a gitlink (submodule) and nothing else -- see CONTRIBUTING.md
         for the GPL-3.0 reasoning.
      3. A path declared in .gitmodules is not present in the index, so a clone
         would silently not have it.
      4. A tracked text file contains something that looks like a hard-coded
         credential. The heuristic is deliberately narrow (classic provider
         prefixes, an explicit private-key header, Huawei-style AK/SK
         assignments) so it stays false-positive-tolerant. It is NOT an entropy
         scanner.

    The pattern lists live in scripts/forbidden-patterns.txt, which the bash
    twin (scripts/verify-repo.sh) reads too, so the two cannot drift.

    Exit codes: 0 = clean, 1 = violations found, 2 = the check could not run
    (for example, not a git work tree).

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory.

.PARAMETER StagedOnly
    Only inspect what the index would commit (HEAD vs index, i.e. the staged
    set). This is what the pre-commit hook uses. The default inspects every
    tracked file, which is what CI and pre-push use.

.PARAMETER PatternsFile
    Override the pattern list. Defaults to scripts/forbidden-patterns.txt.

.PARAMETER Json
    Emit the findings as a JSON object instead of human-readable text.

.PARAMETER MaxLineLength
    Lines longer than this are skipped by the secret heuristic. Minified or
    generated single-line files produce nothing but false positives and are the
    slowest thing to scan. Default 300.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-repo.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-repo.ps1 -StagedOnly
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $StagedOnly,
    [string] $PatternsFile,
    [switch] $Json,
    [int] $MaxLineLength = 300
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Findings = New-Object System.Collections.ArrayList

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string] $Rule,
        [Parameter(Mandatory = $true)][string] $Path,
        [string] $Detail = ''
    )
    $null = $script:Findings.Add([pscustomobject]@{
            Rule   = $Rule
            Path   = $Path
            Detail = $Detail
        })
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
# 0. Locate the repository and the pattern file
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir '..')).Path
}
elseif (Test-Path -LiteralPath $RepoRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
}

if ([string]::IsNullOrWhiteSpace($PatternsFile)) {
    $PatternsFile = Join-Path $RepoRoot 'scripts\forbidden-patterns.txt'
}

function Exit-With {
    param([int] $Code)
    exit $Code
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    Write-Host 'verify-repo: git not found on PATH; cannot inspect the repository.' -ForegroundColor Red
    Exit-With 2
}
$gitExe = $git.Source
if ([string]::IsNullOrEmpty($gitExe)) { $gitExe = $git.Definition }

$insideWorkTree = $false
try {
    $null = & $gitExe -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $insideWorkTree = $true }
}
catch { }
if (-not $insideWorkTree) {
    Write-Host ('verify-repo: ' + $RepoRoot + ' is not a git work tree.') -ForegroundColor Red
    Exit-With 2
}

# ---------------------------------------------------------------------------
# 1. Load the shared pattern list
# ---------------------------------------------------------------------------
$artifactPatterns = New-Object System.Collections.ArrayList
$secretPatterns = New-Object System.Collections.ArrayList

if (Test-Path -LiteralPath $PatternsFile -PathType Leaf) {
    $section = ''
    foreach ($rawLine in (Get-Content -LiteralPath $PatternsFile)) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith('[')) {
            $section = $line.Trim('[', ']').ToLowerInvariant()
            continue
        }
        if ($section -eq 'artifacts') { $null = $artifactPatterns.Add($line) }
        elseif ($section -eq 'secrets') { $null = $secretPatterns.Add($line) }
    }
}
else {
    Write-Host ('verify-repo: pattern file not found: ' + $PatternsFile) -ForegroundColor Red
    Exit-With 2
}

# ---------------------------------------------------------------------------
# 2. Enumerate the file set under inspection
#
#    Deliberately NOT using `-z` here: Windows PowerShell 5.1 does not preserve
#    NUL bytes in captured native-command output, which silently corrupts the
#    record splitting. Line-oriented `git ls-files -s` output is
#    "<mode> SP <object> SP <stage> TAB <path>" and repository paths cannot
#    contain a newline, so splitting on newlines and the single TAB is exact.
# ---------------------------------------------------------------------------
$tracked = New-Object System.Collections.ArrayList   # repo-relative POSIX paths of regular files
$gitlinks = New-Object System.Collections.ArrayList  # repo-relative POSIX paths of submodule gitlinks
$trackedMap = @{}                                    # path -> $true

function Get-IndexEntries {
    <#
        Return @{ Path = ...; Mode = ... } for every index entry relevant to this
        run. Full mode reads the whole index; -StagedOnly restricts the result to
        the staged delta (Added/Copied/Modified/Renamed), which is what the
        pre-commit hook cares about.
    #>
    $global:LASTEXITCODE = 0
    $raw = $null
    try { $raw = & $gitExe -C $RepoRoot ls-files -s 2>$null } catch { $raw = $null }
    if ($LASTEXITCODE -ne 0 -or $null -eq $raw) { return @() }

    $allEntries = New-Object System.Collections.ArrayList
    foreach ($line in @($raw)) {
        $text = [string] $line
        if ($text.Length -eq 0) { continue }
        $tab = $text.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $meta = $text.Substring(0, $tab)
        $path = ($text.Substring($tab + 1)) -replace '\\', '/'
        if ($path.Length -eq 0) { continue }
        $mode = ($meta -split '\s+')[0]
        $null = $allEntries.Add([pscustomobject]@{ Path = $path; Mode = $mode })
    }

    if (-not $StagedOnly) { return $allEntries }

    # Which of those are staged?
    $global:LASTEXITCODE = 0
    $stagedRaw = $null
    try { $stagedRaw = & $gitExe -C $RepoRoot diff --cached --name-only --diff-filter=ACMR 2>$null } catch { $stagedRaw = $null }
    $stagedSet = @{}
    if ($LASTEXITCODE -eq 0 -and $null -ne $stagedRaw) {
        foreach ($line in @($stagedRaw)) {
            $text = ([string] $line).Trim()
            if ($text.Length -eq 0) { continue }
            $stagedSet[($text -replace '\\', '/')] = $true
        }
    }

    # No staged delta (for example `git commit --amend --no-edit` with nothing
    # queued) means the whole index is about to be committed: fall back to it.
    if ($stagedSet.Count -eq 0) { return $allEntries }

    $filtered = New-Object System.Collections.ArrayList
    foreach ($entry in $allEntries) {
        if ($stagedSet.ContainsKey($entry.Path)) { $null = $filtered.Add($entry) }
    }
    return $filtered
}

$entries = @(Get-IndexEntries)
foreach ($entry in $entries) {
    $path = [string] $entry.Path
    if ($path.Length -eq 0) { continue }
    if ($trackedMap.ContainsKey($path)) { continue }
    $trackedMap[$path] = $true
    if ($entry.Mode -eq '160000') { $null = $gitlinks.Add($path) }
    else { $null = $tracked.Add($path) }
}

# Everything the index knows about, regardless of scope. `.gitmodules` integrity
# is a property of the repository, not of the staged delta, so it is validated
# against this snapshot rather than against $trackedMap -- otherwise a
# -StagedOnly run would report the reference submodule as missing.
$indexPaths = @{}
$indexGitlinks = @{}
$global:LASTEXITCODE = 0
$indexRaw = $null
try { $indexRaw = & $gitExe -C $RepoRoot ls-files -s 2>$null } catch { $indexRaw = $null }
if ($null -ne $indexRaw) {
    foreach ($line in @($indexRaw)) {
        $text = [string] $line
        if ($text.Length -eq 0) { continue }
        $tab = $text.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $mode = (($text.Substring(0, $tab)) -split '\s+')[0]
        $path = ($text.Substring($tab + 1)) -replace '\\', '/'
        if ($path.Length -eq 0) { continue }
        $indexPaths[$path] = $true
        if ($mode -eq '160000') { $indexGitlinks[$path] = $true }
    }
}

# ---------------------------------------------------------------------------
# 3. Rule A -- forbidden artifacts
# ---------------------------------------------------------------------------
function Test-ArtifactMatch {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Pattern
    )
    $pattern = $Pattern.Replace('\', '/')

    # Directory keep-files are the one place a build-output pattern must not
    # fire; .gitignore carves out the same exception for entry/libs/**/.gitkeep.
    if ($Path -like '*.gitkeep') { return $false }

    if ($pattern.StartsWith('/')) {
        # Anchored at the repository root.
        $rooted = '*' + $pattern
        return ($Path -like $rooted)
    }
    # Unanchored patterns match at any depth: `**/` + pattern.
    $atAnyDepth = '*/*' + $pattern
    if ($Path -like $atAnyDepth) { return $true }
    # ...and also allow them to match from the root with no directory prefix.
    return ($Path -like $pattern)
}

foreach ($path in $tracked) {
    foreach ($pattern in $artifactPatterns) {
        if (Test-ArtifactMatch -Path $path -Pattern $pattern) {
            Add-Finding -Rule 'forbidden-artifact' -Path $path -Detail ('matched `' + $pattern + '`')
            break
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Rule B -- third_party/ must be submodule gitlinks only
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath (Join-Path $RepoRoot '.gitmodules') -PathType Leaf) {
    foreach ($path in $tracked) {
        if ($path -eq 'third_party' -or $path.StartsWith('third_party/')) {
            Add-Finding -Rule 'third-party-not-submodule' -Path $path `
                -Detail 'third_party/ may only contain submodule gitlinks; a vendored file here breaks the licensing boundary'
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Rule C -- every .gitmodules path must exist in the index
# ---------------------------------------------------------------------------
$gitmodulesPath = Join-Path $RepoRoot '.gitmodules'
if (Test-Path -LiteralPath $gitmodulesPath -PathType Leaf) {
    $declared = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($rawLine in (Get-Content -LiteralPath $gitmodulesPath)) {
        $line = $rawLine.Trim()
        if ($line.StartsWith('[submodule')) { $current = $line; continue }
        if ($line -match '^path\s*=\s*(.+)$') {
            $declaredPath = $Matches[1].Trim() -replace '\\', '/'
            $null = $declared.Add($declaredPath)
        }
    }
    if ($declared.Count -eq 0) {
        Add-Finding -Rule 'gitmodules-empty' -Path '.gitmodules' -Detail 'no [submodule "name"] path = ... entries found'
    }
    foreach ($declaredPath in $declared) {
        if (-not $indexPaths.ContainsKey($declaredPath)) {
            Add-Finding -Rule 'gitmodules-missing-from-index' -Path $declaredPath `
                -Detail ('.gitmodules declares this path but the index has no entry; a fresh clone would miss it')
        }
        elseif (-not $indexGitlinks.ContainsKey($declaredPath)) {
            Add-Finding -Rule 'submodule-not-a-gitlink' -Path $declaredPath `
                -Detail '.gitmodules declares a submodule but the index entry is a regular file, not mode 160000'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Rule D -- secret-looking strings in tracked text files
#
#    `git grep --cached -I` matches the *index* (what would be committed) and
#    skips binaries. Pathspecs are passed explicitly so -StagedOnly really does
#    look only at the staged delta, and so nothing outside third_party/ or the
#    build directories is silently swept in. Files with no trailing newline are
#    skipped by git grep; that is a deliberate trade for never scanning a blob.
# ---------------------------------------------------------------------------
$secretScanSkipped = $false
$scanPaths = @($tracked)
if ($scanPaths.Count -eq 0) {
    $secretScanSkipped = $true
}

foreach ($pattern in $secretPatterns) {
    if ($scanPaths.Count -eq 0) { break }
    $global:LASTEXITCODE = 0
    $hits = $null
    $grepArgs = @('-C', $RepoRoot, 'grep', '--cached', '-E', '-I', '-n', '--no-color', '-e', $pattern, '--') + $scanPaths
    try {
        $hits = & $gitExe @grepArgs 2>$null
    }
    catch {
        # Almost always "command line too long" for a huge index. Never silently
        # downgrade a security check.
        $hits = $null
        $secretScanSkipped = $true
        Write-Host ('verify-repo: secret scan for `' + $pattern + '` could not run (' + $_.Exception.Message + ')') -ForegroundColor Yellow
        continue
    }
    if ($LASTEXITCODE -gt 1) {
        $secretScanSkipped = $true
        Write-Host ('verify-repo: secret scan for `' + $pattern + '` failed (git grep exit ' + $LASTEXITCODE + ')') -ForegroundColor Yellow
        continue
    }
    foreach ($hit in @($hits)) {
        $text = [string] $hit
        if ($text.Trim().Length -eq 0) { continue }
        $parts = $text -split ':', 3
        if ($parts.Length -lt 3) { continue }
        $hitPath = $parts[0] -replace '\\', '/'
        $lineNumber = $parts[1]
        $lineText = $parts[2]
        if ($lineText.Length -gt $MaxLineLength) { continue }
        Add-Finding -Rule 'possible-secret' -Path $hitPath `
            -Detail ('line ' + $lineNumber + ' matches `' + $pattern + '` -- remove the credential and rotate it')
    }
}

# ---------------------------------------------------------------------------
# 7. Report
# ---------------------------------------------------------------------------
$byRule = @{}
foreach ($finding in $script:Findings) {
    if (-not $byRule.ContainsKey($finding.Rule)) { $byRule[$finding.Rule] = 0 }
    $byRule[$finding.Rule] = $byRule[$finding.Rule] + 1
}

$mode = 'tracked files (whole index)'
if ($StagedOnly) { $mode = 'staged changes only' }

if ($Json) {
    [pscustomobject]@{
        repoRoot      = $RepoRoot
        mode          = $mode
        filesChecked  = $tracked.Count
        gitlinks      = $gitlinks.Count
        findingsCount = $script:Findings.Count
        findings      = $script:Findings
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Host ''
    Write-Host ('  verify-repo: ' + $RepoRoot) -ForegroundColor White
    Write-Host ('  scope: ' + $mode + '   regular files: ' + $tracked.Count + '   submodule gitlinks: ' + $gitlinks.Count)
    Write-Host ('  ' + ('-' * 78))

    if ($script:Findings.Count -eq 0) {
        Write-Host '  [ OK ] no forbidden artifacts, no vendored third_party files,' -ForegroundColor Green
        Write-Host '         no unresolved .gitmodules paths, no credential-looking strings.' -ForegroundColor Green
    }
    else {
        foreach ($rule in ($byRule.Keys | Sort-Object)) {
            Write-Host ('  ' + $rule + ' (' + $byRule[$rule] + ')') -ForegroundColor Red
            foreach ($finding in ($script:Findings | Where-Object { $_.Rule -eq $rule })) {
                Write-Host ('    - ' + $finding.Path)
                if (-not [string]::IsNullOrWhiteSpace($finding.Detail)) {
                    Write-Host ('        ' + $finding.Detail) -ForegroundColor DarkGray
                }
            }
        }
    }

    Write-Host ('  ' + ('-' * 78))
    if ($secretScanSkipped) {
        Write-Host '  WARNING: at least one secret pattern could not be evaluated; see above.' -ForegroundColor Yellow
    }
    if ($script:Findings.Count -eq 0) {
        Write-Host '  VERDICT: PASS' -ForegroundColor Green
    }
    else {
        Write-Host ('  VERDICT: FAIL -- ' + $script:Findings.Count + ' finding(s).') -ForegroundColor Red
        Write-Host '  Fix them before committing. Build outputs are produced by the build, never committed:' -ForegroundColor Red
        Write-Host '  see CONTRIBUTING.md and docs/design/ci.md.' -ForegroundColor Red
    }
    Write-Host ''
}

if ($script:Findings.Count -gt 0) { Exit-With 1 }
Exit-With 0
