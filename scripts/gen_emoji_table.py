#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
# ABOUTME: Generates src/engine/emoji_table.zig from Unicode emoji-data.txt.
# ABOUTME: Run via `just gen-emoji-table`; the generated file is checked in.
import pathlib
import re
import urllib.request

VERSION = "18.0.0"
URL = f"https://www.unicode.org/Public/{VERSION}/ucd/emoji/emoji-data.txt"
OUT = pathlib.Path(__file__).resolve().parent.parent / "src/engine/emoji_table.zig"
LINE = re.compile(r"^([0-9A-F]{4,6})(?:\.\.([0-9A-F]{4,6}))?\s*;\s*(\w+)")


def ranges(text: str, prop: str) -> list[list[int]]:
    found = []
    for line in text.splitlines():
        m = LINE.match(line)
        if not m or m.group(3) != prop:
            continue
        lo = int(m.group(1), 16)
        hi = int(m.group(2) or m.group(1), 16)
        found.append([lo, hi])
    found.sort()
    merged: list[list[int]] = []
    for lo, hi in found:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return merged


def zig_array(name: str, rs: list[list[int]]) -> str:
    body = "\n".join(f"    .{{ 0x{lo:04X}, 0x{hi:04X} }}," for lo, hi in rs)
    return f"pub const {name} = [_]Range{{\n{body}\n}};\n"


def main() -> None:
    text = urllib.request.urlopen(URL).read().decode("utf-8")
    presentation = ranges(text, "Emoji_Presentation")
    emoji = ranges(text, "Emoji")
    OUT.write_text(
        "// ABOUTME: Unicode emoji property ranges, generated from emoji-data.txt.\n"
        "// ABOUTME: Regenerate with `just gen-emoji-table`; do not edit by hand.\n\n"
        f'pub const unicode_version = "{VERSION}";\n\n'
        "/// Inclusive code point range, sorted and non-overlapping within each table.\n"
        "pub const Range = [2]u21;\n\n"
        + zig_array("emoji_presentation", presentation)
        + "\n"
        + zig_array("emoji", emoji)
    )
    print(f"wrote {OUT}: {len(presentation)} Emoji_Presentation ranges, {len(emoji)} Emoji ranges")


if __name__ == "__main__":
    main()
