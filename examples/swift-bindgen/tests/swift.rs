//! The Swift generator (`examples/swift-bindgen`), end to end.
//!
//! Every fixture IR, with the Swift runtime's declarations
//! (`swift-bindgen runtime-ir`) appended, is lowered under Swift's profile
//! (`all-linear, jspi = on`), generated with `--public` and a scaffold app,
//! and compared against `examples/swift-bindgen/tests/snapshots/<fixture>/`.
//! Then each compiles as its own Swift module for wasm32-unknown-wasip1,
//! gets its shim merged in, and the merged module's interop surface is
//! checked against the lowered layouts: every import is `(module, key)`
//! with its core wire type, and every export is named by its key with its
//! own. workers-types is compiled and checked, but only its skipped list is
//! snapshotted.
//!
//! Needs a Swift toolchain with its Swift SDK for WASI
//! (`examples/swift-bindgen/swiftc-wasm.sh --check` finds both), binaryen's
//! `wasm-merge`, and node (26+) for the worker; without them a test is
//! skipped, and fails instead when `TSGEN_REQUIRE_SWIFT` is set (a CI job
//! that installs them). `TSGEN_SKIP_SWIFT` skips them outright. To update
//! snapshots:
//!
//! ```sh
//! BLESS=1 cargo test --test swift
//! ```

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};

use ts_gen_abi::ir::Ir;
use ts_gen_abi::json::{self, Json};
use ts_gen_abi::profile::Profile;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn swift_dir() -> PathBuf {
    root().join("examples/swift-bindgen")
}

fn work() -> PathBuf {
    root().join("target/swift-test")
}

/// Whether to skip: `TSGEN_SKIP_SWIFT` is set, or a tool is missing (the
/// Swift toolchain and SDK, `wasm-merge`, and node when `node`), which
/// fails under `TSGEN_REQUIRE_SWIFT` instead.
fn skipped(node: bool) -> bool {
    if std::env::var_os("TSGEN_SKIP_SWIFT").is_some() {
        eprintln!("TSGEN_SKIP_SWIFT is set, skipping");
        return true;
    }
    let found = |cmd: &mut Command| cmd.output().is_ok_and(|o| o.status.success());
    let missing = if !found(Command::new(swift_dir().join("swiftc-wasm.sh")).arg("--check")) {
        "a Swift toolchain with its Swift SDK for WASI"
    } else if !found(Command::new("wasm-merge").arg("--version")) {
        "wasm-merge (binaryen)"
    } else if node && !found(Command::new("node").arg("--version")) {
        "node"
    } else {
        return false;
    };
    assert!(
        !required(),
        "{missing} is required under TSGEN_REQUIRE_SWIFT"
    );
    eprintln!("skipping: {missing} not found");
    true
}

fn required() -> bool {
    std::env::var_os("TSGEN_REQUIRE_SWIFT").is_some()
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

/// The generator, built once with the host's `swift`.
fn generator() -> PathBuf {
    static BUILT: OnceLock<()> = OnceLock::new();
    BUILT.get_or_init(|| {
        run(Command::new("swift")
            .args(["build", "-c", "release", "--package-path"])
            .arg(swift_dir()));
    });
    swift_dir().join(".build/release/swift-bindgen")
}

/// The Swift runtime's declarations, which every IR the bindings are
/// generated for carries.
fn runtime_ir() -> Ir {
    // Declarations to append to an IR, so without the IR's header.
    let src = run(Command::new(generator()).arg("runtime-ir"));
    ts_gen_abi::text::parse(&format!("ir 1;\n{src}")).unwrap()
}

/// The profile Swift generates for: linear carriers, and JSPI, since
/// Swift's executor runs its tasks synchronously.
fn swift_profile() -> Profile {
    Profile::parse("all-linear, jspi = on").unwrap()
}

struct Fixture {
    name: String,
    ir: Ir,
    snapshot: bool,
}

fn parse(path: &Path, libs: &[Ir]) -> Ir {
    let src = std::fs::read_to_string(path).unwrap();
    let ir = ts_gen_abi::text::parse(&src).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let opts = ts_gen_abi::validate::Options {
        libs,
        ..Default::default()
    };
    ts_gen_abi::validate::validate_with(&ir, opts).unwrap();
    ir
}

/// The fixtures, each with the runtime's declarations; `std` is the lib
/// the fixtures that name it resolve against.
fn fixtures(std: &Ir) -> Vec<Fixture> {
    let libs = [std.clone()];
    let mut out = vec![Fixture {
        name: "sample".into(),
        ir: parse(&root().join("abi/tests/json/sample.ir"), &[]),
        snapshot: true,
    }];
    let mut lower: Vec<PathBuf> = std::fs::read_dir(root().join("tests/lower"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "ir"))
        .collect();
    lower.sort();
    for p in lower {
        out.push(Fixture {
            name: p.file_stem().unwrap().to_string_lossy().into(),
            ir: parse(&p, &libs),
            snapshot: true,
        });
    }
    let files = vec![root().join("tests/fixtures/workers-types.d.ts")];
    let (module, gctx) = ts_gen::parse(&files, None).unwrap();
    out.push(Fixture {
        name: "workers-types".into(),
        ir: ts_gen::lower::lower(&module, &gctx).ir,
        snapshot: false,
    });
    let rt = runtime_ir();
    for f in &mut out {
        f.ir.items.extend(rt.items.iter().cloned());
    }
    out
}

fn files(dir: &Path, base: &Path, out: &mut BTreeMap<String, String>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            files(&p, base, out);
        } else {
            let rel = p
                .strip_prefix(base)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            out.insert(rel, std::fs::read_to_string(&p).unwrap());
        }
    }
}

