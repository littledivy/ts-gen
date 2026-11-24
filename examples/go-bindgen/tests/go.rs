//! The Go generator (`examples/go-bindgen`), end to end.
//!
//! Every fixture IR (plus go-bindgen's runtime declarations) is lowered
//! under Go's profile (`all-linear, jspi = on`), generated, and compared
//! against `examples/go-bindgen/tests/testdata/snapshots/<fixture>.go`; then all of
//! them are vetted as one module for wasip1. workers-types is generated
//! from the roots a Worker starts from and vetted, and only its skipped
//! list is snapshotted. The runtime's JSON codec is checked against
//! encoding/json natively, and `tests/runtime/run.sh` builds a probe
//! through the bridge and runs it in node.
//!
//! Needs Go 1.24+, and node, wasm-tools and binaryen's wasm-merge for the
//! runtime test; without them a test is skipped locally and fails under
//! `CI`. `TSGEN_SKIP_GO` skips them outright. To update snapshots:
//!
//! ```sh
//! BLESS=1 cargo test --test go
//! ```

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use ts_gen_abi::ir::Ir;
use ts_gen_abi::json;
use ts_gen_abi::profile::Profile;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn go_dir() -> PathBuf {
    root().join("examples/go-bindgen")
}

fn work() -> PathBuf {
    root().join("target/go-test")
}

