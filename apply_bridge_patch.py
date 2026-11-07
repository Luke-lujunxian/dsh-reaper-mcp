#!/usr/bin/env python3
"""Turn an upstream reaper_mcp_bridge.lua into the DSH variant, in place.

Why a script instead of a .patch file: the upstream Lua ships with CRLF line
endings, and any diff produced after a newline-normalising round-trip explodes
into an 8000-line whitespace patch. Replacing one anchor line is stable across
upstream versions, keeps the file's own line endings and is idempotent.

What it changes: the bridge resolves its mailbox with
    reaper.GetResourcePath() .. '/Scripts/mcp_bridge_data/'
and ignores REAPER_BRIDGE_DIR, while the Python half documents that variable as
the portable-install override. After this patch both halves honour it, and an
unset variable still resolves to the stock directory.

Usage: apply_bridge_patch.py <path/to/reaper_mcp_bridge.lua>
Exit 0 patched or already patched, 1 anchor missing (upstream changed shape).
"""

import sys
from pathlib import Path

ANCHOR = "local bridge_dir = reaper.GetResourcePath() .. '/Scripts/mcp_bridge_data/'"

NEW_LINES = [
    "-- PATCHED (dsh-reaper-mcp): the mailbox is REAPER_BRIDGE_DIR when that env",
    "-- variable is set, otherwise REAPER's standard Scripts/mcp_bridge_data --",
    "-- identical to stock behaviour when the variable is unset. Both halves of the",
    "-- protocol therefore agree on the directory instead of only the server honouring it.",
    "local bridge_dir = os.getenv('REAPER_BRIDGE_DIR')",
    "  or (reaper.GetResourcePath() .. '/Scripts/mcp_bridge_data/')",
    "if bridge_dir:sub(-1) ~= '/' then bridge_dir = bridge_dir .. '/' end",
]


def main(argv):
    if len(argv) != 1:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    path = Path(argv[0])
    if not path.is_file():
        print(f"not a file: {path}", file=sys.stderr)
        return 2

    # newline='' keeps CRLF exactly as shipped; nothing here rewrites the file.
    with path.open("r", encoding="utf-8", newline="") as fh:
        text = fh.read()

    if "os.getenv('REAPER_BRIDGE_DIR')" in text:
        print(f"already patched: {path}")
        return 0

    eol = "\r\n" if "\r\n" in text else "\n"
    anchor = ANCHOR + eol
    if anchor not in text:
        anchor = ANCHOR  # last line without a trailing newline
        if anchor not in text:
            print(
                "anchor line not found -- upstream changed the bridge's mailbox setup.\n"
                f"expected: {ANCHOR}",
                file=sys.stderr,
            )
            return 1

    text = text.replace(anchor, eol.join(NEW_LINES) + eol, 1)
    with path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    print(f"patched: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
