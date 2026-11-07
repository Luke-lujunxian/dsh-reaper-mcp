#!/usr/bin/env python3
"""rmcp -- command-line driver for the TwelveTake REAPER MCP server.

The upstream project (https://github.com/TwelveTake-Studios/reaper-mcp) ships a
stdio MCP server built on FastMCP. DeepSeek Harness has no generic MCP-client
plugin, so this script imports that very same server module and calls its tool
functions directly: same code, same file-bridge protocol, no MCP transport in
between, all 187 tools reachable from one shell command.

Nothing here depends on the current working directory, and nothing is tied to a
particular agent workspace. The mailbox is REAPER's standard
Scripts/mcp_bridge_data directory unless REAPER_BRIDGE_DIR is set (or
--bridge-dir is passed); the Lua bridge honours the same variable, so both
halves can be pointed somewhere else together.

Usage
  rmcp --list                        list every tool, one line each
  rmcp --schema get_track            show one tool's parameters
  rmcp get_track_count               call a tool with no arguments
  rmcp insert_track '{"index":0,"name":"Vocals"}'
  rmcp --bridge-dir /tmp/mailbox get_track_count

Exit codes: 0 ok, 1 usage error, 2 unknown tool or bad arguments. A tool that
returns {"ok": false, ...} still exits 0 -- read the payload.
"""

import argparse
import asyncio
import inspect
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

sys.path.insert(0, str(HERE))
import reaper_mcp_server as srv  # noqa: E402

# Mailbox directory: REAPER_BRIDGE_DIR wins when set, otherwise the server's own
# platform default -- which is exactly what the stock bridge script uses
# (Windows: %APPDATA%\REAPER\Scripts\mcp_bridge_data).
BRIDGE_DIR = Path(srv.BRIDGE_DIR)
try:
    BRIDGE_DIR.mkdir(parents=True, exist_ok=True)
except OSError:
    pass


def _json_default(value):
    return str(value)


def list_tools():
    tools = asyncio.run(srv.mcp.list_tools())
    for tool in sorted(tools, key=lambda t: t.name):
        first = (tool.description or "").strip().splitlines()
        print(f"{tool.name:38s} {(first[0] if first else '')[:110]}")


def show_schema(name):
    tools = {t.name: t for t in asyncio.run(srv.mcp.list_tools())}
    tool = tools.get(name)
    if tool is None:
        print(f"unknown tool: {name}", file=sys.stderr)
        return 2
    print(f"# {name}")
    print((tool.description or "").strip())
    print("\n# parameters")
    print(json.dumps(tool.inputSchema, indent=2, ensure_ascii=False))
    return 0


def call(name, args):
    fn = getattr(srv, name, None)
    if fn is None or not callable(fn):
        print(f"unknown tool: {name}", file=sys.stderr)
        return 2
    try:
        if inspect.iscoroutinefunction(fn):
            result = asyncio.run(fn(**args))
        else:
            result = fn(**args)
    except TypeError as exc:
        print(f"bad arguments for {name}: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, ensure_ascii=False, default=_json_default))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("tool", nargs="?")
    parser.add_argument("args", nargs="?")
    parser.add_argument("--list", action="store_true", help="list every tool")
    parser.add_argument("--schema", help="print one tool's description and schema")
    parser.add_argument("--bridge-dir", help="override the mailbox directory")
    ns = parser.parse_args(argv)

    if ns.bridge_dir:
        os.environ["REAPER_BRIDGE_DIR"] = ns.bridge_dir
        srv.BRIDGE_DIR = Path(ns.bridge_dir)
        srv.BRIDGE_DIR.mkdir(parents=True, exist_ok=True)

    if ns.list:
        list_tools()
        return 0
    if ns.schema:
        return show_schema(ns.schema)
    if not ns.tool:
        parser.print_help()
        return 1
    return call(ns.tool, json.loads(ns.args) if ns.args else {})


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
