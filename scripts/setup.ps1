#Requires -Version 5.1
<#
.SYNOPSIS
    One-command full setup for the Kilo monorepo (Windows).
.DESCRIPTION
    Validates prerequisites, configures a same-drive Bun cache (Windows EPERM
    mitigation), ensures git remotes, runs a resilient `bun install` retry loop,
    and finishes with a typecheck.
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
$bunVersion = [version]($bunVersionOutput | Select-Object -First 1)
if ($bunVersion -lt [version]'1.3.9') {
    Write-Warning "Bun $bunVersion found; this repo pins bun@1.3.9 via packageManager. Proceeding, but use >= 1.3.9."
}
Write-Info "Bun $bunVersion at $bunExe"

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
    if ($LASTEXITCODE -ne 0) {
        git -C $RepoRoot remote add $Name $Url
        Write-Info "Added remote $Name -> $Url"
    }
    elseif ($ForkUrl -and $Name -eq 'origin') {
        git -C $RepoRoot remote set-url $Name $Url
        Write-Info "Set remote $Name -> $Url"
    }
    else {
        Write-Info "Remote $Name already set to $existing"
    }
}

Ensure-Remote -Name 'origin' -Url $(if ($ForkUrl) { $ForkUrl } else { (git -C $RepoRoot remote get-url origin 2>$null); if ($LASTEXITCODE -ne 0) { 'https://github.com/<YOU>/kilo.git' } })
Ensure-Remote -Name 'upstream' -Url 'https://github.com/Kilo-Org/kilo.git'

# ---------------------------------------------------------------------------
# 4. bun install with resilient retry loop
# ---------------------------------------------------------------------------
Write-Step "Installing dependencies (up to $MaxInstallAttempts attempts)"

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

# ---------------------------------------------------------------------------
# 5. Typecheck
# ---------------------------------------------------------------------------
Write-Step "Typechecking (bun turbo typecheck)"

& $bunExe turbo typecheck
if ($LASTEXITCODE -ne 0) {
    throw "Typecheck failed."
}

Write-Host "`nSetup complete. Run 'bun dev' to start." -ForegroundColor Green