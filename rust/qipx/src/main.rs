use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use url::Url;
use wasmparser::{ExternalKind, Operator, Parser, Payload};
use wasmtime::{Caller, Engine, Instance, Linker, Module, Store, Val, ValType};

mod tui;

struct StageSpec {
    path: String,
    uniforms: Vec<(String, String)>,
}

fn main() {
    if let Err(message) = run() {
        eprintln!("qipx: {message}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty()
        || matches!(
            args.first().map(String::as_str),
            Some("--help" | "-h" | "help")
        )
    {
        println!("{}", usage());
        return Ok(());
    }
    let command_index = args
        .iter()
        .position(|arg| {
            matches!(
                arg.as_str(),
                "run" | "dry" | "dry-run" | "tui" | "bench" | "comply"
            )
        })
        .ok_or("qipx requires a subcommand: run, dry run, tui, bench, or comply")?;
    let hosts: Vec<String> = args[..command_index]
        .iter()
        .map(|host| parse_host(host))
        .collect::<Result<_, _>>()?;
    let args = &args[command_index..];
    if matches!(args.get(1).map(String::as_str), Some("--help" | "-h")) {
        println!(
            "{}",
            match args[0].as_str() {
                "tui" => tui_usage(),
                "bench" => bench_usage(),
                "comply" => comply_usage(),
                _ => usage(),
            }
        );
        return Ok(());
    }
    if args.first().map(String::as_str) == Some("dry") {
        if args.get(1).map(String::as_str) != Some("run") {
            return Err("dry must be followed by run".into());
        }
        if matches!(args.get(2).map(String::as_str), Some("--help" | "-h")) {
            println!("{}", usage());
            return Ok(());
        }
        return dry_run(&args[2..], &hosts);
    }
    if args.first().map(String::as_str) == Some("dry-run") {
        return dry_run(&args[1..], &hosts);
    }
    if args.first().map(String::as_str) == Some("bench") {
        return bench(&args[1..], &hosts);
    }
    if args.first().map(String::as_str) == Some("comply") {
        return comply(&args[1..], &hosts);
    }
    let tui_mode = args.first().map(String::as_str) == Some("tui");
    if args.first().map(String::as_str) != Some("run") && !tui_mode {
        return Err("expected run <component.wasm>".into());
    }
    let mut input_path = "-";
    let mut input_from_cli = false;
    let mut output_path = "-";
    let mut form_fields = Vec::new();
    let mut max_memory = None;
    let mut capacities_must_fit = false;
    let mut stages: Vec<StageSpec> = Vec::new();
    let mut index = 1;
    let mut after_separator = false;
    while index < args.len() {
        if after_separator && !matches!(args[index].as_str(), "-u" | "--uniform") {
            stages.push(StageSpec {
                path: args[index].clone(),
                uniforms: Vec::new(),
            });
            index += 1;
            continue;
        }
        if args[index] == "--" {
            after_separator = true;
            index += 1;
            continue;
        }
        match args[index].as_str() {
            "-i" | "--input" => {
                index += 1;
                input_path = args.get(index).ok_or("--input requires a path")?;
                input_from_cli = true;
            }
            "-F" | "--form" => {
                index += 1;
                form_fields.push(args.get(index).ok_or("-F requires <name=value>")?.as_str());
            }
            "--max-memory" => {
                index += 1;
                let value = args.get(index).ok_or("--max-memory requires <bytes>")?;
                let cap: u64 = value
                    .parse()
                    .map_err(|_| format!("invalid --max-memory {value}"))?;
                if cap == 0 || cap > 9_007_199_254_740_991 {
                    return Err(format!("invalid --max-memory {value}"));
                }
                max_memory = Some(cap);
            }
            "--capacities-must-fit" => capacities_must_fit = true,
            "-o" | "--output" => {
                index += 1;
                output_path = args.get(index).ok_or("--output requires a path")?;
            }
            "-u" | "--uniform" => {
                index += 1;
                let assignment = args.get(index).ok_or("-u requires <name=value>")?;
                let (name, value) = assignment
                    .split_once('=')
                    .filter(|(name, _)| !name.is_empty())
                    .ok_or_else(|| format!("-u requires <name=value>, got {assignment:?}"))?;
                stages
                    .last_mut()
                    .ok_or("-u must follow a component path")?
                    .uniforms
                    .push((name.to_owned(), value.to_owned()));
            }
            arg if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
            path => stages.push(StageSpec {
                path: path.to_owned(),
                uniforms: Vec::new(),
            }),
        }
        index += 1;
    }
    if stages.is_empty() {
        return Err("at least one component is required".into());
    }
    if input_from_cli && !form_fields.is_empty() {
        return Err("-F and -i are mutually exclusive".into());
    }

    if tui_mode {
        if output_path != "-" {
            return Err("qipx tui writes only to terminal stdout; remove -o/--output".into());
        }
        if input_from_cli && input_path == "-" {
            return Err("qipx tui cannot read -i - because stdin carries terminal events".into());
        }
        if form_fields.iter().any(|field| {
            field
                .split_once('=')
                .is_some_and(|(_, value)| value == "@-" || value == "<-")
        }) {
            return Err(
                "qipx tui cannot use -F name=@- or name=<- because stdin carries terminal events"
                    .into(),
            );
        }
    }
    let engine = Engine::default();
    let mut loaded = stages
        .iter()
        .map(|stage| BenchCandidate::load(&engine, &stage.path, max_memory, &hosts))
        .collect::<Result<Vec<_>, _>>()?;
    validate_pipeline(&loaded, capacities_must_fit, !form_fields.is_empty())?;
    let mut input = if !form_fields.is_empty() {
        build_form(&form_fields, &hosts)?
    } else if input_path == "-"
        && (tui_mode
            || (!input_from_cli && loaded[0].input_ptr.is_none() && io::stdin().is_terminal()))
    {
        Vec::new()
    } else if input_path == "-" {
        let mut bytes = Vec::new();
        io::stdin()
            .read_to_end(&mut bytes)
            .map_err(|e| format!("cannot read stdin: {e}"))?;
        bytes
    } else {
        fs::read(input_path).map_err(|e| format!("cannot read {input_path}: {e}"))?
    };
    if tui_mode {
        return tui::run_tui(loaded, &stages, input);
    }
    for (candidate, stage) in loaded.iter_mut().zip(&stages) {
        for (name, value) in &stage.uniforms {
            apply_uniform(
                &candidate.instance,
                &mut candidate.store,
                &candidate.label,
                name,
                value,
            )?;
        }
        input = candidate.render(&input)?;
    }
    let is_utf8 = loaded.last().is_some_and(|stage| stage.is_utf8);
    if output_path == "-" {
        io::stdout()
            .write_all(&input)
            .map_err(|e| format!("cannot write stdout: {e}"))?;
        if is_utf8 {
            io::stdout()
                .write_all(b"\n")
                .map_err(|e| format!("cannot write stdout: {e}"))?;
        }
    } else {
        fs::write(output_path, &input).map_err(|e| format!("cannot write {output_path}: {e}"))?;
    }
    Ok(())
}

fn usage() -> &'static str {
    "Usage: qipx [host ...] run [options] <component.wasm> [component2.wasm ...]\n\
       qipx [host ...] dry run [options] <component.wasm> [component2.wasm ...]\n\
       qipx [host ...] tui [options] <interactive.wasm> [content.wasm ...]\n\
       qipx [host ...] comply [options] <file-or-dir> [...]\n\
       qipx [host ...] bench (-i <input> | -F <name=value>) [options] <component.wasm> [...]\n\n\
Hosts: dotted DNS names with optional ports; missing safe relative .wasm files use HTTPS.\n\n\
Options:\n\
  -i, --input <path>              Read input from a file instead of stdin\n\
  -F, --form <name=value>         Add multipart fields (repeatable)\n\
  -o, --output <path>             Write output to a file instead of stdout\n\
  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n\
  --capacities-must-fit           Reject stages whose max output cannot fit next input\n\
  -u, --uniform <name=value>      Set a uniform on the preceding component\n\
  -h, --help                      Show this help\n\n\
Multipart fields:\n\
  -F name=value                  UTF-8 text field\n\
  -F name=@path                  File bytes with basename as filename\n\
  -F 'name=<path'                File bytes as a regular field, without filename\n\
@path sends Content-Type: application/octet-stream; <path omits that part header.\n\
  -F name=@-                     Stdin bytes as a file field with filename \"-\"\n\
  -F 'name=<-'                   Stdin bytes as a regular field without filename\n\
Quote arguments containing < in a shell. Only one field may read stdin.\n\
Dry run plans form files without reading file contents or stdin.\n\n\
Examples:\n\
  qipx run -F mode=step -F component=@text/wc.wasm bytes/identity.wasm\n\
  qipx run -F 'data=<input.txt' bytes/identity.wasm\n\
  printf hello | qipx run -F 'data=<-' bytes/identity.wasm\n"
}

fn tui_usage() -> &'static str {
    "Usage: qipx [host ...] tui [options] <interactive.wasm> [content.wasm ...]\n\n\
  -i, --input <path>              Read initial input from a file\n\
  -F, --form <name=value>         Construct multipart input (repeatable)\n\
  -u, --uniform <name=value>      Set a uniform on the preceding component\n\
  --max-memory <bytes>            Reject modules whose declared memory exceeds bytes\n\
  --capacities-must-fit           Check capacity between Content stages\n\n\
Multipart fields: -F name=value, -F name=@path, or -F 'name=<path'.\n\
@path adds a filename; <path sends exact file bytes without a filename.\n\
@path sends Content-Type: application/octet-stream; <path omits that part header.\n\
-F name=@- and -F 'name=<-' are unavailable because stdin carries keys.\n\
Quote arguments containing < in a shell.\n\n\
Examples:\n\
  qipx tui components/interactive/calendar-gregorian.wasm\n\
  qipx tui -F 'component=<text/wc.wasm' components/interactive/qipdb.wasm\n"
}