/// What the lowered JSON says the module imports and exports, with core
/// types: members, callback call imports and trampolines.
#[derive(Default)]
struct Surface {
    imports: BTreeMap<(String, String), String>,
    exports: BTreeMap<String, String>,
    /// Imports a module may have but needn't: the operations of the
    /// futures, boxes and enums it reads, and the runtime's.
    optional: BTreeMap<(String, String), String>,
}

fn get<'a>(o: &'a [(String, Json)], k: &str) -> Option<&'a Json> {
    o.iter().find(|(n, _)| n == k).map(|(_, v)| v)
}

fn s(j: Option<&Json>) -> String {
    match j {
        Some(Json::Str(s)) => s.clone(),
        _ => String::new(),
    }
}

fn strs(j: Option<&Json>) -> Vec<String> {
    match j {
        Some(Json::Arr(xs)) => xs.iter().map(|x| s(Some(x))).collect(),
        _ => Vec::new(),
    }
}

fn import_key(o: &Json) -> (String, String) {
    let Json::Obj(o) = o else { unreachable!() };
    (s(get(o, "module")), s(get(o, "name")))
}

/// `(params) -> (results)` of an object with `params` and `results`.
fn ft(o: &[(String, Json)]) -> String {
    let list = |k| strs(get(o, k)).join(", ");
    format!("({}) -> ({})", list("params"), list("results"))
}

fn core(sig: &Json) -> String {
    let Json::Obj(o) = sig else {
        return String::new();
    };
    match get(o, "core") {
        Some(Json::Obj(c)) => ft(c),
        _ => String::new(),
    }
}

/// `, s0, s1..`: an enum layout's slot types.
fn enum_slots(e: Option<&Json>) -> String {
    let Some(Json::Obj(e)) = e else {
        return String::new();
    };
    let Some(Json::Obj(shape)) = get(e, "shape") else {
        return String::new();
    };
    strs(get(shape, "slots"))
        .iter()
        .map(|t| format!(", {t}"))
        .collect()
}

/// What the runtime (`Runtime.swift`) adds: the future operations it
/// drives tasks with, the boxes and `TsgenValue` unbox Codable goes
/// through, and the wake it exports.
fn runtime(lowered: &Json, out: &mut Surface) {
    for (m, n, t) in [
        ("tw:future", "poll", "(externref, i32) -> (i32)"),
        ("tw:future", "drop", "(externref) -> ()"),
        ("tw:future", "wait", "(i32) -> ()"),
        ("tw:future", "new", "() -> (externref, externref)"),
        ("tw:box", "str", "(i32, i32) -> (externref)"),
        ("tw:box", "f64", "(f64) -> (externref)"),
        ("tw:box", "bool", "(i32) -> (externref)"),
        ("tw:box", "arr<Any?>", "(i32, i32) -> (externref)"),
    ] {
        out.optional.insert((m.into(), n.into()), t.into());
    }
    let Json::Obj(o) = lowered else {
        unreachable!()
    };
    let value = match get(o, "decls") {
        Some(Json::Arr(ds)) => ds.iter().find_map(|d| match d {
            Json::Obj(d) if s(get(d, "path")) == "TsgenValue" => get(d, "layout"),
            _ => None,
        }),
        _ => None,
    };
    out.optional.insert(
        ("tw:unbox".into(), "TsgenValue?".into()),
        format!("(externref) -> (i32{})", enum_slots(value)),
    );
    out.exports
        .insert("tw:future/wake".into(), "(i32) -> ()".into());
}

