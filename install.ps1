#Requires -Version 5.1
<#
.SYNOPSIS
    Install the DSH integration layer for the TwelveTake REAPER MCP server.

.DESCRIPTION
    Fetches the upstream REAPER MCP project, patches its Lua bridge so the mailbox
    honours REAPER_BRIDGE_DIR, builds a private virtualenv for the Python server,
    and deploys the bridge, the JSFX analyzer and an autostart hook into REAPER's
    resource directory. Idempotent: safe to re-run to upgrade.

    Nothing is vendored in this repository -- the upstream halves are fetched at
    install time, so a new upstream release only needs a re-run unless the patch
    anchor moved (the patcher fails loudly if it did).

.PARAMETER InstallDir
    Where the server, driver and venv live. Default: ~/.dsh/tools/reaper-mcp

.PARAMETER Ref
    Upstream branch or tag to install. Default: main

.PARAMETER IndexUrl
    PyPI index used for the mcp SDK. Default: the Aliyun mirror.

.EXAMPLE
    ./install.ps1
.EXAMPLE
    ./install.ps1 -InstallDir D:\tools\reaper-mcp -Ref v1.10.1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $HOME ".dsh\tools\reaper-mcp"),
    [string]$RepoUrl    = "https://github.com/TwelveTake-Studios/reaper-mcp.git",
    [string]$Ref        = "main",
    [string]$Python     = "python",
    [string]$IndexUrl   = "https://mirrors.aliyun.com/pypi/simple",
    [switch]$SkipReaper
)

$ErrorActionPreference = "Stop"
function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }

# --- 0. prerequisites ------------------------------------------------------
foreach ($exe in @("git")) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$exe not found on PATH" }
}
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) { throw "$Python not found on PATH" }

$repoRoot = $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("reaper-mcp-" + [guid]::NewGuid().ToString("N"))

# --- 1. fetch upstream -----------------------------------------------------
Step "Fetching upstream ($RepoUrl @ $Ref)"
git clone --quiet --depth 1 --branch $Ref $RepoUrl $tmp
if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

Step "Installing server files into $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
try {
    foreach ($f in @("reaper_mcp_server.py", "requirements.txt", "twelvetake_mcp_analyzer.jsfx")) {
        Copy-Item (Join-Path $tmp $f) (Join-Path $InstallDir $f) -Force
    }
    # Keep the pristine copy so a later re-patch or a diff stays readable.
    Copy-Item (Join-Path $tmp "reaper_mcp_bridge.lua") (Join-Path $InstallDir "reaper_mcp_bridge.upstream.lua") -Force
    Copy-Item (Join-Path $tmp "reaper_mcp_bridge.lua") (Join-Path $InstallDir "reaper_mcp_bridge.lua") -Force
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 2. patch the bridge ---------------------------------------------------
Step "Patching bridge so it honours REAPER_BRIDGE_DIR"
& $Python (Join-Path $repoRoot "apply_bridge_patch.py") (Join-Path $InstallDir "reaper_mcp_bridge.lua")
if ($LASTEXITCODE -ne 0) { throw "bridge patch failed -- upstream changed the mailbox setup, inspect apply_bridge_patch.py" }

# --- 3. venv ---------------------------------------------------------------
Step "Creating virtualenv and installing the mcp SDK"
$venv = Join-Path $InstallDir ".venv"
if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) { & $Python -m venv $venv }
$py = Join-Path $venv "Scripts\python.exe"
& $py -m pip install --quiet --no-cache-dir --disable-pip-version-check `
    -i $IndexUrl -r (Join-Path $InstallDir "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
Copy-Item (Join-Path $repoRoot "rmcp.py") (Join-Path $InstallDir "rmcp.py") -Force

# --- 4. deploy into REAPER -------------------------------------------------
if (-not $SkipReaper) {
    $res = Join-Path $env:APPDATA "REAPER"
    if (-not (Test-Path $res)) {
        Write-Warning "REAPER resource directory not found at $res -- skipping REAPER deployment. Run REAPER once, then re-run with -SkipReaper:`$false."
    } else {
        $scripts = Join-Path $res "Scripts"
        $fxDir  = Join-Path $res "Effects\TwelveTake"
        New-Item -ItemType Directory -Force -Path $scripts, $fxDir | Out-Null

        $target = Join-Path $scripts "reaper_mcp_bridge.lua"
        if (Test-Path $target) {
            Copy-Item $target "$target.bak" -Force
        }
        Copy-Item (Join-Path $InstallDir "reaper_mcp_bridge.lua") $target -Force
        Copy-Item (Join-Path $InstallDir "twelvetake_mcp_analyzer.jsfx") $fxDir -Force

        $startup = Join-Path $scripts "__startup.lua"
        $marker  = "DSH reaper-mcp bridge autostart"
        $existing = if (Test-Path $startup) { Get-Content -Raw $startup } else { "" }
        if ($existing -notmatch [regex]::Escape($marker)) {
            if ($existing) { Copy-Item $startup "$startup.bak" -Force }
            $block = @"

-- <<< $marker >>>
-- Added by dsh-reaper-mcp. Delete this block to stop the bridge starting with REAPER.
local dsh_bridge = reaper.GetResourcePath() .. "/Scripts/reaper_mcp_bridge.lua"
if reaper.file_exists(dsh_bridge) then dofile(dsh_bridge) end
-- <<< $marker >>>
"@
            Add-Content -Path $startup -Value $block -NoNewline
            Note "autostart block appended to $startup"
        } else {
            Note "autostart block already present"
        }

        # The SKILL.md makes future agent sessions discover the tool by themselves.
        $skillDir = Join-Path $HOME ".dsh\skills\reaper-mcp"
        New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
        Copy-Item (Join-Path $repoRoot "skill\SKILL.md") (Join-Path $skillDir "SKILL.md") -Force
        Step "Deployed bridge, JSFX analyzer, autostart hook and skill"
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  driver : $InstallDir\rmcp.py"
Write-Host "  python : $InstallDir\.venv\Scripts\python.exe"
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. If REAPER is running, load the bridge now (it autostarts next launch):"
Write-Host "     Actions -> New action -> Load ReaScript -> $env:APPDATA\REAPER\Scripts\reaper_mcp_bridge.lua -> Run"
Write-Host "  2. Verify:"
Write-Host "     & '$InstallDir\.venv\Scripts\python.exe' '$InstallDir\rmcp.py' get_project_summary"