fn bench_usage() -> &'static str {
    "Usage: qipx [host ...] bench (-i <input> | -F <name=value>) [options] <component.wasm> [...]\n\n\
  -i, --input <path>              Read benchmark input from a file or stdin (-)\n\
  -F, --form <name=value>         Construct multipart input (repeatable)\n\
  -r, --runs <n>                  Number of measured runs\n\
  --warmup <n>                    Warmup runs per component\n\
  --benchtime <duration>          Target measured time per component (default: 3s)\n\
  --max-memory <bytes>            Reject large declared memory\n\n\
Multipart fields: -F name=value, -F name=@path, or -F 'name=<path'.\n\
@path adds a filename; <path sends exact file bytes without a filename.\n\
@path sends Content-Type: application/octet-stream; <path omits that part header.\n\
-F name=@- or -F 'name=<-' reads stdin; only one field may do so.\n\
Quote arguments containing < in a shell.\n\n\
Examples:\n\
  qipx bench -F 'data=<input.txt' bytes/identity.wasm\n\
  printf hello | qipx bench -F 'data=<-' bytes/identity.wasm\n"
}

fn comply_usage() -> &'static str {
    "Usage: qipx [host ...] comply [options] <file-or-dir> [...]\n\n\
  --with <compliance.wasm>        Run a Compliance oracle (repeatable)\n\
  --seed <n>                      Set oracle uniform_set_seed(u32)\n\
  --max-memory <bytes>            Reject implementation memory above bytes\n"
}

fn parse_host(host: &str) -> Result<String, String> {
    let (name, port) = host
        .rsplit_once(':')
        .map_or((host, None), |(name, port)| (name, Some(port)));
    if name.len() > 253
        || !name.contains('.')
        || !name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                && label.as_bytes()[0].is_ascii_alphanumeric()
                && label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
        })
        || !name
            .rsplit('.')
            .next()
            .unwrap_or("")
            .bytes()
            .any(|byte| byte.is_ascii_alphabetic())
    {
        return Err(format!(
            "invalid host {host:?}; use a dotted DNS name with an optional port"
        ));
    }
    let port = if let Some(port) = port {
        let number: u16 = port
            .parse()
            .map_err(|_| format!("invalid host port in {host:?}"))?;
        if number == 0 {
            return Err(format!("invalid host port in {host:?}"));
        }
        format!(":{number}")
    } else {
        String::new()
    };
    Ok(format!("https://{}{port}", name.to_ascii_lowercase()))
}

fn dry_run(args: &[String], hosts: &[String]) -> Result<(), String> {
    let mut stages: Vec<StageSpec> = Vec::new();
    let mut forms = Vec::new();
    let mut max_memory = None;
    let mut capacities_must_fit = false;
    let mut index = 0;
    let mut after_separator = false;
    while index < args.len() {
        if after_separator && !matches!(args[index].as_str(), "-u" | "--uniform") {
            stages.push(StageSpec {
                path: args[index].clone(),
                uniforms: Vec::new(),
            });
            index += 1;
            continue;
        }
        if args[index] == "--" {
            after_separator = true;
            index += 1;
            continue;
        }
        match args[index].as_str() {
            "-i" | "--input" | "-o" | "--output" => {
                index += 1;
                args.get(index)
                    .ok_or("input/output option requires a path")?;
            }
            "-F" | "--form" => {
                index += 1;
                forms.push(args.get(index).ok_or("-F requires <name=value>")?.as_str());
            }
            "--max-memory" => {
                index += 1;
                let raw = args.get(index).ok_or("--max-memory requires <bytes>")?;
                let cap: u64 = raw
                    .parse()
                    .map_err(|_| format!("invalid --max-memory {raw}"))?;
                if cap == 0 || cap > 9_007_199_254_740_991 {
                    return Err(format!("invalid --max-memory {raw}"));
                }
                max_memory = Some(cap);
            }
            "--capacities-must-fit" => capacities_must_fit = true,
            "-u" | "--uniform" => {
                index += 1;
                let assignment = args.get(index).ok_or("-u requires <name=value>")?;
                let (name, value) = assignment
                    .split_once('=')
                    .filter(|(name, _)| !name.is_empty())
                    .ok_or_else(|| format!("-u requires <name=value>, got {assignment:?}"))?;
                stages
                    .last_mut()
                    .ok_or("-u must follow a component path")?
                    .uniforms
                    .push((name.to_owned(), value.to_owned()));
            }
            arg if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
            path => stages.push(StageSpec {
                path: path.to_owned(),
                uniforms: Vec::new(),
            }),
        }
        index += 1;
    }
    if stages.is_empty() {
        return Err("at least one component is required".into());
    }
    if forms
        .iter()
        .filter(|field| {
            field
                .split_once('=')
                .is_some_and(|(_, value)| value == "@-" || value == "<-")
        })
        .count()
        > 1
    {
        return Err("only one -F field may read from stdin with @- or <-".into());
    }
    println!("Sources:");
    for (component_index, stage) in stages.iter().enumerate() {
        if stages.len() > 1 {
            println!("  Component {}: {}", component_index + 1, stage.path);
        }
        let indent = if stages.len() > 1 { "    " } else { "  " };
        println!("{indent}0  local  {}", stage.path);
        if remote_eligible(&stage.path) {
            for (host_index, host) in hosts.iter().enumerate() {
                println!(
                    "{indent}{}  https  {}",
                    host_index + 1,
                    source_url(host, &stage.path)?
                );
            }
        }
    }
    println!("\nResolution:");
    let mut missing = 0;
    for (component_index, stage) in stages.iter().enumerate() {
        if stages.len() > 1 {
            println!("  Component {}: {}", component_index + 1, stage.path);
        }
        let indent = if stages.len() > 1 { "    " } else { "  " };
        match fs::metadata(&stage.path) {
            Ok(_) => println!("{indent}0  selected"),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
                ) =>
            {
                missing += 1;
                println!("{indent}0  missing");
            }
            Err(error) => return Err(format!("cannot read {}: {error}", stage.path)),
        }
        if remote_eligible(&stage.path) {
            for (host_index, _) in hosts.iter().enumerate() {
                println!("{indent}{}  unexamined", host_index + 1);
            }
        }
    }
    let multipart_files: Vec<_> = forms
        .iter()
        .filter_map(|assignment| {
            assignment.split_once('=').and_then(|(name, value)| {
                value
                    .strip_prefix('@')
                    .or_else(|| value.strip_prefix('<'))
                    .map(|path| (name, path))
            })
        })
        .filter(|(_, path)| *path != "-")
        .collect();
    if !multipart_files.is_empty() {
        println!("\nMultipart files:");
        for (name, path) in multipart_files {
            let status = if fs::metadata(path).is_ok() {
                "present (contents not read)"
            } else {
                "missing"
            };
            println!("  Field {name:?}: {path}");
            println!("    0  local  {path}  {status}");
            if remote_eligible(path) {
                for (host_index, host) in hosts.iter().enumerate() {
                    println!(
                        "    {}  https  {}  unexamined",
                        host_index + 1,
                        source_url(host, path)?
                    );
                }
            }
        }
    }
    println!("\nValidation:");
    let engine = Engine::default();
    let mut loaded = Vec::new();
    for stage in &stages {
        if fs::metadata(&stage.path).is_err() {
            println!("  {}: deferred (local file missing)", stage.path);
            continue;
        }
        let mut candidate = BenchCandidate::load(&engine, &stage.path, max_memory, &[])?;
        for (name, value) in &stage.uniforms {
            apply_uniform(
                &candidate.instance,
                &mut candidate.store,
                &candidate.label,
                name,
                value,
            )?;
        }
        println!("  {}: valid", stage.path);
        loaded.push(candidate);
    }
    if missing > 0 {
        println!(
            "Pipeline compatibility: deferred ({missing} component{} missing locally)",
            if missing == 1 { "" } else { "s" }
        );
        return Ok(());
    }
    validate_pipeline(&loaded, capacities_must_fit, !forms.is_empty())?;
    println!("Pipeline compatible: {} step(s)", stages.len());
    let mut total = 0usize;
    for (index, stage) in loaded.iter().enumerate() {
        let buffers = stage.input_cap + stage.output_cap;
        total += buffers;
        println!("{}. {} — Content", index + 1, stage.label);
        println!(
            "   Input: encoding={}, type={}, capacity={} bytes",
            if stage.input_ptr.is_none() {
                "none"
            } else if stage.input_utf8 {
                "UTF-8"
            } else {
                "bytes"
            },
            if stage.input_mime.is_empty() {
                "unspecified"
            } else {
                &stage.input_mime
            },
            stage.input_cap
        );
        println!(
            "   Output: encoding={}, type={}, capacity={} bytes",
            if stage.is_utf8 { "UTF-8" } else { "bytes" },
            if stage.output_mime.is_empty() {
                "unspecified"
            } else {
                &stage.output_mime
            },
            stage.output_cap
        );
        println!("   Buffers: {buffers} bytes");
    }
    println!("Total declared buffer capacity: {total} bytes");
    Ok(())
}

