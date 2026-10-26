// Records the Wasmtime and rustc versions so `qipx bench` can report the engine it measured.
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let lock = Path::new(&manifest).join("Cargo.lock");
    println!("cargo::rerun-if-changed={}", lock.display());
    let wasmtime = fs::read_to_string(&lock)
        .ok()
        .and_then(|lock| {
            let (_, rest) = lock.split_once("\nname = \"wasmtime\"\nversion = \"")?;
            Some(rest.split_once('"')?.0.to_owned())
        })
        .unwrap_or_default();
    println!("cargo::rustc-env=QIPX_WASMTIME_VERSION={wasmtime}");

    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let rustc_version = Command::new(rustc)
        .arg("--version")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .and_then(|text| text.split_whitespace().nth(1).map(str::to_owned))
        .unwrap_or_default();
    println!("cargo::rustc-env=QIPX_RUSTC_VERSION={rustc_version}");
}
