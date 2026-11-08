#Requires -Version 5.1
<#
.SYNOPSIS
    One-command full setup for the Kilo monorepo (Windows).
.DESCRIPTION
    Validates prerequisites, configures a same-drive Bun cache (Windows EPERM
    mitigation), ensures git remotes, runs a resilient `bun install` retry loop,
    repairs Windows git-symlink placeholders that break typecheck, and finishes
    with a serial (--concurrency=1) typecheck.
.PARAMETER RepoRoot
    Path to the repository root. Defaults to the directory containing this script's parent.
.PARAMETER ForkUrl
    Your fork's git URL to set as `origin`. If not provided, existing origin is left untouched.
.PARAMETER MaxInstallAttempts
    Maximum `bun install` attempts (default 5).
.EXAMPLE
    .\scripts\setup.ps1 -RepoRoot . -ForkUrl "https://github.com/<YOU>/kilo.git"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ForkUrl,
    [int]$MaxInstallAttempts = 5
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RepoRoot -PathType Container)) {
    throw "RepoRoot '$RepoRoot' does not exist or is not a directory."
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 1. Locate Bun and validate version >= 1.3.9
# ---------------------------------------------------------------------------
Write-Step "Checking Bun"

$bunExe = $env:BUN_EXE
if (-not $bunExe) {
    $cmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($cmd) { $bunExe = $cmd.Source }
}
if (-not $bunExe) {
    # Common install locations
    $candidates = @(
        (Join-Path $env:USERPROFILE '.bun\bin\bun.exe'),
        (Join-Path (Split-Path -Parent $RepoRoot) '.tools\bun\bun-windows-x64\bun.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $bunExe = $c; break }
    }
}
if (-not $bunExe -or -not (Test-Path $bunExe)) {
    throw "Bun not found. Install from https://bun.sh (>= 1.3.9) or set `$env:BUN_EXE to the bun.exe path."
}

$bunVersionOutput = & $bunExe --version 2>&1
$versionText = "$($bunVersionOutput | Select-Object -First 1)".Trim()
$bunVersion = $null
if (-not [version]::TryParse(($versionText -split '-')[0], [ref]$bunVersion)) {
    Write-Warning "Could not parse Bun version output '$versionText'; skipping the version check."
}
elseif ($bunVersion -lt [version]'1.3.9') {
    Write-Warning "Bun $bunVersion found; this repo pins bun@1.3.9 via packageManager. Proceeding, but use >= 1.3.9."
}
Write-Info "Bun $versionText at $bunExe"

# ---------------------------------------------------------------------------
# 2. Same-drive Bun cache (Windows EPERM mitigation)
# ---------------------------------------------------------------------------
Write-Step "Configuring Bun cache on the same drive as the repo"

$drive = (Get-Item $RepoRoot).PSDrive.Name
$cacheDir = Join-Path "$drive`:\" '.bun-cache'
$env:BUN_INSTALL_CACHE_DIR = $cacheDir
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
Write-Info "BUN_INSTALL_CACHE_DIR=$env:BUN_INSTALL_CACHE_DIR"

# Optional: suggest a Defender exclusion (requires admin, not applied automatically)
$defender = Get-Command Add-MpPreference -ErrorAction SilentlyContinue
if ($defender) {
    Write-Info "Tip: run as admin to exclude the cache from Defender: Add-MpPreference -ExclusionPath '$cacheDir'"
}

# ---------------------------------------------------------------------------
# 3. Ensure remotes
# ---------------------------------------------------------------------------
Write-Step "Ensuring git remotes"

function Ensure-Remote {
    param([string]$Name, [string]$Url)
    $existing = git -C $RepoRoot remote get-url $Name 2>$null
    if ($LASTEXITCODE -eq 0) {
        if ($ForkUrl -and $Name -eq 'origin' -and $existing -ne $ForkUrl) {
            git -C $RepoRoot remote set-url $Name $ForkUrl
            Write-Info "Set remote $Name -> $ForkUrl"
        }
        else {
            Write-Info "Remote $Name already set to $existing"
        }
        return
    }
    if ($Url) {
        git -C $RepoRoot remote add $Name $Url
        Write-Info "Added remote $Name -> $Url"
    }
    else {
        Write-Warning "Remote '$Name' is not configured and no URL was provided; skipping."
    }
}

Ensure-Remote -Name 'origin' -Url $ForkUrl
Ensure-Remote -Name 'upstream' -Url 'https://github.com/Kilo-Org/kilo.git'

# ---------------------------------------------------------------------------
# 4. bun install with resilient retry loop
# ---------------------------------------------------------------------------
Write-Step "Installing dependencies (up to $MaxInstallAttempts attempts)"

Push-Location $RepoRoot
try {
    $installed = $false
    for ($i = 1; $i -le $MaxInstallAttempts; $i++) {
        Write-Info "Attempt $i of $MaxInstallAttempts..."

        # Clear stuck dot-prefixed temp dirs from a previous failed rename
        Get-ChildItem $env:BUN_INSTALL_CACHE_DIR -Directory -Filter '.*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        & $bunExe install
        if ($LASTEXITCODE -eq 0) {
            Write-Info "bun install succeeded."
            $installed = $true
            break
        }

        Write-Warning "bun install failed (exit $LASTEXITCODE). Cleaning stale cache temp dirs and retrying..."
        # Kill any hung bun (rename-hang side effect)
        Get-Process bun -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if (-not $installed) {
        throw "bun install failed after $MaxInstallAttempts attempts. See output above."
    }

    # -----------------------------------------------------------------------
    # 5. Windows: repair git-symlink placeholders that break typecheck
    # -----------------------------------------------------------------------
    # With core.symlinks=false (the Windows default), git checks symlinks out
    # as plain text files containing the target path. One of them
    # (packages/app/src/custom-elements.d.ts) then fails typecheck with TS1128.
    # Repair it locally and mark it skip-worktree so the repository keeps the
    # original symlink (compatible with upstream) while the working tree works.
    Write-Step "Repairing Windows symlink placeholders (if any)"

    $symlinksEnabled = git -C $RepoRoot config core.symlinks
    if ($symlinksEnabled -ne 'true') {
        $brokenLink = Join-Path $RepoRoot 'packages/app/src/custom-elements.d.ts'
        $linkTarget = Join-Path $RepoRoot 'packages/ui/src/custom-elements.d.ts'
        $linkContent = Get-Content $brokenLink -Raw -ErrorAction SilentlyContinue
        if ($linkContent -and $linkContent -notmatch 'DIFFS_TAG_NAME') {
            Copy-Item $linkTarget $brokenLink -Force
            git -C $RepoRoot update-index --skip-worktree 'packages/app/src/custom-elements.d.ts'
            Write-Info "Copied symlink target over placeholder and marked skip-worktree (local-only; repo stays compatible with upstream)."
        }
        else {
            Write-Info "No symlink placeholder to repair."
        }
    }
    else {
        Write-Info "core.symlinks=true; real symlinks are in use."
    }

    # -----------------------------------------------------------------------
    # 6. Typecheck (serial: parallel tsgo processes OOM on Windows)
    # -----------------------------------------------------------------------
    Write-Step "Typechecking (bun turbo typecheck --concurrency=1)"

    & $bunExe turbo typecheck --concurrency=1
    if ($LASTEXITCODE -ne 0) {
        throw "Typecheck failed."
    }
}
finally {
    Pop-Location
}

Write-Host "`nSetup complete. Run 'bun dev' to start." -ForegroundColor Green