fn remote_eligible(path: &str) -> bool {
    path.ends_with(".wasm")
        && !path.starts_with('/')
        && !path.contains('\\')
        && !path.contains(['?', '#', ':'])
        && !path.bytes().any(|byte| byte < 0x20 || byte == 0x7f)
        && path
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

fn source_url(host: &str, path: &str) -> Result<Url, String> {
    let mut url = Url::parse(host).map_err(|e| format!("invalid host {host}: {e}"))?;
    url.path_segments_mut()
        .map_err(|_| format!("invalid host {host}"))?
        .extend(path.split('/'));
    Ok(url)
}

fn resolve_wasm(
    path: &str,
    hosts: &[String],
    validate: impl Fn(&[u8], &str) -> Result<(), String>,
) -> Result<Vec<u8>, String> {
    match fs::read(path) {
        Ok(bytes) => {
            validate(&bytes, path)?;
            return Ok(bytes);
        }
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
            ) => {}
        Err(error) => return Err(format!("cannot read {path}: {error}")),
    }
    if !remote_eligible(path) {
        return Err(format!(
            "{path} is missing; only missing relative paths ending in .wasm can be downloaded"
        ));
    }
    let mut unavailable = Vec::new();
    for host in hosts {
        let mut url = source_url(host, path)?;
        let origin = url.origin();
        let source = url.clone();
        let config = ureq::Agent::config_builder()
            .https_only(true)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = ureq::Agent::new_with_config(config);
        let mut fetched = None;
        for redirects in 0..=2 {
            let mut response = match agent.get(url.as_str()).call() {
                Ok(response) => response,
                Err(error) => {
                    unavailable.push(format!("{source}: {error}"));
                    break;
                }
            };
            let status = response.status().as_u16();
            if (300..=399).contains(&status) {
                if redirects == 2 {
                    return Err(format!("{source} exceeded the 2-redirect limit"));
                }
                let location = response
                    .headers()
                    .get("location")
                    .ok_or_else(|| format!("{url} returned HTTP {status} without Location"))?
                    .to_str()
                    .map_err(|_| format!("{url} returned an invalid Location"))?;
                let next = url
                    .join(location)
                    .map_err(|e| format!("{url} returned an invalid Location: {e}"))?;
                if next.scheme() != "https"
                    || next.origin() != origin
                    || !next.username().is_empty()
                    || next.password().is_some()
                {
                    return Err(format!("{url} redirected outside its HTTPS origin"));
                }
                url = next;
                continue;
            }
            if status == 404 || status == 410 || status >= 500 {
                unavailable.push(format!("{source}: HTTP {status}"));
                break;
            }
            if status != 200 {
                return Err(format!("{url} returned HTTP {status}"));
            }
            if response
                .headers()
                .get("content-length")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok())
                .is_some_and(|size| size > 16 * 1024 * 1024)
            {
                return Err(format!("{url} exceeds the 16777216-byte download limit"));
            }
            let mut bytes = Vec::new();
            response
                .body_mut()
                .with_config()
                .limit(16 * 1024 * 1024 + 1)
                .reader()
                .read_to_end(&mut bytes)
                .map_err(|e| format!("cannot read {url}: {e}"))?;
            if bytes.len() > 16 * 1024 * 1024 {
                return Err(format!("{url} exceeds the 16777216-byte download limit"));
            }
            validate(&bytes, url.as_str())?;
            fetched = Some(bytes);
            break;
        }
        if let Some(bytes) = fetched {
            vendor_download(path, &bytes)?;
            let installed =
                fs::read(path).map_err(|e| format!("cannot read installed {path}: {e}"))?;
            validate(&installed, path)?;
            return Ok(installed);
        }
    }
    let detail = if unavailable.is_empty() {
        String::new()
    } else {
        format!(" ({})", unavailable.join("; "))
    };
    Err(format!("{path} is unavailable from every source{detail}"))
}

