#!/usr/bin/env bash
# Install the DSH integration layer for the TwelveTake REAPER MCP server.
#
# Fetches upstream, patches its Lua bridge so the mailbox honours
# REAPER_BRIDGE_DIR, builds a private virtualenv, and deploys the bridge, the JSFX
# analyzer, an autostart hook and the agent skill. Idempotent: re-run to upgrade.
#
# Works in Git Bash on Windows, macOS and Linux. Override anything with env vars:
#   INSTALL_DIR, REPO_URL, REF, PYTHON, INDEX_URL, SKIP_REAPER=1
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.dsh/tools/reaper-mcp}"
REPO_URL="${REPO_URL:-https://github.com/TwelveTake-Studios/reaper-mcp.git}"
REF="${REF:-main}"
PYTHON="${PYTHON:-python3}"
INDEX_URL="${INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}"
SKIP_REAPER="${SKIP_REAPER:-0}"
MARKER="DSH reaper-mcp bridge autostart"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- platform --------------------------------------------------------------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    command -v cygpath >/dev/null && APPDATA_U="$(cygpath -u "$APPDATA")" || APPDATA_U="${APPDATA//\//}"
    RES="$APPDATA_U/REAPER"
    ;;
  Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
  *)      RES="${XDG_CONFIG_HOME:-$HOME/.config}/REAPER"; [ -d "$RES" ] || RES="$HOME/.reaper" ;;
esac

# --- prerequisites ---------------------------------------------------------
command -v git >/dev/null || die "git not found on PATH"
command -v "$PYTHON" >/dev/null || die "$PYTHON not found on PATH"

# --- 1. fetch upstream -----------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "Fetching upstream ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$TMP/upstream" || die "git clone failed"

log "Installing server files into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
for f in reaper_mcp_server.py requirements.txt twelvetake_mcp_analyzer.jsfx; do
  cp "$TMP/upstream/$f" "$INSTALL_DIR/$f"
done
cp "$TMP/upstream/reaper_mcp_bridge.lua" "$INSTALL_DIR/reaper_mcp_bridge.upstream.lua"
cp "$TMP/upstream/reaper_mcp_bridge.lua" "$INSTALL_DIR/reaper_mcp_bridge.lua"
cp "$HERE/rmcp.py" "$INSTALL_DIR/rmcp.py"

# --- 2. patch the bridge ---------------------------------------------------
log "Patching bridge so it honours REAPER_BRIDGE_DIR"
"$PYTHON" "$HERE/apply_bridge_patch.py" "$INSTALL_DIR/reaper_mcp_bridge.lua" \
  || die "bridge patch failed -- upstream changed the mailbox setup"

# --- 3. venv ---------------------------------------------------------------
log "Creating virtualenv and installing the mcp SDK"
if [ -x "$INSTALL_DIR/.venv/Scripts/python.exe" ]; then
  VPY="$INSTALL_DIR/.venv/Scripts/python.exe"
elif [ -x "$INSTALL_DIR/.venv/bin/python" ]; then
  VPY="$INSTALL_DIR/.venv/bin/python"
else
  "$PYTHON" -m venv "$INSTALL_DIR/.venv"
  if [ -x "$INSTALL_DIR/.venv/Scripts/python.exe" ]; then
    VPY="$INSTALL_DIR/.venv/Scripts/python.exe"
  else
    VPY="$INSTALL_DIR/.venv/bin/python"
  fi
fi
"$VPY" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
  -i "$INDEX_URL" -r "$INSTALL_DIR/requirements.txt" || die "pip install failed"

# --- 4. deploy into REAPER -------------------------------------------------
if [ "$SKIP_REAPER" = "1" ]; then
  note "SKIP_REAPER=1, not touching REAPER"
elif [ ! -d "$RES" ]; then
  note "REAPER resource directory not found at $RES -- run REAPER once, then re-run."
else
  mkdir -p "$RES/Scripts" "$RES/Effects/TwelveTake"
  [ -f "$RES/Scripts/reaper_mcp_bridge.lua" ] && cp "$RES/Scripts/reaper_mcp_bridge.lua" "$RES/Scripts/reaper_mcp_bridge.lua.bak"
  cp "$INSTALL_DIR/reaper_mcp_bridge.lua" "$RES/Scripts/reaper_mcp_bridge.lua"
  cp "$INSTALL_DIR/twelvetake_mcp_analyzer.jsfx" "$RES/Effects/TwelveTake/"

  STARTUP="$RES/Scripts/__startup.lua"
  if [ -f "$STARTUP" ] && grep -qF "$MARKER" "$STARTUP"; then
    note "autostart block already present in $STARTUP"
  else
    [ -f "$STARTUP" ] && cp "$STARTUP" "$STARTUP.bak"
    cat >> "$STARTUP" <<LUA

-- <<< $MARKER >>>
-- Added by dsh-reaper-mcp. Delete this block to stop the bridge starting with REAPER.
local dsh_bridge = reaper.GetResourcePath() .. "/Scripts/reaper_mcp_bridge.lua"
if reaper.file_exists(dsh_bridge) then dofile(dsh_bridge) end
-- <<< $MARKER >>>
LUA
    note "autostart block appended to $STARTUP"
  fi

  mkdir -p "$HOME/.dsh/skills/reaper-mcp"
  cp "$HERE/skill/SKILL.md" "$HOME/.dsh/skills/reaper-mcp/SKILL.md"
  log "Deployed bridge, JSFX analyzer, autostart hook and skill"
fi

cat <<EOF

Done.
  driver : $INSTALL_DIR/rmcp.py
  python : $VPY

Next:
  1. If REAPER is running, load the bridge now (it autostarts next launch):
     Actions -> New action -> Load ReaScript -> <REAPER>/Scripts/reaper_mcp_bridge.lua -> Run
  2. Verify:
     "$VPY" "$INSTALL_DIR/rmcp.py" get_project_summary
EOF
