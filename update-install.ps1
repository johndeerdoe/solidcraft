<#
.SYNOPSIS
  Build SolidCraft from the testing branch and update the installed copy in place.

.DESCRIPTION
  Local only: this script never fetches, pulls or pushes. It builds whatever is in the
  testing branch's working tree right now, including uncommitted edits.

  1. Checks you are on the testing branch.
  2. Builds solidcraft.exe, solidcraft-cli.exe and solvecraft-cli.exe in release mode
     (static C runtime, same as the official packaging script).
  3. Closes any running SolidCraft, backs up the installed .exe files to *.bak,
     and copies the new ones into the install folder (asks for admin once).

  Needs: Rust (rustup, MSVC toolchain) and Visual Studio Build Tools with the
  "Desktop development with C++" workload.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\update-install.ps1
  powershell -ExecutionPolicy Bypass -File .\update-install.ps1 -Restore      # put the .bak files back
#>
param(
  [string] $InstallDir = 'C:\Program Files\SolidCraft',
  [switch] $Restore
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Exes = @('solidcraft.exe', 'solidcraft-cli.exe', 'solvecraft-cli.exe')
$Target = 'x86_64-pc-windows-msvc'

function Invoke-Native([string] $What, [scriptblock] $Block) {
  Write-Host "==> $What" -ForegroundColor Cyan
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

# Copies files into the install folder, elevating if this shell isn't admin.
function Install-Files([string[]] $Lines) {
  Get-Process solidcraft, solidcraft-cli -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Closing running $($_.ProcessName) (pid $($_.Id))"
    $_ | Stop-Process -Force
  }
  Start-Sleep -Milliseconds 500
  $script = ($Lines -join "`n")
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Invoke-Expression $script
  } else {
    $tmp = Join-Path $env:TEMP 'solidcraft-install-step.ps1'
    Set-Content -Path $tmp -Value "`$ErrorActionPreference='Stop'`n$script" -Encoding UTF8
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru `
      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`""
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) { throw "Install step failed (exit code $($p.ExitCode))" }
  }
}

if (-not (Test-Path $InstallDir)) { throw "Install folder not found: $InstallDir" }

if ($Restore) {
  $lines = foreach ($exe in $Exes) {
    "if (Test-Path '$InstallDir\$exe.bak') { Copy-Item -Force '$InstallDir\$exe.bak' '$InstallDir\$exe' }"
  }
  Install-Files $lines
  Write-Host 'Restored the backed-up .exe files.' -ForegroundColor Green
  exit 0
}

# ---- Prerequisites -------------------------------------------------------------------------------
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
  throw "cargo not found. Install Rust first:  winget install Rustlang.Rustup   (then open a new terminal)"
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasMsvc = (Test-Path $vswhere) -and
  (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $hasMsvc) {
  throw ("MSVC C++ build tools not found. Install them with:`n" +
    '  winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"')
}

# ---- Source ---------------------------------------------------------------------------------------
Push-Location $Root
try {
  $branch = (git rev-parse --abbrev-ref HEAD).Trim()
  if ($branch -ne 'testing') { throw "You're on '$branch'. Switch to testing first:  git switch testing" }
  $commit = (git log -1 --format='%h %s').Trim()
  if (git status --porcelain --untracked-files=no) { $commit += ' (+ uncommitted changes)' }
  $version = (Select-String -Path (Join-Path $Root 'Cargo.toml') -Pattern '^version\s*=\s*"([^"]+)"' |
    Select-Object -First 1).Matches[0].Groups[1].Value
  Write-Host "Building SolidCraft $version from $commit" -ForegroundColor Cyan

  # ---- Build --------------------------------------------------------------------------------------
  Invoke-Native 'rustup target' { rustup target add $Target }
  $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = '-C target-feature=+crt-static'
  Invoke-Native 'cargo build --release' {
    cargo build --release --locked -p solidcraft -p solidcraft-cli --target $Target
  }
} finally {
  Pop-Location
}

$TargetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Root 'target' }
$Bin = Join-Path $TargetDir "$Target\release"
foreach ($exe in $Exes) {
  if (-not (Test-Path (Join-Path $Bin $exe))) { throw "Build output missing: $Bin\$exe" }
}

# ---- Install --------------------------------------------------------------------------------------
$lines = foreach ($exe in $Exes) {
  "if (Test-Path '$InstallDir\$exe') { Copy-Item -Force '$InstallDir\$exe' '$InstallDir\$exe.bak' }"
  "Copy-Item -Force '$Bin\$exe' '$InstallDir\$exe'"
}
Install-Files $lines

Write-Host "Installed SolidCraft $version ($commit) to $InstallDir" -ForegroundColor Green
Write-Host "Old files kept as *.bak. Undo with: .\update-install.ps1 -Restore"
& (Join-Path $InstallDir 'solidcraft-cli.exe') --version