/// Whether to skip: `TSGEN_SKIP_GO` is set, or a tool is missing, which
/// fails under `CI` instead.
fn skipped(tools: &[&str]) -> bool {
    if std::env::var_os("TSGEN_SKIP_GO").is_some() {
        eprintln!("TSGEN_SKIP_GO is set, skipping");
        return true;
    }
    for t in tools {
        let arg = if *t == "go" { "version" } else { "--version" };
        if Command::new(t).arg(arg).output().is_err() {
            assert!(std::env::var_os("CI").is_none(), "{t} is required under CI");
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

/// The generator, built once.
fn generator() -> PathBuf {
    static BUILT: OnceLock<PathBuf> = OnceLock::new();
    BUILT
        .get_or_init(|| {
            let bin = work().join("go-bindgen");
            run(Command::new("go")
                .current_dir(go_dir())
                .args(["build", "-o"])
                .arg(&bin)
                .arg("."));
            bin
        })
        .clone()
}

fn profile() -> Profile {
    Profile::parse("all-linear, jspi = on").unwrap()
}

/// An IR with go-bindgen's runtime declarations appended, as a build
/// appends `go-bindgen runtime-ir`.
fn parse(src: &str, what: &str, libs: &[Ir]) -> Ir {
    let src = format!("{src}\n{}", include_str!("../runtime/runtime.ir"));
    let ir = ts_gen_abi::text::parse(&src).unwrap_or_else(|e| panic!("{what}: {e}"));
    let opts = ts_gen_abi::validate::Options {
        libs,
        ..Default::default()
    };
    ts_gen_abi::validate::validate_with(&ir, opts).unwrap_or_else(|e| panic!("{what}: {e:?}"));
    ir
}

fn std_ir() -> Ir {
    let src = std::fs::read_to_string(root().join("std/std.ir")).unwrap();
    let ir = ts_gen_abi::text::parse(&src).unwrap();
    ts_gen_abi::validate::validate_with(&ir, Default::default()).unwrap();
    ir
}

/// Generates `ir` (against std) into `<module>/<name>/`, returning the
/// generator's stdout.
fn generate(ir: &Ir, std: &Ir, module: &Path, name: &str, roots: Option<&str>) -> String {
    let std_json = work().join(format!("{name}.std.json"));
    std::fs::write(&std_json, json::lower(std, &profile()).pretty()).unwrap();
    let lowered = work().join(format!("{name}.json"));
    std::fs::write(&lowered, json::lower_with(ir, &[std], &profile()).pretty()).unwrap();
    let pkg = name.replace('-', "_");
    let out = module.join(name);
    let _ = std::fs::remove_dir_all(&out);
    run(Command::new(generator())
        .arg("bindings")
        .arg(&lowered)
        .arg("--lib")
        .arg(&std_json)
        .arg("--out")
        .arg(&out)
        .args(["--package", &pkg])
        .args(roots.map(|r| ["--roots", r]).into_iter().flatten()))
}

fn module(dir: &Path) {
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("go.mod"), "module fixtures\n\ngo 1.24\n").unwrap();
}

/// `go vet` for wasip1. The runtime turns linear-memory addresses into
/// pointers, which unsafeptr flags, so that check is off.
fn vet(dir: &Path) {
    run(Command::new("go")
        .current_dir(dir)
        .env("GOOS", "wasip1")
        .env("GOARCH", "wasm")
        .args(["vet", "-unsafeptr=false", "./..."]));
}

fn compare(path: &Path, actual: &str, failures: &mut Vec<String>) {
    if std::env::var_os("BLESS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(path).unwrap_or_default();
    if expected != actual {
        let diff = similar::TextDiff::from_lines(expected.as_str(), actual)
            .unified_diff()
            .header("expected", "actual")
            .to_string();
        failures.push(format!("{}:\n{diff}", path.display()));
    }
}

#[test]
fn go_fixtures() {
    if skipped(&["go"]) {
        return;
    }
    let std = std_ir();
    let dir = work().join("fixtures");
    module(&dir);
    let mut fixtures = vec![root().join("abi/tests/json/sample.ir")];
    let mut lower: Vec<PathBuf> = std::fs::read_dir(root().join("tests/lower"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "ir"))
        .collect();
    lower.sort();
    fixtures.extend(lower);
    let mut failures = Vec::new();
    for p in &fixtures {
        let name = p.file_stem().unwrap().to_string_lossy().into_owned();
        let ir = parse(
            &std::fs::read_to_string(p).unwrap(),
            &name,
            std::slice::from_ref(&std),
        );
        generate(&ir, &std, &dir, &name, None);
        let actual = std::fs::read_to_string(dir.join(&name).join("bindings.go")).unwrap();
        compare(
            &go_dir()
                .join("tests/testdata/snapshots")
                .join(format!("{name}.go")),
            &actual,
            &mut failures,
        );
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    vet(&dir);
}

/// workers-types, from the roots a Worker starts at: it vets, and what it
/// skips is snapshotted.
#[test]
fn go_workers_types() {
    if skipped(&["go"]) {
        return;
    }
    let std = std_ir();
    let files = vec![root().join("tests/fixtures/workers-types.d.ts")];
    let (m, gctx) = ts_gen::parse(&files, None).unwrap();
    let mut ir = ts_gen::lower::lower(&m, &gctx).ir;
    let runtime = parse("ir 1;", "runtime", &[]);
    ir.items.extend(runtime.items);
    let dir = work().join("workers");
    module(&dir);
    let roots = "URL,Request,Response,Headers,KVNamespace,R2Bucket,D1Database,\
        DurableObjectNamespace,DurableObjectState,Queue,Fetcher,HTMLRewriter,Date,console,fetch,atob";
    generate(&ir, &std, &dir, "workers", Some(roots));
    vet(&dir);
    let skipped = std::fs::read_to_string(dir.join("workers/skipped.txt")).unwrap();
    let mut failures = Vec::new();
    compare(
        &go_dir().join("tests/testdata/snapshots/workers-types.skipped"),
        &skipped,
        &mut failures,
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// The runtime's JSON codec against encoding/json (tests/testdata/json_test.go).
#[test]
fn go_json_codec() {
    if skipped(&["go"]) {
        return;
    }
    let dir = work().join("codec");
    module(&dir);
    let src = std::fs::read_to_string(go_dir().join("runtime/json.go"))
        .unwrap()
        .replace("//go:build tsgen_runtime\n\n", "")
        .replace("package tsgenruntime", "package codec");
    std::fs::write(dir.join("json.go"), src).unwrap();
    std::fs::copy(
        go_dir().join("tests/testdata/json_test.go"),
        dir.join("json_test.go"),
    )
    .unwrap();
    run(Command::new("go").current_dir(&dir).args(["test", "./..."]));
}

/// The probe's Go exports through the bridge, in node
/// (`tests/runtime/run.sh`).
#[test]
fn go_runtime() {
    if skipped(&["go", "node", "wasm-tools", "wasm-merge"]) {
        return;
    }
    let out = run(&mut Command::new(go_dir().join("tests/runtime/run.sh")));
    eprintln!("{out}");
    for want in [
        "check(0) = RangeError: zero",
        "overlapped=true",
        "release() live = 0",
    ] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
}
