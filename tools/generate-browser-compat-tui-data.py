#!/usr/bin/env python3
"""Generate a pinned, offline MDN browser compatibility table for the TUI.

Download the npm tarball at SOURCE_URL and pass its path to this script.
The output covers Web APIs and CSS properties (including their subfeatures).
"""

import hashlib
from html.parser import HTMLParser
import io
import json
from pathlib import Path
import re
import sys
import tarfile

VERSION = "8.1.2"
SOURCE_URL = f"https://registry.npmjs.org/@mdn/browser-compat-data/-/browser-compat-data-{VERSION}.tgz"
SOURCE_SHA256 = "6e715c5d769e94ee82994f6a6a2a258d7dc7ecb69913f0c56150cffe8fb71bc7"
OUTPUT = Path(__file__).resolve().parents[1] / "tui/lib/browser-compat-data.zig"
BROWSERS = ("chrome", "firefox", "safari", "edge")


class PlainText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, value):
        self.parts.append(value)

    def handle_starttag(self, tag, attributes):
        if tag in ("br", "p", "li"):
            self.parts.append(" ")

    def text(self):
        return " ".join("".join(self.parts).split())


def clean_note(value):
    if isinstance(value, list):
        return "; ".join(clean_note(part) for part in value)
    parser = PlainText()
    parser.feed(value)
    return parser.text()


def zig_string(value):
    if any(ord(char) < 32 and char != "\n" for char in value):
        raise ValueError(f"control character in {value!r}")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def statement_detail(statement):
    added = statement.get("version_added")
    if added is False:
        parts = ["Not supported"]
    elif added is True or added is None:
        parts = ["Supported; version unknown" if added is True else "Support unknown"]
    elif added == "preview":
        parts = ["Supported in preview"]
    elif added.startswith("≤"):
        parts = [f"Supported by {added[1:]}"]
    else:
        parts = [f"Since {added}"]
    if statement.get("version_last"):
        parts.append(f"last supported version {statement['version_last']}")
    if statement.get("version_removed"):
        parts.append(f"removed in {statement['version_removed']}")
    if statement.get("partial_implementation"):
        parts.append("partial implementation")
    if statement.get("prefix"):
        parts.append(f"prefix {statement['prefix']}")
    if statement.get("alternative_name"):
        parts.append(f"alternative name {statement['alternative_name']}")
    for flag in statement.get("flags", []):
        label = f"{flag['type']} {flag['name']}"
        if flag.get("value_to_set"):
            label += f" = {flag['value_to_set']}"
        parts.append(label)
    if statement.get("notes"):
        parts.append(f"Note: {clean_note(statement['notes'])}")
    result = "; ".join(parts)
    return result if result.endswith((".", "!", "?")) else result + "."


def support_summary(statements):
    current = [item for item in statements if item.get("version_added") is not False and not item.get("version_removed")]
    if not current:
        if any(item.get("version_removed") for item in statements):
            return "Removed"
        return "No" if all(item.get("version_added") is False for item in statements) else "Unknown"
    item = current[0]
    added = item.get("version_added")
    if added is True:
        summary = "Yes, version ?"
    elif added is None:
        summary = "Unknown"
    elif added == "preview":
        summary = "Preview"
    elif added.startswith("≤"):
        summary = added
    else:
        summary = added + "+"
    if any(form.get(key) for form in current for key in ("partial_implementation", "prefix", "alternative_name", "flags", "notes")):
        summary += " *"
    if len(current) > 1:
        summary += f" +{len(current) - 1} forms"
    if len(statements) > len(current):
        summary += " history"
    return summary


def all_features(prefix, node):
    if "__compat" in node:
        yield ".".join(prefix), node["__compat"]
    for key, child in sorted(node.items()):
        if not key.startswith("__") and isinstance(child, dict):
            yield from all_features((*prefix, key), child)


def main(source):
    payload = Path(source).read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError(f"unexpected MDN BCD SHA-256: {digest}")
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        data = json.load(archive.extractfile("package/data.json"))
    if data["__meta"]["version"] != VERSION:
        raise ValueError(f"unexpected dataset version: {data['__meta']}")
    features = [
        *all_features(("api",), data["api"]),
        *all_features(("css", "properties"), data["css"]["properties"]),
    ]
    if len(features) != 13603 or len({path for path, _ in features}) != len(features):
        raise ValueError(f"unexpected feature count: {len(features)}")
    output = [
        "// Generated by tools/generate-browser-compat-tui-data.py. Do not edit by hand.",
        f"// Source: {SOURCE_URL}",
        f"// SHA-256: {SOURCE_SHA256}",
        "// License: CC0-1.0 (MDN browser-compat-data).",
        f"// Dataset timestamp: {data['__meta']['timestamp']}",
        f"pub const snapshot = {zig_string(VERSION)};",
        "pub const Feature = struct {",
        "    path: []const u8,",
        "    summary: [4][]const u8,",
        "    details: [4][]const u8,",
        "};",
        "",
        "pub const features = [_]Feature{",
    ]
    for path, compat in features:
        summaries = []
        details = []
        for browser in BROWSERS:
            value = compat["support"].get(browser)
            statements = value if isinstance(value, list) else [value] if value is not None else []
            if not statements:
                summaries.append("Unknown")
                details.append("No support data.")
            else:
                summaries.append(support_summary(statements))
                details.append("\n".join(statement_detail(item) for item in statements))
        zig_details = [zig_string(item) for item in details]
        output.append(
            f"    .{{ .path = {zig_string(path)}, "
            ".summary = .{ " + ", ".join(map(zig_string, summaries)) + " }, "
            ".details = .{ " + ", ".join(zig_details) + " } },"
        )
    output.extend(("};", ""))
    OUTPUT.write_text("\n".join(output))
    print(f"wrote {len(features)} features to {OUTPUT}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} browser-compat-data-{VERSION}.tgz")
    main(sys.argv[1])
