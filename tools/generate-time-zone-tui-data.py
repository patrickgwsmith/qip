#!/usr/bin/env python3
"""Build the time-zone converter's offline table from IANA tzdata 2026d.

Download the archive at SOURCE_URL and pass its path to this script. Requires
`zic`, which compiles the pinned source to TZif before transitions are read.
"""

from bisect import bisect_right
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
import hashlib
import struct
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
from zoneinfo import ZoneInfo

SOURCE_URL = "https://data.iana.org/time-zones/releases/tzdata2026d.tar.gz"
SOURCE_SHA256 = "0cb2aa8e333c3dc049badc42a0c61f21987b8cd44e107fa900bad764aacc7767"
VERSION = "2026d"
START = int(datetime(2020, 1, 1, tzinfo=timezone.utc).timestamp())
END = int(datetime(2038, 1, 1, tzinfo=timezone.utc).timestamp())
DATA_FILES = ("africa", "antarctica", "asia", "australasia", "europe", "northamerica", "southamerica", "etcetera", "backward")
FEATURED = (
    "Australia/Melbourne", "Europe/London", "America/New_York",
    "America/Los_Angeles", "Asia/Tokyo", "Asia/Kolkata",
    "Asia/Singapore", "Pacific/Auckland",
)
OUTPUT = Path(__file__).resolve().parents[1] / "tui/lib/time-zone-data.zig"


def tzif_transitions(payload):
    def block_start(pos, width):
        if payload[pos:pos + 4] != b"TZif":
            raise ValueError("not a TZif file")
        gmtcnt, stdcnt, leapcnt, timecnt, typecnt, charcnt = struct.unpack_from(">6I", payload, pos + 20)
        size = 44 + timecnt * width + timecnt + typecnt * 6 + charcnt + leapcnt * (width + 4) + stdcnt + gmtcnt
        return pos + size, timecnt, typecnt

    second_header, _, _ = block_start(0, 4)
    _, timecnt, typecnt = block_start(second_header, 8)
    position = second_header + 44
    times = struct.unpack_from(f">{timecnt}q", payload, position)
    position += timecnt * 8
    indexes = payload[position:position + timecnt]
    position += timecnt
    offsets = [struct.unpack_from(">i", payload, position + i * 6)[0] for i in range(typecnt)]
    return [(timestamp, offsets[index]) for timestamp, index in zip(times, indexes)]


def offset_at(zone, timestamp):
    instant = datetime.fromtimestamp(timestamp, timezone.utc)
    return int(instant.astimezone(zone).utcoffset().total_seconds())


def zig_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(archive_path):
    archive = Path(archive_path).read_bytes()
    digest = hashlib.sha256(archive).hexdigest()
    if digest != SOURCE_SHA256:
        raise ValueError(f"unexpected tzdata SHA-256: {digest}")

    with TemporaryDirectory(prefix="qip-tzdata-") as temporary:
        source_dir = Path(temporary) / "source"
        compiled_dir = Path(temporary) / "tzif"
        source_dir.mkdir()
        compiled_dir.mkdir()
        with tarfile.open(fileobj=BytesIO(archive), mode="r:gz") as package:
            for name in (*DATA_FILES, "zone.tab"):
                (source_dir / name).write_bytes(package.extractfile(name).read())
        subprocess.run(
            ["zic", "-b", "fat", "-d", str(compiled_dir),
             *(str(source_dir / name) for name in DATA_FILES)],
            check=True,
        )

        zone_countries = {}
        for line in (source_dir / "zone.tab").read_text().splitlines():
            if line and not line.startswith("#"):
                country, _, name, *_ = line.split("\t")
                if name in zone_countries:
                    raise ValueError(f"duplicate zone {name}")
                zone_countries[name] = country
        if len(zone_countries) != 418:
            raise ValueError(f"expected 418 location zones, got {len(zone_countries)}")
        if not all(name in zone_countries for name in FEATURED):
            raise ValueError("featured zone absent from zone.tab")
        names = (*FEATURED, *(name for name in sorted(zone_countries) if name not in FEATURED))

        zones = []
        transitions = []
        for name in names:
            payload = (compiled_dir / name).read_bytes()
            zone = ZoneInfo.from_file(BytesIO(payload), key=name)
            changes = [(START, offset_at(zone, START))]
            for timestamp, offset in tzif_transitions(payload):
                if START < timestamp < END and offset != changes[-1][1]:
                    changes.append((timestamp, offset))
            times = [entry[0] for entry in changes]
            for year in range(2020, 2038):
                for month in range(1, 13):
                    instant = int(datetime(year, month, 15, tzinfo=timezone.utc).timestamp())
                    actual = changes[bisect_right(times, instant) - 1][1]
                    if actual != offset_at(zone, instant):
                        raise ValueError(f"missing transition for {name} at {year}-{month:02d}")
            for index in range(1, len(changes)):
                instant, offset = changes[index]
                if offset_at(zone, instant - 1) != changes[index - 1][1] or offset_at(zone, instant) != offset:
                    raise ValueError(f"incorrect transition for {name} at {instant}")
            zones.append((name, zone_countries[name], len(transitions), len(changes)))
            transitions.extend(changes)

    lines = [
        "// Generated by tools/generate-time-zone-tui-data.py. Do not edit by hand.",
        f"// Source: {SOURCE_URL}",
        f"// Source SHA-256: {SOURCE_SHA256}",
        "// IANA tzdata is public-domain data. Compiled with zic -b fat.",
        "// UTC instants supported: 2020-01-01 through 2037-12-31.",
        f'pub const version = "{VERSION}";',
        "pub const Zone = struct { name: []const u8, country: []const u8, first: u32, count: u32 };",
        "pub const Transition = struct { at: i64, offset: i32 };",
        "pub const zones = [_]Zone{",
    ]
    lines.extend(
        f"    .{{ .name = {zig_string(name)}, .country = {zig_string(country)}, .first = {first}, .count = {count} }},"
        for name, country, first, count in zones
    )
    lines.extend(("};", "pub const transitions = [_]Transition{"))
    lines.extend(f"    .{{ .at = {timestamp}, .offset = {offset} }}," for timestamp, offset in transitions)
    lines.extend(("};", ""))
    OUTPUT.write_text("\n".join(lines))
    print(f"wrote {len(zones)} zones and {len(transitions)} transitions to {OUTPUT}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} tzdata2026d.tar.gz")
    main(sys.argv[1])