fn walk(j: &Json, out: &mut Surface) {
    match j {
        Json::Obj(o) => {
            if let (Some(key), Some(sig)) = (get(o, "key"), get(o, "sig")) {
                let key = s(Some(key));
                if s(get(o, "role")) == "import" {
                    out.imports.insert((s(get(o, "module")), key), core(sig));
                } else {
                    out.exports.insert(key, core(sig));
                }
            }
            // `tw:new` and the `tw:unbox` recovering its instance.
            if let (Some(key), Some(c @ Json::Obj(_)), Some(owner)) =
                (get(o, "key"), get(o, "construct"), get(o, "owner"))
            {
                out.optional
                    .insert(("tw:new".into(), s(Some(key))), core(c));
                out.optional.insert(
                    ("tw:unbox".into(), s(Some(owner))),
                    "(externref) -> (externref)".into(),
                );
            }
            // A boxed value's `tw:box` and `tw:unbox`, of its inner wire.
            if let (Some(Json::Str(of)), Some(Json::Obj(inner))) = (get(o, "of"), get(o, "inner")) {
                if of == "box" {
                    let wire = strs(get(inner, "wire")).join(", ");
                    for (k, t) in [
                        ("box", format!("({wire}) -> (externref)")),
                        ("unbox", format!("(externref) -> ({wire})")),
                    ] {
                        if let Some(i @ Json::Obj(_)) = get(o, k) {
                            out.optional.insert(import_key(i), t);
                        }
                    }
                }
            }
            // A box helper's `tw:box` and `tw:unbox`.
            for k in ["box", "unbox"] {
                if let Some(Json::Obj(b)) = get(o, k) {
                    if let Some(i) = get(b, "import") {
                        out.optional.insert(import_key(i), ft(b));
                    }
                }
            }
            if let (Some(t), Some(op)) = (get(o, "trampoline"), get(o, "op")) {
                out.exports.insert(s(Some(t)), core(op));
            }
            if let (Some(t), Some(Json::Obj(v))) = (get(o, "take"), get(o, "value")) {
                let wire = strs(get(v, "wire"));
                out.optional.insert(
                    import_key(t),
                    format!("(externref) -> ({})", wire.join(", ")),
                );
                out.optional.insert(
                    import_key(get(o, "resolve").unwrap()),
                    format!(
                        "({}) -> ()",
                        [vec!["externref".into()], wire].concat().join(", ")
                    ),
                );
                let slots = enum_slots(get(o, "rejection"));
                out.optional.insert(
                    import_key(get(o, "errorOp").unwrap()),
                    format!("(externref) -> (i32{slots})"),
                );
                out.optional.insert(
                    import_key(get(o, "reject").unwrap()),
                    format!("(externref, i32{slots}) -> ()"),
                );
            }
            if let (Some(Json::Obj(c)), Some(op)) = (get(o, "call"), get(o, "op")) {
                out.imports
                    .insert((s(get(c, "module")), s(get(c, "name"))), core(op));
            }
            for (_, v) in o {
                walk(v, out);
            }
        }
        Json::Arr(xs) => xs.iter().for_each(|x| walk(x, out)),
        _ => {}
    }
}

fn val(v: &wasmparser::ValType) -> String {
    use wasmparser::ValType::*;
    match v {
        I32 => "i32".into(),
        I64 => "i64".into(),
        F32 => "f32".into(),
        F64 => "f64".into(),
        V128 => "v128".into(),
        Ref(r) if *r == wasmparser::RefType::EXTERNREF => "externref".into(),
        Ref(r) => format!("{r:?}"),
    }
}