fn vendor_download(path: &str, bytes: &[u8]) -> Result<(), String> {
    let root =
        fs::canonicalize(".").map_err(|e| format!("cannot resolve current directory: {e}"))?;
    let file = Path::new(path);
    let parent = file.parent().unwrap_or(Path::new("."));
    let mut ancestor = parent;
    while !ancestor.exists() {
        ancestor = ancestor.parent().unwrap_or(Path::new("."));
    }
    let resolved = fs::canonicalize(ancestor).map_err(|e| format!("cannot resolve {path}: {e}"))?;
    if !resolved.starts_with(&root) {
        return Err(format!(
            "refusing to vendor outside the current directory: {path}"
        ));
    }
    fs::create_dir_all(parent).map_err(|e| format!("cannot create parent of {path}: {e}"))?;
    let resolved =
        fs::canonicalize(parent).map_err(|e| format!("cannot resolve parent of {path}: {e}"))?;
    if !resolved.starts_with(&root) {
        return Err(format!(
            "refusing to vendor outside the current directory: {path}"
        ));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(
        ".{}.qipx-{}-{nonce}.tmp",
        file.file_name().unwrap().to_string_lossy(),
        std::process::id()
    ));
    let result = (|| {
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|e| format!("cannot create temporary download for {path}: {e}"))?;
        output
            .write_all(bytes)
            .map_err(|e| format!("cannot save {path}: {e}"))?;
        match fs::hard_link(&temporary, file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(format!("cannot install {path}: {error}")),
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

struct BenchCandidate {
    label: String,
    store: Store<()>,
    instance: Instance,
    memory: wasmtime::Memory,
    input_ptr: Option<usize>,
    input_cap: usize,
    output_cap: usize,
    is_utf8: bool,
    input_utf8: bool,
    input_mime: String,
    output_mime: String,
}

impl BenchCandidate {
    fn load(
        engine: &Engine,
        path: &str,
        max_memory: Option<u64>,
        hosts: &[String],
    ) -> Result<Self, String> {
        let wasm = resolve_wasm(path, hosts, |wasm, label| {
            validate_policy(wasm, label, max_memory)?;
            Module::validate(engine, wasm).map_err(|e| format!("{label}: {e}"))
        })?;
        let module = Module::new(engine, wasm).map_err(|e| format!("{path}: {e}"))?;
        let mut store = Store::new(engine, ());
        let instance =
            Instance::new(&mut store, &module, &[]).map_err(|e| format!("{path}: {e}"))?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| format!("{path} does not export memory"))?;
        let has_input_bytes = instance.get_func(&mut store, "input_bytes_cap").is_some();
        let has_input_utf8 = instance.get_func(&mut store, "input_utf8_cap").is_some();
        let input_ptr = if instance.get_func(&mut store, "input_ptr").is_some() {
            Some(call_i32(&instance, &mut store, "input_ptr", path)? as u32 as usize)
        } else {
            None
        };
        if input_ptr.is_some() && has_input_bytes == has_input_utf8 {
            return Err(format!(
                "{path} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap"
            ));
        }
        if input_ptr.is_none() && (has_input_bytes || has_input_utf8) {
            return Err(format!(
                "{path} inputless generator must not export an input capacity"
            ));
        }
        let input_cap = if input_ptr.is_none() {
            0
        } else if has_input_bytes {
            call_i32(&instance, &mut store, "input_bytes_cap", path)? as u32 as usize
        } else {
            call_i32(&instance, &mut store, "input_utf8_cap", path)? as u32 as usize
        };
        let is_utf8 = instance.get_func(&mut store, "output_utf8_cap").is_some();
        let has_output_bytes = instance.get_func(&mut store, "output_bytes_cap").is_some();
        if is_utf8 == has_output_bytes {
            return Err(format!(
                "{path} must export exactly one output capacity: output_utf8_cap or output_bytes_cap"
            ));
        }
        let output_cap = if is_utf8 {
            call_i32(&instance, &mut store, "output_utf8_cap", path)?
        } else {
            call_i32(&instance, &mut store, "output_bytes_cap", path)?
        } as u32 as usize;
        let input_mime = read_content_type(&instance, &mut store, &memory, path, "input")?;
        let output_mime = read_content_type(&instance, &mut store, &memory, path, "output")?;
        if input_ptr.is_none() && !input_mime.is_empty() {
            return Err(format!(
                "{path} inputless generator must not declare an input content type"
            ));
        }
        Ok(Self {
            label: path.to_owned(),
            store,
            instance,
            memory,
            input_ptr,
            input_cap,
            output_cap,
            is_utf8,
            input_utf8: has_input_utf8,
            input_mime,
            output_mime,
        })
    }

    fn render(&mut self, input: &[u8]) -> Result<Vec<u8>, String> {
        let path = self.label.as_str();
        if self.input_ptr.is_none() && !input.is_empty() {
            return Err(format!(
                "{path} is an inputless generator and cannot receive input bytes"
            ));
        }
        if input.len() > self.input_cap {
            return Err(format!("{path} input exceeds its capacity"));
        }
        if let Some(input_ptr) = self.input_ptr {
            self.memory
                .write(&mut self.store, input_ptr, input)
                .map_err(|_| format!("{path} input exceeds linear memory"))?;
        }
        let render = self
            .instance
            .get_typed_func::<i32, i64>(&mut self.store, "render")
            .map_err(|_| format!("{path} must export render(i32) -> i64"))?;
        let bits = render
            .call(&mut self.store, input.len() as i32)
            .map_err(|e| format!("{path} trapped: {e}"))? as u64;
        if bits >> 63 != 0 {
            let modes = call_i32(
                &self.instance,
                &mut self.store,
                "failure_modes_per_input_offset",
                path,
            )? as u32;
            let detail = bits as u32;
            return Err(if modes == 0 {
                format!("{path} rejected input")
            } else if detail.is_multiple_of(modes) {
                format!("{path} rejected input at input offset {}", detail / modes)
            } else {
                format!(
                    "{path} rejected input at input offset {} with mode {}",
                    detail / modes,
                    detail % modes
                )
            });
        }
        let ptr = ((bits >> 32) & 0x7fff_ffff) as usize;
        let length = bits as u32 as usize;
        if length > self.output_cap {
            return Err(format!("{path} returned an invalid output length"));
        }
        let mut output = vec![0; length];
        self.memory
            .read(&self.store, ptr, &mut output)
            .map_err(|_| format!("{path} returned an invalid output pointer"))?;
        Ok(output)
    }
}

fn read_content_type(
    instance: &Instance,
    store: &mut Store<()>,
    memory: &wasmtime::Memory,
    path: &str,
    prefix: &str,
) -> Result<String, String> {
    let pointer = format!("{prefix}_content_type_ptr");
    let size = format!("{prefix}_content_type_size");
    let has_pointer = instance.get_func(&mut *store, &pointer).is_some();
    let has_size = instance.get_func(&mut *store, &size).is_some();
    if has_pointer != has_size {
        return Err(format!(
            "{path} has incomplete {prefix} content-type exports"
        ));
    }
    if !has_pointer {
        return Ok(String::new());
    }
    let offset = call_i32(instance, store, &pointer, path)? as u32 as usize;
    let length = call_i32(instance, store, &size, path)? as u32 as usize;
    let data = memory.data(&*store);
    let end = offset
        .checked_add(length)
        .filter(|end| *end <= data.len())
        .ok_or_else(|| format!("{path} has invalid {prefix} content-type pointer or size"))?;
    let value = std::str::from_utf8(&data[offset..end])
        .map_err(|_| format!("{path} has invalid UTF-8 {prefix} content type"))?
        .to_owned();
    if value != "multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000" {
        let Some((main, sub)) = value.split_once('/') else {
            return Err(format!("invalid {path} {prefix} content type: {value}"));
        };
        let valid = |s: &str| {
            !s.is_empty()
                && s.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || b"!#$&^_.+-".contains(&byte)
                })
        };
        if !valid(main) || !valid(sub) {
            return Err(format!("invalid {path} {prefix} content type: {value}"));
        }
    }
    Ok(value)
}

fn validate_pipeline(
    stages: &[BenchCandidate],
    capacities_must_fit: bool,
    form_input: bool,
) -> Result<(), String> {
    if stages.is_empty() {
        return Err("at least one component is required".into());
    }
    let mut current = if form_input {
        "multipart/form-data;boundary=uuid-00000000-0000-0000-0000-000000000000"
    } else {
        ""
    };
    for (index, stage) in stages.iter().enumerate() {
        if stage.input_ptr.is_none() && index != 0 {
            return Err(format!(
                "{} inputless generator must be the first pipeline stage",
                stage.label
            ));
        }
        if !stage.input_mime.is_empty() {
            if current.is_empty() && index == 0 {
                current = &stage.input_mime;
            } else if current != stage.input_mime {
                return Err(if current.is_empty() {
                    format!(
                        "{} expects {}, but pipeline content type is unspecified",
                        stage.label, stage.input_mime
                    )
                } else {
                    format!(
                        "{} expects {}, got {current}",
                        stage.label, stage.input_mime
                    )
                });
            }
        }
        if !stage.output_mime.is_empty() {
            current = &stage.output_mime;
        } else if stage.input_ptr.is_some() && stage.is_utf8 && !stage.input_utf8 {
            current = "";
        }
        if capacities_must_fit
            && index + 1 < stages.len()
            && stage.output_cap > stages[index + 1].input_cap
        {
            return Err(format!(
                "{} output capacity {} exceeds {} input capacity {}",
                stage.label,
                stage.output_cap,
                stages[index + 1].label,
                stages[index + 1].input_cap
            ));
        }
    }
    Ok(())
}

