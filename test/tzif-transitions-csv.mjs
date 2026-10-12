import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const qip = join(process.cwd(), "qip");
const component = join(process.cwd(), "application/tzif/tzif-transitions-csv.wasm");
const wasmCounts = join(process.cwd(), "application/wasm/wasm-counts.wasm");

// Builds one TZif header and data block. `timeSize` is 4 for version 1 data
// and 8 for version 2+ data.
function tzifBlock(version, zone, timeSize) {
  const leapcnt = zone.leapcnt ?? 0;
  const counts = [
    zone.isut?.length ?? 0,
    zone.isstd?.length ?? 0,
    leapcnt,
    zone.times.length,
    zone.types.length,
    zone.chars.length,
  ];
  const header = Buffer.alloc(44);
  header.write("TZif", 0, "latin1");
  header[4] = version;
  counts.forEach((count, index) => header.writeUInt32BE(count, 20 + index * 4));
  const times = Buffer.alloc(zone.times.length * timeSize);
  zone.times.forEach((time, index) => {
    if (timeSize === 8) times.writeBigInt64BE(BigInt(time), index * 8);
    else times.writeInt32BE(time, index * 4);
  });
  const types = Buffer.alloc(zone.types.length * 6);
  zone.types.forEach(([utoff, isdst, desigidx], index) => {
    types.writeInt32BE(utoff, index * 6);
    types[index * 6 + 4] = isdst;
    types[index * 6 + 5] = desigidx;
  });
  return Buffer.concat([
    header,
    times,
    Buffer.from(zone.indices),
    types,
    Buffer.from(zone.chars, "latin1"),
    Buffer.alloc(leapcnt * (timeSize + 4)),
    Buffer.from(zone.isstd ?? []),
    Buffer.from(zone.isut ?? []),
  ]);
}

function tzifV2(zone, footer) {
  const v1 = { times: [], indices: [], types: [[0, 0, 0]], chars: "\0" };
  return Buffer.concat([
    tzifBlock(0x32, v1, 4),
    tzifBlock(0x32, zone, 8),
    Buffer.from(footer, "latin1"),
  ]);
}

const newYork = {
  times: [-2717650800, 1710054000, 1730613600],
  indices: [2, 1, 2],
  types: [[-17762, 0, 0], [-14400, 1, 4], [-18000, 0, 8]],
  chars: "LMT\0EDT\0EST\0",
  isstd: [0, 0, 0],
  isut: [0, 0, 0],
};

async function run(bytes) {
  const directory = await mkdtemp(join(tmpdir(), "qip-tzif-"));
  const inputPath = join(directory, "zone.tzif");
  const outputPath = join(directory, "zone.csv");
  await writeFile(inputPath, bytes);
  await execFileAsync(qip, ["run", "-i", inputPath, "-o", outputPath, component]);
  return readFile(outputPath, "utf8");
}

test("tzif-transitions-csv has no indirect calls", async () => {
  const { stdout } = await execFileAsync(qip, ["run", "-i", component, "--", wasmCounts]);
  assert.match(stdout, /^calls_indirect,0$/m);
});

test("tzif-transitions-csv lists version 2 transitions", async () => {
  const csv = await run(tzifV2(newYork, "\nEST5EDT,M3.2.0,M11.1.0\n"));
  assert.equal(
    csv,
    "time,utc,local,utoff,isdst,abbreviation,type\n" +
      ",,,-17762,0,LMT,0\n" +
      "-2717650800,1883-11-18T17:00:00Z,1883-11-18T12:00:00-05:00,-18000,0,EST,2\n" +
      "1710054000,2024-03-10T07:00:00Z,2024-03-10T03:00:00-04:00,-14400,1,EDT,1\n" +
      "1730613600,2024-11-03T06:00:00Z,2024-11-03T01:00:00-05:00,-18000,0,EST,2\n",
  );
});

test("tzif-transitions-csv reads version 1 files", async () => {
  const csv = await run(tzifBlock(0, {
    times: [0],
    indices: [1],
    types: [[19800 + 61, 0, 0], [0, 0, 4]],
    chars: "IST\0UTC\0",
  }, 4));
  assert.equal(
    csv,
    "time,utc,local,utoff,isdst,abbreviation,type\n" +
      ",,,19861,0,IST,0\n" +
      "0,1970-01-01T00:00:00Z,1970-01-01T00:00:00+00:00,0,0,UTC,1\n",
  );
});

test("tzif-transitions-csv rejects leap-second records and bad footers", async () => {
  const leap = tzifV2({ ...newYork, leapcnt: 1 }, "\n\n");
  await assert.rejects(run(leap), /rejected input at input offset 79\b/);
  const noFooter = tzifV2(newYork, "");
  await assert.rejects(
    run(noFooter),
    new RegExp(`rejected input at input offset ${noFooter.length}\\b`),
  );
});
