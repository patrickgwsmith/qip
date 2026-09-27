#!/usr/bin/env node
// Rewrites the input_mime and output_mime columns of site/data/component-catalog.csv from
// the content types each listed component declares, so the catalog carries parameters such
// as "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
// Other columns are left as they are. Usage: node tools/update-component-catalog.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const catalogPath = join(root, "site/data/component-catalog.csv");
const header = "path,input_encoding,input_mime,input_capacity_bytes,output_encoding,output_mime,output_capacity_bytes";

function readDeclaredContentType(instance, prefix) {
  const { exports } = instance;
  const ptrName = `${prefix}_content_type_ptr`;
  const sizeName = `${prefix}_content_type_size`;
  if (typeof exports[ptrName] !== "function" || typeof exports[sizeName] !== "function") return undefined;
  const ptr = exports[ptrName]();
  const size = exports[sizeName]();
  return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(exports.memory.buffer, ptr, size));
}

const lines = readFileSync(catalogPath, "utf8").trim().split("\n");
if (lines[0] !== header) throw new Error("Unexpected component catalog header.");
let changed = 0;
const rows = lines.slice(1).map((line) => {
  const fields = line.split(",");
  if (fields.length !== 7) throw new Error(`Row must have seven columns: ${line}`);
  const module = new WebAssembly.Module(readFileSync(join(root, fields[0].slice(1))));
  if (WebAssembly.Module.imports(module).length > 0) throw new Error(`${fields[0]} needs host imports`);
  const instance = new WebAssembly.Instance(module, {});
  const input = readDeclaredContentType(instance, "input");
  const output = readDeclaredContentType(instance, "output");
  for (const [index, value] of [[2, input], [5, output]]) {
    // A form component declares a placeholder boundary; the catalog only needs its media type.
    const declared = value?.startsWith("multipart/form-data;") ? "multipart/form-data" : value;
    if (declared === undefined || declared === fields[index]) continue;
    if (declared.includes(",") || declared.includes('"')) throw new Error(`${fields[0]} declares a content type that needs CSV quoting: ${declared}`);
    fields[index] = declared;
    changed += 1;
  }
  return fields.join(",");
});
writeFileSync(catalogPath, [header, ...rows].join("\n") + "\n");
console.log(`updated ${changed} content type column(s) across ${rows.length} components`);