fn bench(args: &[String], hosts: &[String]) -> Result<(), String> {
    let mut input_path = None;
    let mut runs = None;
    let mut warmup = 10usize;
    let mut benchtime = None;
    let mut form_fields = Vec::new();
    let mut max_memory = None;
    let mut paths: Vec<StageSpec> = Vec::new();
    let mut index = 0;
    let mut after_separator = false;
    while index < args.len() {
        if after_separator && !matches!(args[index].as_str(), "-u" | "--uniform") {
            paths.push(StageSpec {
                path: args[index].clone(),
                uniforms: Vec::new(),
            });
            index += 1;
            continue;
        }
        if args[index] == "--" {
            after_separator = true;
            index += 1;
            continue;
        }
        match args[index].as_str() {
            "-i" | "--input" => {
                index += 1;
                input_path = Some(args.get(index).ok_or("--input requires a path")?.as_str());
            }
            "-F" | "--form" => {
                index += 1;
                form_fields.push(args.get(index).ok_or("-F requires <name=value>")?.as_str());
            }
            "-r" | "--runs" => {
                index += 1;
                let count: usize = args
                    .get(index)
                    .ok_or("--runs must be a positive integer")?
                    .parse()
                    .map_err(|_| "--runs must be a positive integer")?;
                if count == 0 {
                    return Err("--runs must be a positive integer".into());
                }
                runs = Some(count);
            }
            "--warmup" => {
                index += 1;
                warmup = args
                    .get(index)
                    .ok_or("--warmup must be a nonnegative integer")?
                    .parse()
                    .map_err(|_| "--warmup must be a nonnegative integer")?;
            }
            "--max-memory" => {
                index += 1;
                let raw = args.get(index).ok_or("--max-memory requires <bytes>")?;
                let cap: u64 = raw
                    .parse()
                    .map_err(|_| format!("invalid --max-memory {raw}"))?;
                if cap == 0 || cap > 9_007_199_254_740_991 {
                    return Err(format!("invalid --max-memory {raw}"));
                }
                max_memory = Some(cap);
            }
            "--benchtime" => {
                index += 1;
                benchtime = Some(
                    args.get(index)
                        .ok_or("--benchtime requires a duration")?
                        .as_str(),
                );
            }
            arg if arg.starts_with("--benchtime=") => benchtime = Some(&arg[12..]),
            "-u" | "--uniform" => {
                index += 1;
                let assignment = args.get(index).ok_or("-u requires <name=value>")?;
                let (name, value) = assignment
                    .split_once('=')
                    .filter(|(name, _)| !name.is_empty())
                    .ok_or_else(|| format!("-u requires <name=value>, got {assignment:?}"))?;
                paths
                    .last_mut()
                    .ok_or("-u must follow a component path")?
                    .uniforms
                    .push((name.to_owned(), value.to_owned()));
            }
            arg if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
            path => paths.push(StageSpec {
                path: path.to_owned(),
                uniforms: Vec::new(),
            }),
        }
        index += 1;
    }
    if runs.is_some() && benchtime.is_some() {
        return Err("use either --runs or --benchtime, not both".into());
    }
    if input_path.is_some() && !form_fields.is_empty() {
        return Err("-F and -i are mutually exclusive".into());
    }
    if input_path.is_none() && form_fields.is_empty() {
        return Err("qipx bench requires -i <input> or -F <name=value>".into());
    }
    if paths.is_empty() {
        return Err("qipx bench requires at least one component".into());
    }
    let input = if !form_fields.is_empty() {
        build_form(&form_fields, hosts)?
    } else if input_path == Some("-") {
        let mut bytes = Vec::new();
        io::stdin()
            .read_to_end(&mut bytes)
            .map_err(|e| format!("cannot read stdin: {e}"))?;
        bytes
    } else {
        let path = input_path.unwrap();
        fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?
    };
    let engine = Engine::default();
    let mut candidates = paths
        .iter()
        .map(|spec| BenchCandidate::load(&engine, &spec.path, max_memory, hosts))
        .collect::<Result<Vec<_>, _>>()?;
    for (candidate, spec) in candidates.iter_mut().zip(&paths) {
        for (name, value) in &spec.uniforms {
            apply_uniform(
                &candidate.instance,
                &mut candidate.store,
                &candidate.label,
                name,
                value,
            )?;
        }
    }
    let expected = candidates[0].render(&input)?;
    let output_type = candidates[0].is_utf8;
    let output_mime = candidates[0].output_mime.clone();
    for candidate in candidates.iter_mut().skip(1) {
        if candidate.is_utf8 != output_type
            || candidate.output_mime != output_mime
            || candidate.render(&input)? != expected
        {
            return Err(format!(
                "{} output differs from {}",
                candidate.label, paths[0].path
            ));
        }
    }
    let mut means = Vec::new();
    for candidate in &mut candidates {
        for _ in 0..warmup {
            if candidate.render(&input)? != expected {
                return Err(format!("{} warmup output differs", candidate.label));
            }
        }
        let mut elapsed = 0u128;
        let target = parse_benchtime(benchtime.unwrap_or("3s"))?;
        let started = Instant::now();
        let mut count = 0usize;
        loop {
            let start = Instant::now();
            let output = candidate.render(&input)?;
            elapsed += start.elapsed().as_nanos();
            count += 1;
            if output != expected {
                return Err(format!("{} measured output differs", candidate.label));
            }
            if runs.is_some_and(|runs| count >= runs)
                || (runs.is_none() && started.elapsed() >= target)
            {
                break;
            }
            if count >= 100_000_000 {
                return Err(
                    "--benchtime produced too many samples; use --runs for explicit control".into(),
                );
            }
        }
        means.push(elapsed as f64 / count as f64);
    }
    println!(
        "{}",
        if candidates.len() == 1 {
            "Benchmark: baseline output captured"
        } else {
            "Benchmark: outputs match"
        }
    );
    println!(
        "Input: {} ({} bytes, sha256 {:x})",
        input_path.unwrap_or("multipart form"),
        input.len(),
        Sha256::digest(&input)
    );
    println!(
        "Output: encoding={}, {} bytes",
        if output_type { "utf8" } else { "bytes" },
        expected.len()
    );
    println!("Output SHA-256: {:x}", Sha256::digest(&expected));
    println!("Warmup: {warmup} runs/component");
    if let Some(runs) = runs {
        println!("Measured: {runs} runs/component");
    } else {
        println!("Measured: {} target/component", benchtime.unwrap_or("3s"));
    }
    println!("Runtime: Wasmtime");
    println!("Boundary: input/output copies and render on one reused instance");
    for (candidate, mean) in candidates.iter().zip(means) {
        println!("{}: {mean:.0} ns mean", candidate.label);
    }
    Ok(())
}

fn parse_benchtime(value: &str) -> Result<Duration, String> {
    for (suffix, scale) in [
        ("ns", 1.0),
        ("us", 1e3),
        ("µs", 1e3),
        ("ms", 1e6),
        ("s", 1e9),
        ("m", 60e9),
    ] {
        if let Some(raw) = value.strip_suffix(suffix) {
            let number: f64 = raw.parse().map_err(|_| {
                format!("invalid --benchtime {value}; use a duration such as 250ms, 3s, or 1m")
            })?;
            if !number.is_finite() || number <= 0.0 {
                return Err("--benchtime must be greater than zero".into());
            }
            return Ok(Duration::from_nanos((number * scale).max(1.0) as u64));
        }
    }
    Err(format!(
        "invalid --benchtime {value}; use a duration such as 250ms, 3s, or 1m"
    ))
}

struct OracleState {
    implementation: BenchCandidate,
    next: u64,
    fail_count: u64,
    failures: Vec<String>,
    protocol_error: Option<String>,
    open_render_into: Option<u64>,
    open_failed: bool,
    open_errors: u32,
}

fn oracle_bytes(caller: &mut Caller<'_, OracleState>, ptr: i32, length: i32) -> Option<Vec<u8>> {
    let memory = caller.get_export("memory")?.into_memory()?;
    let offset = ptr as u32 as usize;
    let size = length as u32 as usize;
    if offset.checked_add(size)? > memory.data_size(&*caller) {
        return None;
    }
    let mut bytes = vec![0; length as u32 as usize];
    memory.read(caller, offset, &mut bytes).ok()?;
    Some(bytes)
}