/// A compiled module's imports `(module, name, type)` and exports
/// `name -> type`.
type Signatures = (Vec<(String, String, String)>, BTreeMap<String, String>);

fn compiled(wasm: &[u8]) -> Signatures {
    use wasmparser::{CompositeInnerType, ExternalKind, Parser, Payload, TypeRef};
    let mut types = Vec::new();
    let mut funcs = Vec::new();
    let mut imports = Vec::new();
    let mut exports = BTreeMap::new();
    let fmt = |f: &wasmparser::FuncType| {
        let l = |vs: &[wasmparser::ValType]| vs.iter().map(val).collect::<Vec<_>>().join(", ");
        format!("({}) -> ({})", l(f.params()), l(f.results()))
    };
    for p in Parser::new(0).parse_all(wasm) {
        match p.unwrap() {
            Payload::TypeSection(r) => {
                for g in r {
                    for t in g.unwrap().into_types() {
                        types.push(match &t.composite_type.inner {
                            CompositeInnerType::Func(f) => Some(fmt(f)),
                            _ => None,
                        });
                    }
                }
            }
            Payload::ImportSection(r) => {
                for i in r.into_imports() {
                    let i = i.unwrap();
                    if let TypeRef::Func(t) = i.ty {
                        funcs.push(t);
                        let ty = types[t as usize].clone().unwrap();
                        imports.push((i.module.to_string(), i.name.to_string(), ty));
                    }
                }
            }
            Payload::FunctionSection(r) => {
                for f in r {
                    funcs.push(f.unwrap());
                }
            }
            Payload::ExportSection(r) => {
                for e in r {
                    let e = e.unwrap();
                    if e.kind == ExternalKind::Func {
                        let t = funcs[e.index as usize];
                        exports.insert(e.name.to_string(), types[t as usize].clone().unwrap());
                    }
                }
            }
            _ => {}
        }
    }
    (imports, exports)
}

/// The generated files of one fixture, its surface, and the merged module
/// or the reason it didn't build.
struct Built {
    name: String,
    files: BTreeMap<String, String>,
    surface: Surface,
    module: Result<Vec<u8>, String>,
}

/// Lowers, generates, compiles and merges one fixture.
fn build(f: &Fixture, std: &Ir, profile: &Profile) -> Built {
    let dir = work().join("check").join(&f.name);
    let _ = std::fs::remove_dir_all(&dir);
    let gen = dir.join("gen");
    std::fs::create_dir_all(&gen).unwrap();
    let libs: Vec<&Ir> = if f.ir.with.iter().any(|w| w == "std") {
        vec![std]
    } else {
        Vec::new()
    };
    let lowered = json::lower_with(&f.ir, &libs, profile);
    let input = dir.join("lowered.json");
    std::fs::write(&input, lowered.pretty()).unwrap();
    let mut cmd = Command::new(generator());
    cmd.arg("bindings").arg(&input).arg("--out").arg(&gen);
    if !libs.is_empty() {
        let lib = work().join("std.json");
        cmd.arg("--lib").arg(lib);
    }
    let app = dir.join("App.swift");
    cmd.args(["--public", "--runtime", "--scaffold"]).arg(&app);
    run(&mut cmd);
    let mut out = BTreeMap::new();
    files(&gen, &gen, &mut out);
    let mut surface = Surface::default();
    walk(&lowered, &mut surface);
    // The bindings bind the lib's members too.
    for lib in &libs {
        walk(&json::lower(lib, profile), &mut surface);
    }
    runtime(&lowered, &mut surface);
    let module = (|| {
        let swift = dir.join("swift.wasm");
        let status = Command::new(swift_dir().join("swiftc-wasm.sh"))
            .args(["-module-name", "Fixture", "-Xcc"])
            .arg(format!(
                "-fmodule-map-file={}",
                gen.join("include/module.modulemap").display()
            ))
            .arg("-I")
            .arg(gen.join("include"))
            // Every member stays, so each import is checked: the optimizer
            // drops the public members an executable doesn't call.
            .args(["-Xlinker", "--no-gc-sections", "-Onone"])
            .arg(&app)
            .arg(gen.join("Runtime.swift"))
            .arg(gen.join("Bindings.swift"))
            .arg("-o")
            .arg(&swift)
            .output()
            .unwrap();
        if !status.status.success() {
            return Err(format!(
                "swiftc:\n{}",
                String::from_utf8_lossy(&status.stderr)
            ));
        }
        let shim = dir.join("shim.wat");
        run(Command::new(generator())
            .arg("shim")
            .arg(gen.join("manifest.json"))
            .arg(&swift)
            .arg("-o")
            .arg(&shim));
        let merged = dir.join("app.wasm");
        run(Command::new("wasm-merge")
            .arg(&swift)
            .arg("swift")
            .arg(&shim)
            .arg("shim")
            .arg("-o")
            .arg(&merged)
            .args(merge_features()));
        Ok(std::fs::read(&merged).unwrap())
    })();
    Built {
        name: f.name.clone(),
        files: out,
        surface,
        module,
    }
}

