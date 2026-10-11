<#
.SYNOPSIS
    Build and publish a HarmonyBridge release FROM THIS MACHINE, without a
    self-hosted CI runner.

.DESCRIPTION
    `.github/workflows/release.yml` is the canonical path: push a tag, and a
    self-hosted runner does the build. This script is the fallback for when no
    runner is registered -- it performs exactly the same steps locally, in the
    same order, reading the same `scripts/release-metadata.json`, so the two
    paths cannot disagree about artifact names or version rules.

    Steps:
      1. preflight (DevEco Studio, SDK, Java)
      2. validate that the tag agrees with AppScope/app.json5 versionName
      3. ohpm install
      4. hvigorw clean + assembleHap (release mode)
      5. rename the unsigned HAP and write SHA256SUMS.txt
      6. generate RELEASE_NOTES.md with scripts/changelog.mjs
      7. optionally `gh release create`

    Nothing is published unless -Publish is given. -Publish still creates a
    DRAFT by default, and refuses to touch an existing release unless -Force.

.PARAMETER Tag
    The version tag, e.g. v0.1.0. Must match AppScope/app.json5 versionName.

.PARAMETER RepoRoot
    Repository root. Defaults to this script's parent directory.

.PARAMETER OutDir
    Where the renamed HAP and SHA256SUMS.txt are staged.
    Defaults to <repo>\release-out\<tag>.

.PARAMETER Publish
    Create a GitHub Release with gh. Requires an authenticated gh CLI.

.PARAMETER Draft
    Publish as a draft (default: true). Use -Draft:$false to publish live.

.PARAMETER Force
    Allow overwriting an existing release/assets. Without it, an existing
    release is a hard error rather than a silent overwrite.

.PARAMETER SkipBuild
    Reuse an existing HAP in entry/build (for re-running just the publish half).

.EXAMPLE
    pwsh -File scripts/release-local.ps1 -Tag v0.1.0
    # build + stage assets, publish nothing

.EXAMPLE
    pwsh -File scripts/release-local.ps1 -Tag v0.1.0 -Publish -Draft:$false
    # build + create a live GitHub Release
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Tag,

    [string] $RepoRoot,
    [string] $OutDir,

    [switch] $Publish,
    [bool] $Draft = $true,
    [switch] $Force,
    [switch] $SkipBuild
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "=== $Message ==="
}