fn run_oracle(
    engine: &Engine,
    implementation: &str,
    oracle: &str,
    seed: Option<u32>,
    max_memory: Option<u64>,
    hosts: &[String],
) -> Result<u64, String> {
    let wasm = resolve_wasm(oracle, hosts, |bytes, label| {
        Module::validate(engine, bytes)
            .map_err(|e| format!("{label} is not valid WebAssembly: {e}"))
    })?;
    let module =
        Module::new(engine, wasm).map_err(|e| format!("{oracle} is not valid WebAssembly: {e}"))?;
    let implementation = BenchCandidate::load(engine, implementation, max_memory, hosts)?;
    let state = OracleState {
        implementation,
        next: 0,
        fail_count: 0,
        failures: Vec::new(),
        protocol_error: None,
        open_render_into: None,
        open_failed: false,
        open_errors: 0,
    };
    let mut store = Store::new(engine, state);
    let mut linker = Linker::new(engine);
    linker
        .func_wrap(
            "qip",
            "set_uniform_u32",
            |mut caller: Caller<'_, OracleState>,
             name_ptr: i32,
             name_len: i32,
             value: i32|
             -> i32 {
                if let Some(ordinal) = caller.data().open_render_into {
                    caller.data_mut().protocol_error = Some(format!(
                        "set_uniform_u32 called inside open must_render_into case {ordinal}"
                    ));
                    return 0;
                }
                if name_len <= 0 || name_len > 128 {
                    caller.data_mut().protocol_error = Some(format!(
                        "set_uniform_u32 name length {name_len} is outside 1..128"
                    ));
                    return 0;
                }
                let Some(name_bytes) = oracle_bytes(&mut caller, name_ptr, name_len) else {
                    caller.data_mut().protocol_error =
                        Some("set_uniform_u32 name pointer out of range".into());
                    return 0;
                };
                let Ok(name) = std::str::from_utf8(&name_bytes) else {
                    caller.data_mut().protocol_error =
                        Some("set_uniform_u32 name is not UTF-8".into());
                    return 0;
                };
                let name = name.to_owned();
                if name.is_empty()
                    || name.len() > 63
                    || !name.bytes().next().unwrap().is_ascii_lowercase()
                    || !name.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
                    })
                    || name.ends_with('_')
                    || name.contains("__")
                {
                    caller.data_mut().protocol_error = Some(format!(
                        "set_uniform_u32 name {name:?} is not a valid uniform key"
                    ));
                    return 0;
                }
                let implementation = &mut caller.data_mut().implementation;
                let export = format!("uniform_set_{name}");
                let Some(function) = implementation
                    .instance
                    .get_func(&mut implementation.store, &export)
                else {
                    caller.data_mut().protocol_error =
                        Some(format!("implementation does not export {export}"));
                    return 0;
                };
                let ty = function.ty(&implementation.store);
                let params: Vec<_> = ty.params().collect();
                let results: Vec<_> = ty.results().collect();
                if params.len() != 1
                    || !matches!(params.first(), Some(ValType::I32))
                    || results.len() > 1
                    || (results.len() == 1 && !matches!(results.first(), Some(ValType::I32)))
                {
                    caller.data_mut().protocol_error =
                        Some(format!("{export} has an invalid signature"));
                    return 0;
                }
                let mut output = if results.is_empty() {
                    Vec::new()
                } else {
                    vec![Val::I32(0)]
                };
                match function.call(&mut implementation.store, &[Val::I32(value)], &mut output) {
                    Ok(()) => output.first().and_then(Val::i32).unwrap_or(0),
                    Err(error) => {
                        caller.data_mut().protocol_error =
                            Some(format!("{export} trapped: {error}"));
                        0
                    }
                }
            },
        )
        .map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker.func_wrap("qip", "must_render_exactly", |mut caller: Caller<'_, OracleState>, ordinal: i64, in_ptr: i32, in_len: i32, exp_ptr: i32, exp_len: i32| -> i32 {
        if let Some(open) = caller.data().open_render_into {
            caller.data_mut().protocol_error = Some(format!("must_render_exactly at ordinal {ordinal} inside open must_render_into case {open}"));
            return 0;
        }
        let expected_ordinal = caller.data().next;
        if ordinal as u64 != expected_ordinal {
            caller.data_mut().protocol_error = Some(format!("must_render_exactly declared ordinal {ordinal}, host expected {expected_ordinal}"));
            return 0;
        }
        caller.data_mut().next += 1;
        let input = oracle_bytes(&mut caller, in_ptr, in_len);
        let expected = oracle_bytes(&mut caller, exp_ptr, exp_len);
        let (Some(input), Some(expected)) = (input, expected) else {
            caller.data_mut().protocol_error = Some(format!("must_render_exactly pointers out of range at ordinal {ordinal}"));
            return 0;
        };
        match caller.data_mut().implementation.render(&input) {
            Ok(actual) if actual == expected => 1,
            Ok(_) => {
                caller.data_mut().fail_count += 1;
                caller.data_mut().failures.push(format!("case {ordinal}: output mismatch"));
                0
            }
            Err(error) => {
                caller.data_mut().fail_count += 1;
                caller.data_mut().failures.push(format!("case {ordinal}: {error}"));
                0
            }
        }
    }).map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker.func_wrap("qip", "must_reject", |mut caller: Caller<'_, OracleState>, ordinal: i64, in_ptr: i32, in_len: i32| -> i32 {
        if let Some(open) = caller.data().open_render_into {
            caller.data_mut().protocol_error = Some(format!("must_reject at ordinal {ordinal} inside open must_render_into case {open}"));
            return 0;
        }
        let expected_ordinal = caller.data().next;
        if ordinal as u64 != expected_ordinal {
            caller.data_mut().protocol_error = Some(format!("must_reject declared ordinal {ordinal}, host expected {expected_ordinal}"));
            return 0;
        }
        caller.data_mut().next += 1;
        let Some(input) = oracle_bytes(&mut caller, in_ptr, in_len) else {
            caller.data_mut().protocol_error = Some(format!("must_reject pointer out of range at ordinal {ordinal}"));
            return 0;
        };
        let implementation = &mut caller.data_mut().implementation;
        let has_failure = implementation.instance.get_func(&mut implementation.store, "failure_modes_per_input_offset").is_some();
        if !has_failure {
            caller.data_mut().fail_count += 1;
            caller.data_mut().failures.push(format!("case {ordinal}: expected rejection, but implementation does not export failure_modes_per_input_offset"));
            return 0;
        }
        match caller.data_mut().implementation.render(&input) {
            Err(error) if error.contains(" rejected input") => 1,
            Ok(_) => {
                caller.data_mut().fail_count += 1;
                caller.data_mut().failures.push(format!("case {ordinal}: expected rejection, render was accepted"));
                0
            }
            Err(error) => {
                caller.data_mut().fail_count += 1;
                caller.data_mut().failures.push(format!("case {ordinal}: expected rejection: {error}"));
                0
            }
        }
    }).map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker
        .func_wrap(
            "qip",
            "must_trap",
            |mut caller: Caller<'_, OracleState>, ordinal: i64, in_ptr: i32, in_len: i32| -> i32 {
                if let Some(open) = caller.data().open_render_into {
                    caller.data_mut().protocol_error = Some(format!(
                        "must_trap at ordinal {ordinal} inside open must_render_into case {open}"
                    ));
                    return 0;
                }
                let expected_ordinal = caller.data().next;
                if ordinal as u64 != expected_ordinal {
                    caller.data_mut().protocol_error = Some(format!(
                        "must_trap declared ordinal {ordinal}, host expected {expected_ordinal}"
                    ));
                    return 0;
                }
                caller.data_mut().next += 1;
                let Some(input) = oracle_bytes(&mut caller, in_ptr, in_len) else {
                    caller.data_mut().protocol_error = Some(format!(
                        "must_trap pointer out of range at ordinal {ordinal}"
                    ));
                    return 0;
                };
                match caller.data_mut().implementation.render(&input) {
                    Ok(_) => {
                        caller.data_mut().fail_count += 1;
                        caller
                            .data_mut()
                            .failures
                            .push(format!("case {ordinal}: expected trap, got output"));
                        0
                    }
                    Err(error) if error.contains(" rejected input") => {
                        caller.data_mut().fail_count += 1;
                        caller
                            .data_mut()
                            .failures
                            .push(format!("case {ordinal}: expected trap, got rejection"));
                        0
                    }
                    Err(_) => 1,
                }
            },
        )
        .map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker.func_wrap("qip", "must_render_into", |mut caller: Caller<'_, OracleState>, ordinal: i64, in_ptr: i32, in_len: i32, out_ptr: i32, out_cap: i32| -> i32 {
        if let Some(open) = caller.data().open_render_into {
            caller.data_mut().protocol_error = Some(format!("must_render_into opened ordinal {ordinal} while ordinal {open} is still open"));
            return -1;
        }
        if ordinal as u64 != caller.data().next {
            let next = caller.data().next;
            caller.data_mut().protocol_error = Some(format!("must_render_into opened ordinal {ordinal}, host expected {next}"));
            return -1;
        }
        caller.data_mut().open_render_into = Some(ordinal as u64);
        caller.data_mut().open_failed = false;
        caller.data_mut().open_errors = 0;
        let Some(input) = oracle_bytes(&mut caller, in_ptr, in_len) else {
            caller.data_mut().open_failed = true;
            caller.data_mut().protocol_error = Some(format!("must_render_into pointer out of range at ordinal {ordinal}"));
            return -1;
        };
        let output = match caller.data_mut().implementation.render(&input) {
            Ok(output) => output,
            Err(_) => { caller.data_mut().open_failed = true; return -1; }
        };
        if output.len() > out_cap as u32 as usize {
            caller.data_mut().open_failed = true;
            return -2;
        }
        let Some(memory) = caller.get_export("memory").and_then(|export| export.into_memory()) else {
            caller.data_mut().open_failed = true;
            caller.data_mut().protocol_error = Some(format!("must_render_into out pointer out of range at ordinal {ordinal}"));
            return -1;
        };
        if memory.write(&mut caller, out_ptr as u32 as usize, &output).is_err() {
            caller.data_mut().open_failed = true;
            caller.data_mut().protocol_error = Some(format!("must_render_into out pointer out of range at ordinal {ordinal}"));
            return -1;
        }
        output.len() as i32
    }).map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker.func_wrap("qip", "must_render_into_emit_error", |mut caller: Caller<'_, OracleState>, ordinal: i64, message_ptr: i32, message_len: i32| -> i32 {
        if caller.data().open_render_into != Some(ordinal as u64) {
            let open = caller.data().open_render_into;
            caller.data_mut().protocol_error = Some(format!("must_render_into_emit_error ordinal {ordinal} does not match open must_render_into case {open:?}"));
            return 0;
        }
        let Some(message) = oracle_bytes(&mut caller, message_ptr, message_len) else {
            caller.data_mut().protocol_error = Some(format!("must_render_into_emit_error message pointer out of range at ordinal {ordinal}"));
            return 0;
        };
        caller.data_mut().open_errors += 1;
        caller.data_mut().failures.push(format!("case {ordinal}: render_into error: {}", String::from_utf8_lossy(&message)));
        1
    }).map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    linker.func_wrap("qip", "must_render_into_finish", |mut caller: Caller<'_, OracleState>, ordinal: i64, error_count: i32| -> i32 {
        if caller.data().open_render_into != Some(ordinal as u64) {
            let open = caller.data().open_render_into;
            caller.data_mut().protocol_error = Some(format!("must_render_into_finish ordinal {ordinal} does not match open must_render_into case {open:?}"));
            return 0;
        }
        let count = error_count as u32;
        if count != caller.data().open_errors {
            let observed = caller.data().open_errors;
            caller.data_mut().protocol_error = Some(format!("must_render_into_finish ordinal {ordinal} reported {count} errors, host observed {observed}"));
            return 0;
        }
        if caller.data().open_failed && count == 0 {
            caller.data_mut().protocol_error = Some(format!("must_render_into_finish ordinal {ordinal} reported 0 errors after render failure"));
            return 0;
        }
        let state = caller.data_mut();
        if count > 0 { state.fail_count += 1; }
        state.open_render_into = None;
        state.open_failed = false;
        state.open_errors = 0;
        state.next += 1;
        1
    }).map_err(|e| format!("cannot bind Compliance bridge: {e}"))?;
    let instance = linker
        .instantiate(&mut store, &module)
        .map_err(|e| format!("{oracle}: {e}"))?;
    instance
        .get_memory(&mut store, "memory")
        .ok_or_else(|| format!("{oracle} Compliance oracle must export memory"))?;
    if let Some(seed) = seed {
        let function = instance
            .get_typed_func::<i32, ()>(&mut store, "uniform_set_seed")
            .map_err(|_| {
                format!(
                    "{oracle}: --seed given but Compliance oracle does not export uniform_set_seed"
                )
            })?;
        function
            .call(&mut store, seed as i32)
            .map_err(|e| format!("{oracle}: uniform_set_seed failed: {e}"))?;
    }
    let function = instance
        .get_typed_func::<(), i32>(&mut store, "comply")
        .map_err(|_| format!("{oracle} Compliance oracle must export comply() -> i32"))?;
    let declared = function
        .call(&mut store, ())
        .map_err(|e| format!("{oracle}: comply() trapped: {e}"))?;
    let state = store.data();
    if let Some(error) = &state.protocol_error {
        return Err(format!("{oracle}: bridge protocol violation: {error}"));
    }
    if let Some(ordinal) = state.open_render_into {
        return Err(format!(
            "{oracle}: comply() returned with must_render_into case {ordinal} still open"
        ));
    }
    if declared <= 0 || declared as u64 != state.next {
        return Err(format!(
            "{oracle}: comply() returned {declared} cases but host counted {}",
            state.next
        ));
    }
    if let Some(first) = state.failures.first() {
        return Err(format!(
            "{oracle}: {}/{} cases failed; {first}",
            state.fail_count, state.next
        ));
    }
    Ok(state.next)
}