/// The features wasm-merge keeps, named one by one: `-all` writes import
/// encodings V8 doesn't read.
fn merge_features() -> [&'static str; 8] {
    [
        "--enable-reference-types",
        "--enable-exception-handling",
        "--enable-multivalue",
        "--enable-bulk-memory",
        "--enable-sign-ext",
        "--enable-mutable-globals",
        "--enable-nontrapping-float-to-int",
        "--enable-simd",
    ]
}

/// The files a snapshot keeps: the bindings, the header and the skipped
/// list (the manifest's `skipped`), or only the skipped list.
fn snapshot_files(out: &BTreeMap<String, String>, full: bool) -> BTreeMap<String, String> {
    let mut snap = BTreeMap::new();
    let manifest = out.get("manifest.json").expect("manifest.json");
    let mut skipped = String::new();
    let m: serde_json::Value = serde_json::from_str(manifest).expect("manifest.json");
    for x in m["skipped"].as_array().into_iter().flatten() {
        let field = |k: &str| x[k].as_str().unwrap_or_default().to_string();
        skipped.push_str(&format!("{}: {}\n", field("key"), field("why")));
    }
    snap.insert("skipped.txt".to_string(), skipped);
    if full {
        for k in ["Bindings.swift", "include/TSGenImports.h"] {
            snap.insert(k.to_string(), out[k].clone());
        }
    }
    snap
}