# Windows PowerShell 5.1 reads files using the ANSI code page (GBK here), which
# garbles the UTF-8 Chinese strings in release-metadata.json and makes
# ConvertFrom-Json fail with a confusing "invalid array" error. Always read
# explicitly as UTF-8.
function Read-Utf8AllText {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Push-Location $RepoRoot
try {
    # -----------------------------------------------------------------------
    # 0. Read the shared release metadata -- never hardcode these names here.
    # -----------------------------------------------------------------------
    $metadataPath = Join-Path $RepoRoot 'scripts\release-metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        throw "release metadata not found: $metadataPath"
    }
    $meta = Read-Utf8AllText -Path $metadataPath | ConvertFrom-Json

    if (-not $OutDir) {
        $OutDir = Join-Path (Join-Path $RepoRoot 'release-out') $Tag
    }
    Write-Host "tag       : $Tag"
    Write-Host "repo root : $RepoRoot"
    Write-Host "staging   : $OutDir"

    # -----------------------------------------------------------------------
    # 1. Paths and environment
    # -----------------------------------------------------------------------
    Write-Step '1/7 preflight'
    $deveco = $env:DEVECO_HOME
    if ([string]::IsNullOrWhiteSpace($deveco)) { $deveco = $meta.build.defaultDevecoHome }
    if (-not (Test-Path -LiteralPath $deveco -PathType Container)) {
        throw "DevEco Studio not found at '$deveco'. Set `$env:DEVECO_HOME and retry."
    }
    $env:DEVECO_HOME = $deveco
    # hvigor needs both of these; omitting them yields 00303217 / 00308018.
    if ([string]::IsNullOrWhiteSpace($env:DEVECO_SDK_HOME)) { $env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk' }
    if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $jbr = Join-Path $deveco 'jbr'
        if (Test-Path -LiteralPath $jbr -PathType Container) { $env:JAVA_HOME = $jbr }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $env:PATH = "$(Join-Path $env:JAVA_HOME 'bin');$env:PATH"
    }
    $preflightLog = Join-Path $env:TEMP 'hb-preflight.log'
    & (Join-Path $RepoRoot 'scripts\release-preflight.ps1') -RepoRoot $RepoRoot -RequireDeveco *> $preflightLog
    $preflightCode = $LASTEXITCODE
    Get-Content -LiteralPath $preflightLog | ForEach-Object { Write-Host $_ }
    if ($preflightCode -ne 0) { throw 'preflight reported the machine is not ready' }
    # The preflight writes PATH repairs to GITHUB_PATH, which only means
    # something under GitHub Actions. Locally, take it from there: hvigor needs
    # `java` on PATH, not just JAVA_HOME (JAVA_HOME alone fails the HAP packaging
    # step with a bare "Error Code: 00308018 Unknown Error").
    $resolvedJava = $env:JAVA_HOME
    if ([string]::IsNullOrWhiteSpace($resolvedJava)) { $resolvedJava = Join-Path $deveco 'jbr' }
    $resolvedJavaBin = Join-Path $resolvedJava 'bin'
    if (Test-Path -LiteralPath $resolvedJavaBin -PathType Container) {
        $env:JAVA_HOME = $resolvedJava
        if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
            $env:PATH = "$resolvedJavaBin;$env:PATH"
            Write-Host "java was not on PATH; added $resolvedJavaBin"
        }
    }

    # -----------------------------------------------------------------------
    # 2. Version agreement (delegated to the same script CI uses)
    # -----------------------------------------------------------------------
    Write-Step '2/7 validate tag against AppScope/app.json5'
    & node (Join-Path $RepoRoot 'scripts\changelog.mjs') --tag $Tag --validate-only
    if ($LASTEXITCODE -ne 0) { throw "version validation failed for tag $Tag" }

    # -----------------------------------------------------------------------
    # 3. Host of the local build
    # -----------------------------------------------------------------------
    if (-not $SkipBuild) {
        Write-Step '3/7 ohpm install'
        & (Join-Path $deveco $meta.build.ohpmRelative) install
        if ($LASTEXITCODE -ne 0) { throw "ohpm install failed with exit code $LASTEXITCODE" }

        Write-Step '4/7 assembleHap (clean first)'
        $hvigor = Join-Path $deveco $meta.build.hvigorRelative
        & $hvigor clean --no-daemon
        if ($LASTEXITCODE -ne 0) { throw "hvigor clean failed with exit code $LASTEXITCODE" }

        $log = Join-Path $env:TEMP 'hb-release-local.log'
        # Do not pipe hvigor through PowerShell: it wraps/truncates lines and
        # destroys the "file:line:col" in error messages (docs/03-环境搭建.md 5.2).
        cmd /c "`"$hvigor`" --mode module -p product=default -p buildMode=$($meta.build.buildMode) $($meta.build.task) $($meta.build.extraArgs) > `"$log`" 2>&1"
        $buildCode = $LASTEXITCODE
        # hvigor writes UTF-8; read it as such or the Chinese diagnostics turn
        # into noise (this repository's scripts run under PowerShell 5.1).
        ((Read-Utf8AllText -Path $log) -replace "\x1b\[[0-9;]*m", '') -split "`r?`n" |
            Where-Object { $_ -match 'BUILD|ERROR|Error Message|CompileArkTS' } |
            ForEach-Object { Write-Host $_ }
        if ($buildCode -ne 0) { throw "assembleHap failed with exit code $buildCode" }
    } else {
        Write-Step '3-4/7 build skipped (-SkipBuild)'
    }

    # -----------------------------------------------------------------------
    # 5. Stage assets
    # -----------------------------------------------------------------------
    Write-Step '5/7 stage the unsigned HAP + SHA256SUMS.txt'
    $source = Join-Path $RepoRoot $meta.paths.unsignedHap
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $found = Get-ChildItem -Path (Join-Path $RepoRoot 'entry\build') -Filter *.hap -Recurse -ErrorAction SilentlyContinue
        if (-not $found) { throw "no HAP found. Expected $($meta.paths.unsignedHap)" }
        $source = $found[0].FullName
        Write-Host "expected path missing; using $source"
    }

    $version = (Select-String -LiteralPath (Join-Path $RepoRoot $meta.version.manifest) -Pattern '"versionName"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value

    $hapName = $meta.artifacts.releaseHapNameTemplate.Replace('{version}', $version)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $hapTarget = Join-Path $OutDir $hapName
    Copy-Item -LiteralPath $source -Destination $hapTarget -Force

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hapTarget).Hash.ToLower()
    # Two spaces, like sha256sum, so `sha256sum -c SHA256SUMS.txt` works.
    "$hash  $hapName" | Set-Content -LiteralPath (Join-Path $OutDir $meta.artifacts.checksumsName) -Encoding ASCII

    $size = (Get-Item -LiteralPath $hapTarget).Length
    Write-Host "HAP      : $hapName ($size bytes)"
    Write-Host "SHA-256  : $hash"

    # -----------------------------------------------------------------------
    # 6. Release notes
    # -----------------------------------------------------------------------
    Write-Step '6/7 generate RELEASE_NOTES.md'
    $notesName = $meta.artifacts.releaseNotesName
    & node (Join-Path $RepoRoot 'scripts\changelog.mjs') --tag $Tag --output (Join-Path $OutDir $notesName)
    if ($LASTEXITCODE -ne 0) { throw 'changelog generation failed' }

    # -----------------------------------------------------------------------
    # 7. Publish (opt-in)
    # -----------------------------------------------------------------------
    if (-not $Publish) {
        Write-Step '7/7 publish skipped (pass -Publish to create a GitHub Release)'
        Write-Host ''
        Write-Host 'Assets staged:'
        Get-ChildItem -LiteralPath $OutDir | ForEach-Object { Write-Host "  $($_.Name)" }
        Write-Host ''
        Write-Host "When ready:"
        Write-Host "  pwsh -File scripts/release-local.ps1 -Tag $Tag -Publish -SkipBuild"
        return
    }

    Write-Step '7/7 publish via gh'
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw 'gh CLI not found; install it or publish the staged assets manually' }

    & gh auth status 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated; run: gh auth login' }

    # Refuse to clobber: a silent overwrite of a published release is not
    # something a convenience script should ever do on its own.
    $existing = & gh release view $Tag --json tagName 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        if (-not $Force) {
            throw "release $Tag already exists. Re-run with -Force to upload assets into it, or choose a new tag."
        }
        Write-Host "release $Tag exists; uploading assets (-Force)"
        & gh release upload $Tag (Join-Path $OutDir $hapName) (Join-Path $OutDir $meta.artifacts.checksumsName) --clobber
        if ($LASTEXITCODE -ne 0) { throw 'gh release upload failed' }
        return
    }

    $ghArgs = @(
        'release', 'create', $Tag,
        '--title', $Tag,
        '--notes-file', (Join-Path $OutDir $notesName)
    )
    if ($Draft) { $ghArgs += '--draft' }
    if ($Tag -match '-') { $ghArgs += '--prerelease' }
    $ghArgs += (Join-Path $OutDir $hapName)
    $ghArgs += (Join-Path $OutDir $meta.artifacts.checksumsName)

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }

    Write-Host ''
    if ($Draft) {
        Write-Host "Draft release created for $Tag. Review it, then publish:"
        Write-Host "  gh release edit $Tag --draft=false"
    } else {
        Write-Host "Published $Tag."
    }
} finally {
    Pop-Location
}
