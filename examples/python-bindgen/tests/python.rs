//! The Python example (`examples/python-bindgen`), end to end.
//!
//! `generic.ir`, lowered under the Python Worker's profile, is generated
//! into its C header and, against `tests/fixtures/core.wat`, its Wasm shim,
//! and both are compared against `tests/snapshots/`; the shim must also
//! assemble. Then the Worker itself is built with `build.sh` and checked
//! with `e2e.sh` under `wrangler dev`.
//!
//! The generator needs python3. The Worker needs wasmtime, wasm-tools,
//! binaryen's wasm-merge, python3.13 and the example's npm packages
//! (`npm install` there), and builds CPython and wasi-sdk into `deps/` the
//! first time, which takes a while. Without a tool a test is skipped.
//! `TSGEN_SKIP_PYTHON` skips them all, and `TSGEN_SKIP_PYTHON_WORKER` only
//! the Worker. To update snapshots:
//!
//! ```sh
//! BLESS=1 cargo test --test python
//! ```

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use ts_gen_abi::json;
use ts_gen_abi::profile::Profile;

const PROFILE: &str = "all-linear, jspi = on, box-none = unit";

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn dir() -> PathBuf {
    root().join("examples/python-bindgen")
}

fn work() -> PathBuf {
    let w = root().join("target/python-test");
    std::fs::create_dir_all(&w).unwrap();
    w
}

/// Whether to skip: `TSGEN_SKIP_PYTHON` or one of `envs` is set, or a tool
/// is missing.
fn skipped(envs: &[&str], tools: &[&str]) -> bool {
    for e in ["TSGEN_SKIP_PYTHON"].iter().chain(envs) {
        if std::env::var_os(e).is_some() {
            eprintln!("{e} is set, skipping");
            return true;
        }
    }
    for t in tools {
        if Command::new(t).arg("--version").output().is_err() {
            eprintln!("skipping: {t} not found");
            return true;
        }
    }
    false
}

fn run(cmd: &mut Command) -> String {
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{cmd:?}:\n{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn snapshot(name: &str, got: &str) {
    let path = dir().join("tests/snapshots").join(name);
    if std::env::var_os("BLESS").is_some() {
        std::fs::write(&path, got).unwrap();
        return;
    }
    let want = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        want == got,
        "{} differs (BLESS=1 to update)",
        path.display()
    );
}

/// The lowered JSON of generic.ir, written for the generator.
fn lowered() -> PathBuf {
    let src = std::fs::read_to_string(dir().join("generic.ir")).unwrap();
    let ir = ts_gen_abi::text::parse(&src).unwrap();
    ts_gen_abi::validate::validate_with(&ir, Default::default()).unwrap();
    let path = work().join("generic.json");
    std::fs::write(
        &path,
        json::lower(&ir, &Profile::parse(PROFILE).unwrap()).pretty(),
    )
    .unwrap();
    path
}

fn bindgen(args: &[&str]) -> Command {
    let mut c = Command::new("python3");
    c.arg(dir().join("bindgen.py")).args(args);
    c
}

#[test]
fn header() {
    if skipped(&[], &["python3"]) {
        return;
    }
    let out = work().join("tsgen_imports.h");
    run(bindgen(&["header"]).arg(lowered()).arg("-o").arg(&out));
    snapshot("generic.h", &std::fs::read_to_string(out).unwrap());
}

#[test]
fn shim() {
    if skipped(&[], &["python3"]) {
        return;
    }
    let core = work().join("core.wasm");
    let src = std::fs::read_to_string(dir().join("tests/fixtures/core.wat")).unwrap();
    std::fs::write(&core, wat::parse_str(&src).unwrap()).unwrap();
    let out = work().join("shim.wat");
    run(bindgen(&["shim"])
        .arg(lowered())
        .arg(&core)
        .args(["--c-module", "python", "--defer", "later()", "-o"])
        .arg(&out));
    let shim = std::fs::read_to_string(&out).unwrap();
    wat::parse_str(&shim).unwrap_or_else(|e| panic!("shim.wat: {e}"));
    snapshot("generic.shim.wat", &shim);
}

/// The listening Worker, stopped with its process group.
struct Dev(Child);

impl Drop for Dev {
    fn drop(&mut self) {
        let _ = Command::new("kill")
            .arg("--")
            .arg(format!("-{}", self.0.id()))
            .status();
        let _ = self.0.wait();
    }
}

#[test]
fn worker() {
    let wrangler = dir().join("node_modules/.bin/wrangler");
    let tools = [
        "python3.13",
        "wasmtime",
        "wasm-tools",
        "wasm-merge",
        "node",
        "curl",
    ];
    if skipped(&["TSGEN_SKIP_PYTHON_WORKER"], &tools) {
        return;
    }
    if !wrangler.exists() {
        eprintln!("skipping: run `npm install` in {}", dir().display());
        return;
    }
    let out = work().join("worker");
    run(Command::new(dir().join("build.sh")).env("OUTDIR", &out));
    // A wrangler.toml beside the build, with the example's bindings.
    let toml = std::fs::read_to_string(dir().join("wrangler.toml"))
        .unwrap()
        .replace("main = \"out/entry.js\"", "main = \"entry.js\"");
    std::fs::write(out.join("wrangler.toml"), toml).unwrap();
    let port = std::env::var("TSGEN_PYTHON_PORT").unwrap_or_else(|_| "8971".into());
    let mut cmd = Command::new(&wrangler);
    cmd.args(["dev", "--port", &port, "--ip", "127.0.0.1"])
        .current_dir(&out)
        .env("WRANGLER_SEND_METRICS", "false")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let _dev = Dev(cmd.spawn().unwrap());
    let url = format!("http://127.0.0.1:{port}/");
    let start = Instant::now();
    while !Command::new("curl")
        .args(["-sf", "-o", "/dev/null", &url])
        .status()
        .unwrap()
        .success()
    {
        assert!(
            start.elapsed() < Duration::from_secs(90),
            "wrangler dev didn't start"
        );
        std::thread::sleep(Duration::from_millis(500));
    }
    let report = run(Command::new("bash")
        .arg(dir().join("e2e.sh"))
        .args([&port, "Python"]));
    assert_eq!(
        report.lines().filter(|l| l.starts_with("ok ")).count(),
        11,
        "{report}"
    );
}