fn comply(args: &[String], hosts: &[String]) -> Result<(), String> {
    let mut files = Vec::new();
    let mut oracles = Vec::new();
    let mut seed = None;
    let mut max_memory = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--with" => {
                index += 1;
                oracles.push(
                    args.get(index)
                        .ok_or("--with requires an oracle path")?
                        .as_str(),
                );
            }
            "--seed" => {
                index += 1;
                let value = args.get(index).ok_or("invalid --seed")?;
                seed = Some(
                    value
                        .parse::<u32>()
                        .map_err(|_| format!("invalid --seed {value}"))?,
                );
            }
            "--max-memory" => {
                index += 1;
                let value = args.get(index).ok_or("invalid --max-memory")?;
                let cap: u64 = value
                    .parse()
                    .map_err(|_| format!("invalid --max-memory {value}"))?;
                if cap == 0 || cap > 9_007_199_254_740_991 {
                    return Err(format!("invalid --max-memory {value}"));
                }
                max_memory = Some(cap);
            }
            arg if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
            path => files.push(path),
        }
        index += 1;
    }
    let mut expanded = Vec::new();
    for file in files {
        collect_wasm_paths(Path::new(file), &mut expanded)?;
    }
    expanded.sort();
    expanded.dedup();
    if expanded.is_empty() {
        return Err("No .wasm files found".into());
    }
    let engine = Engine::default();
    let mut pass = 0;
    let mut fail = 0;
    for file in &expanded {
        match BenchCandidate::load(&engine, file, max_memory, hosts) {
            Ok(_) => {
                println!("PASS {file}");
                pass += 1;
            }
            Err(error) => {
                println!("FAIL {file}: {error}");
                fail += 1;
                continue;
            }
        }
        for oracle in &oracles {
            match run_oracle(&engine, file, oracle, seed, max_memory, hosts) {
                Ok(cases) => {
                    println!("PASS {file} --with {oracle} ({cases} cases)");
                    pass += 1;
                }
                Err(error) => {
                    println!("FAIL {file} --with {oracle}: {error}");
                    fail += 1;
                }
            }
        }
    }
    println!("\npass={pass} fail={fail} total={}", pass + fail);
    if fail != 0 {
        return Err(format!("{fail} Compliance check(s) failed"));
    }
    Ok(())
}

