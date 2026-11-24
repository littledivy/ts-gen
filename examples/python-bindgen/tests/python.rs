//! The Python example (`examples/python-bindgen`), end to end.
//!
//! `generic.ir`, lowered under the Python Worker's profile, is generated
//! into its C header and, against `tests/fixtures/core.wat`, its Wasm shim,
//! and both are compared against `tests/snapshots/`; the shim must also
//! assemble.
//!
//! The generator needs python3; without it a test is skipped.
//! `TSGEN_SKIP_PYTHON` skips them all. To update snapshots:
//!
//! ```sh
//! BLESS=1 cargo test --test python
//! ```

use std::path::{Path, PathBuf};
use std::process::Command;

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