#[test]
fn swift() {
    if skipped(false) {
        return;
    }
    let bless = std::env::var_os("BLESS").is_some();
    let profile = swift_profile();
    std::fs::create_dir_all(work()).unwrap();
    let std = parse(&root().join("std/std.ir"), &[]);
    std::fs::write(
        work().join("std.json"),
        json::lower(&std, &profile).pretty(),
    )
    .unwrap();
    let fixtures = fixtures(&std);
    // Each fixture compiles on its own; a few at a time.
    let jobs = std::thread::available_parallelism().map_or(2, |n| n.get().div_ceil(2));
    let queue = Mutex::new(fixtures.iter());
    let built = Mutex::new(Vec::new());
    std::thread::scope(|sc| {
        for _ in 0..jobs {
            sc.spawn(|| loop {
                let Some(f) = queue.lock().unwrap().next() else {
                    break;
                };
                let b = build(f, &std, &profile);
                built.lock().unwrap().push((f.snapshot, b));
            });
        }
    });
    let mut built = built.into_inner().unwrap();
    built.sort_by(|a, b| a.1.name.cmp(&b.1.name));
    let mut failures = Vec::new();
    for (full, b) in &built {
        let actual = snapshot_files(&b.files, *full);
        let snap = swift_dir().join("tests/snapshots").join(&b.name);
        if bless {
            let _ = std::fs::remove_dir_all(&snap);
            for (rel, text) in &actual {
                let p = snap.join(rel);
                std::fs::create_dir_all(p.parent().unwrap()).unwrap();
                std::fs::write(p, text).unwrap();
            }
        } else {
            let mut want = BTreeMap::new();
            if snap.exists() {
                files(&snap, &snap, &mut want);
            }
            let names: BTreeSet<&String> = want.keys().chain(actual.keys()).collect();
            for n in names {
                if want.get(n) != actual.get(n) {
                    let diff = similar::TextDiff::from_lines(
                        want.get(n).map_or("", String::as_str),
                        actual.get(n).map_or("", String::as_str),
                    );
                    failures.push(format!(
                        "{}/{n} differs:\n{}",
                        b.name,
                        diff.unified_diff().context_radius(2)
                    ));
                }
            }
        }
        match &b.module {
            Ok(wasm) => check_surface(&b.name, &b.surface, &b.files, wasm, &mut failures),
            Err(e) => failures.push(format!("{}: {e}", b.name)),
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// Checks one merged module against its lowered layouts.
fn check_surface(
    name: &str,
    surface: &Surface,
    out: &BTreeMap<String, String>,
    wasm: &[u8],
    failures: &mut Vec<String>,
) {
    let (imports, exports) = compiled(wasm);
    let skipped: BTreeSet<String> = snapshot_files(out, false)["skipped.txt"]
        .lines()
        .filter_map(|l| l.split(": ").next().map(str::to_string))
        .collect();
    let want_imports: BTreeMap<_, _> = surface
        .imports
        .iter()
        .filter(|(k, _)| !skipped.contains(&k.1))
        .collect();
    let mut seen = BTreeSet::new();
    for (module, field, ty) in &imports {
        if module.starts_with("wasi_") {
            continue;
        }
        let key = (module.clone(), field.clone());
        match want_imports.get(&key) {
            Some(want) if *want == ty => {}
            Some(want) => failures.push(format!(
                "{name}: import {key:?} is {ty}, the layout says {want}"
            )),
            None if surface.optional.get(&key) == Some(ty) => {}
            None => failures.push(format!(
                "{name}: import {key:?} ({ty}) is no member's or operation's"
            )),
        }
        seen.insert(key);
    }
    for key in want_imports.keys() {
        if !seen.contains(*key) && !key.0.starts_with("tw:call") {
            failures.push(format!(
                "{name}: import {key:?} is missing from the compiled module"
            ));
        }
    }
    for (key, want) in &surface.exports {
        if skipped.contains(key) {
            continue;
        }
        match exports.get(key) {
            Some(ty) if ty == want => {}
            Some(ty) => failures.push(format!(
                "{name}: export {key} is {ty}, the layout says {want}"
            )),
            None if key.starts_with("tw:call:") => {}
            None => failures.push(format!(
                "{name}: export {key} is missing from the compiled module"
            )),
        }
    }
}

/// `examples/swift-bindgen/example` end to end in node, through the merged
/// module and its bridge: the routes of the tour node can serve.
#[test]
fn swift_worker() {
    if skipped(true) {
        return;
    }
    tour("node", "tour.node.txt");
}

/// `examples/swift-bindgen/example` served by workerd (`WORKERD`, else
/// `workerd` on the path): the whole tour, with its Durable Object and
/// second service. Without workerd it is skipped, and fails under
/// `TSGEN_REQUIRE_SWIFT`.
#[test]
fn swift_worker_workerd() {
    if skipped(true) {
        return;
    }
    let workerd = std::env::var_os("WORKERD").unwrap_or_else(|| "workerd".into());
    if Command::new(workerd).arg("--version").output().is_err() {
        assert!(!required(), "workerd is required under TSGEN_REQUIRE_SWIFT");
        eprintln!("skipping: workerd not found");
        return;
    }
    tour("serve", "tour.txt");
}

/// What a mode of the worker's `run.sh` prints from its first route on,
/// against the copy the example keeps. The two modes share a build
/// directory, so one runs at a time.
fn tour(mode: &str, recorded: &str) {
    static BUILD: Mutex<()> = Mutex::new(());
    let _one = BUILD.lock().unwrap_or_else(|e| e.into_inner());
    generator();
    let dir = swift_dir().join("example");
    let stdout = run(Command::new(dir.join("run.sh"))
        .arg(mode)
        .env("TSGEN_SWIFT_BUILT", "1"));
    let actual = stdout.find("== ").map_or(stdout.as_str(), |i| &stdout[i..]);
    let recorded = dir.join(recorded);
    if std::env::var_os("BLESS").is_some() {
        std::fs::write(&recorded, actual).unwrap();
        return;
    }
    assert_eq!(
        actual,
        std::fs::read_to_string(&recorded).unwrap_or_default()
    );
}