fn collect_wasm_paths(path: &Path, result: &mut Vec<String>) -> Result<(), String> {
    match fs::metadata(path) {
        Ok(meta) if meta.is_dir() => {
            for entry in
                fs::read_dir(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?
            {
                let entry = entry.map_err(|e| format!("cannot read {}: {e}", path.display()))?;
                collect_wasm_paths(&entry.path(), result)?;
            }
        }
        Ok(_) => {
            if path
                .extension()
                .is_some_and(|extension| extension == "wasm")
            {
                result.push(path.to_string_lossy().into_owned());
            }
        }
        Err(error)
            if error.kind() == io::ErrorKind::NotFound
                && remote_eligible(&path.to_string_lossy()) =>
        {
            result.push(path.to_string_lossy().into_owned());
        }
        Err(error) => return Err(format!("cannot read {}: {error}", path.display())),
    }
    Ok(())
}

fn build_form(fields: &[&str], hosts: &[String]) -> Result<Vec<u8>, String> {
    const BOUNDARY: &str = "uuid-00000000-0000-0000-0000-000000000000";
    let mut result = Vec::new();
    let mut used_stdin = false;
    for field in fields {
        let (name, value) = field
            .split_once('=')
            .filter(|(name, _)| !name.is_empty())
            .ok_or_else(|| format!("-F requires <name=value>, got {field:?}"))?;
        if !name
            .bytes()
            .all(|byte| (0x20..=0x7e).contains(&byte) && byte != b'"' && byte != b'\\')
        {
            return Err(format!(
                "multipart field name {name:?} must use printable ASCII without quotes or backslashes"
            ));
        }
        let file = value
            .strip_prefix('@')
            .map(|path| ('@', path))
            .or_else(|| value.strip_prefix('<').map(|path| ('<', path)));
        let (body, filename) = if let Some((mode, path)) = file {
            if path.is_empty() {
                return Err(format!("-F {field:?} has an empty file path"));
            }
            let bytes = if path == "-" {
                if used_stdin {
                    return Err("only one -F field may read from stdin with @- or <-".into());
                }
                used_stdin = true;
                let mut bytes = Vec::new();
                io::stdin()
                    .read_to_end(&mut bytes)
                    .map_err(|e| format!("read -F {name}={mode}-: {e}"))?;
                bytes
            } else {
                if remote_eligible(path) && !hosts.is_empty() {
                    resolve_wasm(path, hosts, |bytes, label| {
                        if !bytes.starts_with(b"\0asm\x01\0\0\0") {
                            return Err(format!("{label} does not have a WebAssembly 1.0 header"));
                        }
                        Ok(())
                    })
                    .map_err(|e| format!("read -F {name}={mode}{path}: {e}"))?
                } else {
                    fs::read(path).map_err(|e| format!("read -F {name}={mode}{path}: {e}"))?
                }
            };
            let filename = if mode == '@' {
                let filename = path.rsplit(['/', '\\']).next().unwrap_or("");
                if filename.is_empty()
                    || !filename
                        .bytes()
                        .all(|byte| (0x20..=0x7e).contains(&byte) && byte != b'"' && byte != b'\\')
                {
                    return Err(format!(
                        "multipart filename {filename:?} must use printable ASCII without quotes or backslashes"
                    ));
                }
                Some(filename)
            } else {
                None
            };
            (bytes, filename)
        } else {
            (value.as_bytes().to_vec(), None)
        };
        let delimiter = format!("\r\n--{BOUNDARY}");
        if body.windows(delimiter.len() + 2).any(|window| {
            window.starts_with(delimiter.as_bytes())
                && (&window[delimiter.len()..] == b"\r\n" || &window[delimiter.len()..] == b"--")
        }) {
            return Err(format!(
                "-F field {name:?} contains the multipart boundary as a delimiter line"
            ));
        }
        let mut header = format!("--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"");
        if let Some(filename) = filename {
            header.push_str(&format!(
                "; filename=\"{filename}\"\r\nContent-Type: application/octet-stream"
            ));
        }
        header.push_str("\r\n\r\n");
        result.extend_from_slice(header.as_bytes());
        result.extend_from_slice(&body);
        result.extend_from_slice(b"\r\n");
    }
    result.extend_from_slice(format!("--{BOUNDARY}--\r\n").as_bytes());
    Ok(result)
}

fn validate_policy(wasm: &[u8], path: &str, max_memory: Option<u64>) -> Result<(), String> {
    let mut exports: HashMap<String, (ExternalKind, u32)> = HashMap::new();
    let mut static_functions = Vec::new();
    let mut memory_count = 0;
    for payload in Parser::new(0).parse_all(wasm) {
        match payload.map_err(|e| format!("{path} is not valid WebAssembly: {e}"))? {
            Payload::ImportSection(imports) if imports.count() != 0 => {
                return Err(format!(
                    "{path} imports host functions or state, which is outside the Strict Wasm Profile"
                ));
            }
            Payload::StartSection { .. } => {
                return Err(format!(
                    "{path} declares a start function, which is outside the Strict Wasm Profile"
                ));
            }
            Payload::MemorySection(memories) => {
                for memory in memories {
                    memory_count += 1;
                    let memory = memory.map_err(|e| format!("{path} has invalid memory: {e}"))?;
                    if memory.shared {
                        return Err(format!(
                            "{path} declares shared memory, which is outside the Strict Wasm Profile"
                        ));
                    }
                    let maximum = memory.maximum.ok_or_else(|| format!("{path} declares memory without a maximum, which is outside the Strict Wasm Profile"))?;
                    if let Some(cap) = max_memory {
                        for (kind, pages) in [("minimum", memory.initial), ("maximum", maximum)] {
                            let bytes = pages.saturating_mul(65_536);
                            if bytes > cap {
                                return Err(format!(
                                    "{path} declares {kind} memory {bytes} bytes, exceeding --max-memory {cap}"
                                ));
                            }
                        }
                    }
                }
            }
            Payload::ExportSection(section) => {
                for export in section {
                    let export =
                        export.map_err(|e| format!("{path} has malformed exports: {e}"))?;
                    exports.insert(export.name.to_owned(), (export.kind, export.index));
                }
            }
            Payload::CodeSectionEntry(body) => {
                let reader = body
                    .get_operators_reader()
                    .map_err(|e| format!("{path} has malformed instructions: {e}"))?;
                let mut is_static = true;
                for operator in reader.into_iter_with_offsets() {
                    let (operator, offset) =
                        operator.map_err(|e| format!("{path} has malformed instructions: {e}"))?;
                    if matches!(operator, Operator::MemoryGrow { .. }) {
                        return Err(format!(
                            "{path} uses memory.grow, which is outside the Strict Wasm Profile"
                        ));
                    }
                    let opcode = wasm[offset as usize];
                    if matches!(opcode, 0x02..=0x04 | 0x0c..=0x0e | 0x10..=0x14 | 0x20..=0x22 | 0x24..=0x40 | 0xfc | 0xfe | 0xd2)
                    {
                        is_static = false;
                    }
                }
                static_functions.push(is_static);
            }
            _ => {}
        }
    }
    if memory_count != 1 {
        return Err(format!("{path} must declare exactly one memory"));
    }
    if exports.get("memory").map(|(kind, _)| *kind) != Some(ExternalKind::Memory) {
        return Err(format!("{path} does not export memory"));
    }
    let require_function = |name: &str| -> Result<u32, String> {
        match exports.get(name) {
            Some((ExternalKind::Func, index)) => Ok(*index),
            Some(_) => Err(format!("{path} export {name} must be a function")),
            None => Err(format!("{path} must export {name}")),
        }
    };
    let require_static = |name: &str| -> Result<(), String> {
        let index = require_function(name)? as usize;
        if !static_functions.get(index).copied().unwrap_or(false) {
            return Err("comply: static qip contract checks failed".into());
        }
        Ok(())
    };
    require_function("render")?;
    let input_ptr = exports.contains_key("input_ptr");
    let input_utf8 = exports.contains_key("input_utf8_cap");
    let input_bytes = exports.contains_key("input_bytes_cap");
    if input_ptr {
        if input_utf8 == input_bytes {
            return Err(format!(
                "{path} transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap"
            ));
        }
    } else if input_utf8 || input_bytes {
        return Err(format!(
            "{path} inputless generator must not export an input capacity"
        ));
    }
    let output_utf8 = exports.contains_key("output_utf8_cap");
    let output_bytes = exports.contains_key("output_bytes_cap");
    if output_utf8 == output_bytes {
        return Err(format!(
            "{path} must export exactly one output capacity: output_utf8_cap or output_bytes_cap"
        ));
    }
    for prefix in ["input", "output"] {
        let pointer = format!("{prefix}_content_type_ptr");
        let size = format!("{prefix}_content_type_size");
        if exports.contains_key(&pointer) != exports.contains_key(&size) {
            return Err(format!(
                "{path} has incomplete {prefix} content-type exports"
            ));
        }
        if prefix == "input" && !input_ptr && exports.contains_key(&pointer) {
            return Err(format!(
                "{path} inputless generator must not declare an input content type"
            ));
        }
    }
    for name in [
        "input_ptr",
        "input_utf8_cap",
        "input_bytes_cap",
        "output_utf8_cap",
        "output_bytes_cap",
        "failure_modes_per_input_offset",
        "input_content_type_ptr",
        "input_content_type_size",
        "output_content_type_ptr",
        "output_content_type_size",
    ] {
        if exports.contains_key(name) {
            require_static(name)?;
        }
    }
    Ok(())
}

fn apply_uniform(
    instance: &Instance,
    store: &mut Store<()>,
    path: &str,
    name: &str,
    raw_value: &str,
) -> Result<(), String> {
    if name.is_empty()
        || name.len() > 63
        || !name.bytes().next().unwrap().is_ascii_lowercase()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        || name.ends_with('_')
        || name.contains("__")
    {
        return Err(format!("{path} has invalid uniform key {name}"));
    }
    let export = format!("uniform_set_{name}");
    let function = instance
        .get_func(&mut *store, &export)
        .ok_or_else(|| format!("{path} does not export {export}"))?;
    let ty = function.ty(&mut *store);
    let params: Vec<_> = ty.params().collect();
    let results: Vec<_> = ty.results().collect();
    if params.len() != 1 || results.len() > 1 {
        return Err(format!("{path} {export} has an invalid signature"));
    }
    let trimmed = raw_value.trim();
    let (negative, unsigned) = if let Some(value) = trimmed.strip_prefix('-') {
        (true, value)
    } else {
        (false, trimmed.strip_prefix('+').unwrap_or(trimmed))
    };
    let number: f64 = if let Some(hex) = unsigned
        .strip_prefix("0x")
        .or_else(|| unsigned.strip_prefix("0X"))
    {
        let integer = u128::from_str_radix(hex, 16)
            .map_err(|_| format!("uniform value {raw_value:?} is not a number"))?;
        (integer as f64) * if negative { -1.0 } else { 1.0 }
    } else {
        trimmed
            .parse()
            .map_err(|_| format!("uniform value {raw_value:?} is not a number"))?
    };
    if !number.is_finite() {
        return Err(format!("uniform value {raw_value:?} is not a number"));
    }
    let value = match &params[0] {
        ValType::I32 => Val::I32(number.trunc().rem_euclid(4_294_967_296.0) as u32 as i32),
        ValType::I64 => Val::I64(number as i64),
        ValType::F32 => Val::F32((number as f32).to_bits()),
        ValType::F64 => Val::F64(number.to_bits()),
        _ => return Err(format!("{path} {export} has an unsupported parameter")),
    };
    let mut output: Vec<Val> = results
        .iter()
        .map(|ty| match ty {
            ValType::I32 => Val::I32(0),
            ValType::I64 => Val::I64(0),
            ValType::F32 => Val::F32(0),
            ValType::F64 => Val::F64(0),
            _ => Val::I32(0),
        })
        .collect();
    function
        .call(store, &[value], &mut output)
        .map_err(|e| format!("{path} {export} trapped: {e}"))
}

fn call_i32(
    instance: &Instance,
    store: &mut Store<()>,
    name: &str,
    path: &str,
) -> Result<i32, String> {
    let function = instance
        .get_typed_func::<(), i32>(&mut *store, name)
        .map_err(|_| format!("{path} must export {name}() -> i32"))?;
    function
        .call(store, ())
        .map_err(|e| format!("{path} {name} trapped: {e}"))
}
