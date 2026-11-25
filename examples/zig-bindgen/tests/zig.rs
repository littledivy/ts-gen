//! The Zig generator (`examples/zig-bindgen`), end to end.
//!
//! Every fixture IR is lowered under Zig's profile (`all-linear` with
//! `jspi = on`), generated, and compared against
//! `examples/zig-bindgen/tests/snapshots/<fixture>/`. Then each compiles as
//! its own wasm32 module, with every function whose types are concrete
//! kept, and its interop surface is checked against the lowered layouts:
//! the module's imports through the shim name a manifest entry and have
//! its wire types (slots for externrefs, a return area when needed), each
//! manifest entry has its member's or operation's core type, and the shim
//! zig-bindgen writes for the module validates and imports and exports
//! exactly those types. workers-types and std are compiled and checked,
//! but only their skipped lists are snapshotted.
//!
//! Needs Zig 0.17, and for the worker's tours binaryen's wasm-merge, node
//! (26+) and workerd; without them a test is skipped, or fails when
//! `TSGEN_REQUIRE_ZIG` is set. `TSGEN_SKIP_ZIG` skips them outright. To
//! update snapshots:
//!
//! ```sh
//! BLESS=1 cargo test --test zig
//! ```

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};

use ts_gen_abi::ir::Ir;
use ts_gen_abi::json::{self, Json};
use ts_gen_abi::profile::Profile;

const PROFILE: &str = "all-linear, jspi = on";

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

fn zig_dir() -> PathBuf {
    root().join("examples/zig-bindgen")
}

fn work() -> PathBuf {
    root().join("target/zig-test")
}

/// Whether a missing tool fails rather than skips.
fn required() -> bool {
    std::env::var_os("TSGEN_REQUIRE_ZIG").is_some()
}

/// Whether to skip: `TSGEN_SKIP_ZIG` is set, or a tool is missing (zig,
/// and wasm-merge and node when `worker`), which fails under
/// `TSGEN_REQUIRE_ZIG` instead.
fn skipped(worker: bool) -> bool {
    if std::env::var_os("TSGEN_SKIP_ZIG").is_some() {
        eprintln!("TSGEN_SKIP_ZIG is set, skipping");
        return true;
    }
    let missing = if Command::new("zig").arg("version").output().is_err() {
        "zig"
    } else if worker
        && Command::new("wasm-merge")
            .arg("--version")
            .output()
            .is_err()
    {
        "wasm-merge"
    } else if worker && Command::new("node").arg("--version").output().is_err() {
        "node"
    } else {
        return false;
    };
    assert!(!required(), "{missing} is required under TSGEN_REQUIRE_ZIG");
    eprintln!("skipping: {missing} not found");
    true
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
    static BUILT: OnceLock<()> = OnceLock::new();
    BUILT.get_or_init(|| {
        run(Command::new("zig").arg("build").current_dir(zig_dir()));
    });
    zig_dir().join("zig-out/bin/zig-bindgen")
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

/// The fixtures, libs first: a fixture that resolves against `std` reads
/// its lowered JSON as a lib.
fn fixtures() -> Vec<Fixture> {
    let std = parse(&root().join("std/std.ir"), &[]);
    let mut out = vec![
        Fixture {
            name: "std".into(),
            ir: std.clone(),
            snapshot: false,
        },
        Fixture {
            name: "sample".into(),
            ir: parse(&root().join("abi/tests/json/sample.ir"), &[]),
            snapshot: true,
        },
    ];
    let libs = [std];
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
    out
}

fn files(dir: &Path, out: &mut BTreeMap<String, String>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_file() {
            out.insert(
                p.file_name().unwrap().to_string_lossy().into(),
                std::fs::read_to_string(&p).unwrap(),
            );
        }
    }
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

fn ty(params: &[String], results: &[String]) -> String {
    format!("({}) -> ({})", params.join(", "), results.join(", "))
}

fn core(sig: &Json) -> String {
    let Json::Obj(o) = sig else {
        return String::new();
    };
    let Some(Json::Obj(c)) = get(o, "core") else {
        return String::new();
    };
    ty(&strs(get(c, "params")), &strs(get(c, "results")))
}

fn key(o: &Json) -> (String, String) {
    let Json::Obj(o) = o else { unreachable!() };
    (s(get(o, "module")), s(get(o, "name")))
}

/// What the lowered JSON lets a module import and export, with core
/// types: members, callbacks' trampolines, and the operations of the
/// futures, boxes and errors it reaches.
#[derive(Default)]
struct Surface {
    imports: BTreeMap<(String, String), String>,
    exports: BTreeMap<String, String>,
}

fn slots(e: Option<&Json>) -> Vec<String> {
    let Some(Json::Obj(e)) = e else {
        return Vec::new();
    };
    let Some(Json::Obj(shape)) = get(e, "shape") else {
        return Vec::new();
    };
    strs(get(shape, "slots"))
}

fn walk(j: &Json, out: &mut Surface) {
    match j {
        Json::Obj(o) => {
            if let (Some(k), Some(sig)) = (get(o, "key"), get(o, "sig")) {
                let k = s(Some(k));
                if s(get(o, "role")) == "import" {
                    let module = s(get(o, "module"));
                    let module = if module.is_empty() {
                        "tw:js/global".into()
                    } else {
                        module
                    };
                    out.imports.insert((module, k), core(sig));
                } else {
                    out.exports.insert(k, core(sig));
                }
            }
            if let (Some(t), Some(op)) = (get(o, "trampoline"), get(o, "op")) {
                out.exports.insert(s(Some(t)), core(op));
            }
            if let (Some(t), Some(Json::Obj(v))) = (get(o, "take"), get(o, "value")) {
                out.imports
                    .insert(key(t), ty(&["externref".into()], &strs(get(v, "wire"))));
                let err = [vec!["i32".to_string()], slots(get(o, "rejection"))].concat();
                out.imports.insert(
                    key(get(o, "errorOp").unwrap()),
                    ty(&["externref".into()], &err),
                );
            }
            for (_, v) in o {
                walk(v, out);
            }
        }
        Json::Arr(xs) => xs.iter().for_each(|x| walk(x, out)),
        _ => {}
    }
}

/// The protocol the runtime (`tsgen.zig`) uses whatever the module.
fn runtime(out: &mut Surface) {
    for (m, n, t) in [
        ("tw:future", "suspend", "(externref) -> (i32)"),
        ("tw:future", "drop", "(externref) -> ()"),
        ("tw:box", "str", "(i32, i32) -> (externref)"),
        ("tw:box", "f64", "(f64) -> (externref)"),
        ("tw:box", "bool", "(i32) -> (externref)"),
        ("tw:box", "arr<Any?>", "(i32, i32) -> (externref)"),
        ("tw:unbox", "str", "(externref) -> (i32, i32)"),
        ("tw:unbox", "f64", "(externref) -> (f64)"),
        ("tw:unbox", "bool", "(externref) -> (i32)"),
        ("tw:isNullish", "", "(externref) -> (i32)"),
        ("tw:arr", "len", "(externref) -> (i32)"),
        ("tw:arr", "get<Any?>", "(externref, i32) -> (externref)"),
    ] {
        out.imports.insert((m.into(), n.into()), t.into());
    }
    for (n, t) in [
        ("tw:realloc", "(i32, i32, i32, i32) -> (i32)"),
        ("tw:free", "(i32, i32, i32) -> ()"),
        ("tw:table/alloc", "(i32) -> (i32)"),
        ("tw:table/free", "(i32, i32) -> ()"),
    ] {
        out.exports.insert(n.into(), t.into());
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

/// A module's function imports `(module, name) -> type`, function exports
/// `name -> type`, and tag imports `(module, name) -> params`.
#[derive(Default)]
struct Signatures {
    imports: BTreeMap<(String, String), String>,
    exports: BTreeMap<String, String>,
    tags: BTreeMap<(String, String), String>,
}

fn signatures(wasm: &[u8]) -> Signatures {
    use wasmparser::{CompositeInnerType, ExternalKind, Parser, Payload, TypeRef};
    let mut types = Vec::new();
    let mut funcs = Vec::new();
    let mut out = Signatures::default();
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
                    let k = (i.module.to_string(), i.name.to_string());
                    match i.ty {
                        TypeRef::Func(t) => {
                            funcs.push(t);
                            out.imports.insert(k, types[t as usize].clone().unwrap());
                        }
                        TypeRef::Tag(t) => {
                            out.tags
                                .insert(k, types[t.func_type_idx as usize].clone().unwrap());
                        }
                        _ => {}
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
                        out.exports
                            .insert(e.name.to_string(), types[t as usize].clone().unwrap());
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The root file each fixture compiles from: it keeps every function of
/// the bindings, and of their classes and enums, whose types are concrete
/// (generic ones compile where they're used).
const PROBE: &str = r#"const b = @import("bindings.zig");
pub const panic = b.panic;

fn concrete(comptime F: type) bool {
    const f = @typeInfo(F).@"fn";
    if (f.return_type == null) return false;
    for (f.param_types) |p| if (p == null or p.? == type) return false;
    return true;
}

fn table() []const *const anyopaque {
    @setEvalBranchQuota(10_000_000);
    comptime var out: []const *const anyopaque = &.{};
    inline for (@typeInfo(b).@"struct".decl_names) |n| {
        const v = @field(b, n);
        const V = @TypeOf(v);
        if (@typeInfo(V) == .@"fn") {
            if (comptime concrete(V)) out = out ++ [_]*const anyopaque{@ptrCast(&v)};
        } else if (V == type and (@typeInfo(v) == .@"struct" and @hasField(v, "ref") or @typeInfo(v) == .@"union" and @hasDecl(v, "tw_arms"))) {
            const names = switch (@typeInfo(v)) {
                .@"struct" => |x| x.decl_names,
                .@"union" => |x| x.decl_names,
                else => unreachable,
            };
            inline for (names) |m| {
                const f = @field(v, m);
                if (@typeInfo(@TypeOf(f)) == .@"fn" and comptime concrete(@TypeOf(f))) out = out ++ [_]*const anyopaque{@ptrCast(&f)};
            }
        }
    }
    return out;
}

const fns = table();
export fn probe(i: u32) usize {
    return @intFromPtr(fns[i]);
}
"#;

#[test]
fn zig() {
    if skipped(false) {
        return;
    }
    let generator = generator();
    // Another profile is refused.
    {
        let dir = work().join("wrong-profile");
        std::fs::create_dir_all(&dir).unwrap();
        let ir = ts_gen_abi::text::parse("ir 1;\nf(v: str);").unwrap();
        let lowered = dir.join("lowered.json");
        std::fs::write(&lowered, json::lower(&ir, &Profile::all_host()).pretty()).unwrap();
        let out = Command::new(&generator)
            .args(["bindings", lowered.to_str().unwrap(), "--out"])
            .arg(dir.join("out"))
            .output()
            .unwrap();
        assert!(!out.status.success());
        assert!(String::from_utf8_lossy(&out.stderr).contains("jspi = on"));
    }
    let bless = std::env::var_os("BLESS").is_some();
    let profile = Profile::parse(PROFILE).unwrap();
    let fixtures = fixtures();
    let lib_irs: Vec<&Ir> = fixtures
        .iter()
        .filter(|f| f.ir.lib.is_some())
        .map(|f| &f.ir)
        .collect();
    let mut failures = Vec::new();
    let mut checks = Vec::new();
    for f in &fixtures {
        let libs: Vec<&Ir> =
            f.ir.with
                .iter()
                .map(|w| *lib_irs.iter().find(|l| l.lib.as_ref() == Some(w)).unwrap())
                .collect();
        let lowered = json::lower_with(&f.ir, &libs, &profile);
        let input = work().join(format!("{}.json", f.name));
        std::fs::create_dir_all(work()).unwrap();
        std::fs::write(&input, lowered.pretty()).unwrap();
        let out = work().join("gen").join(&f.name);
        let _ = std::fs::remove_dir_all(&out);
        let mut cmd = Command::new(&generator);
        cmd.args([
            "bindings",
            input.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
            "--runtime",
        ]);
        for l in &f.ir.with {
            cmd.args(["--lib", work().join(format!("{l}.json")).to_str().unwrap()]);
        }
        run(&mut cmd);
        let mut actual = BTreeMap::new();
        files(&out, &mut actual);
        let manifest = actual["manifest.json"].clone();
        let mut surface = Surface::default();
        walk(&lowered, &mut surface);
        for l in &libs {
            walk(&json::lower(l, &profile), &mut surface);
        }
        runtime(&mut surface);
        checks.push((f.name.clone(), out.clone(), surface, manifest));
        // The runtime is the generator's fixed source, not generated.
        actual.remove("tsgen.zig");
        if !f.snapshot {
            actual.retain(|k, _| k == "skipped.txt");
        }
        let snap = zig_dir().join("tests/snapshots").join(&f.name);
        if bless {
            let _ = std::fs::remove_dir_all(&snap);
            std::fs::create_dir_all(&snap).unwrap();
            for (rel, text) in &actual {
                std::fs::write(snap.join(rel), text).unwrap();
            }
            continue;
        }
        let mut want = BTreeMap::new();
        if snap.exists() {
            files(&snap, &mut want);
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
                    f.name,
                    diff.unified_diff().context_radius(2)
                ));
            }
        }
    }
    // Compile each fixture, a few at a time, then check its surface.
    let next = std::sync::atomic::AtomicUsize::new(0);
    let slots: Mutex<Vec<Option<Compiled>>> = Mutex::new(vec![None; checks.len()]);
    std::thread::scope(|scope| {
        let n = std::thread::available_parallelism().map_or(4, |n| n.get().min(8));
        for _ in 0..n {
            scope.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let Some((_, dir, _, _)) = checks.get(i) else {
                    break;
                };
                std::fs::write(dir.join("probe.zig"), PROBE).unwrap();
                let out = Command::new("zig")
                    .args([
                        "build-exe",
                        "probe.zig",
                        "-target",
                        "wasm32-freestanding",
                        "-fno-entry",
                        "-rdynamic",
                    ])
                    .args([
                        "-O",
                        "ReleaseSmall",
                        "-femit-bin=probe.wasm",
                        "--cache-dir",
                        "../../cache",
                    ])
                    .current_dir(dir)
                    .output()
                    .unwrap();
                let r = if out.status.success() {
                    Ok(std::fs::read(dir.join("probe.wasm")).unwrap())
                } else {
                    Err(String::from_utf8_lossy(&out.stderr).into_owned())
                };
                slots.lock().unwrap()[i] = Some(r);
            });
        }
    });
    let results = slots.into_inner().unwrap().into_iter().map(Option::unwrap);
    for ((name, dir, surface, manifest), r) in checks.iter().zip(results) {
        match r {
            Ok(wasm) => check_surface(
                name,
                dir,
                surface,
                manifest,
                &wasm,
                &generator,
                &mut failures,
            ),
            Err(e) => failures.push(format!("{name}: doesn't compile:\n{e}")),
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// A fixture's compiled module, or the compiler's errors.
type Compiled = Result<Vec<u8>, String>;

/// The wire type of an import through the shim: slots for externrefs, and
/// a return area pointer, with a status result, when it throws or has
/// more than one result.
fn through_shim(params: &[String], results: &[String], throws: bool) -> String {
    let slot = |w: &String| {
        if w == "externref" {
            "i32".to_string()
        } else {
            w.clone()
        }
    };
    let mut ps: Vec<String> = params.iter().map(slot).collect();
    if throws || results.len() > 1 {
        ps.push("i32".into());
    }
    let rs: Vec<String> = if throws {
        vec!["i32".into()]
    } else if results.len() == 1 {
        vec![slot(&results[0])]
    } else {
        vec![]
    };
    ty(&ps, &rs)
}

/// Checks one compiled module, and the shim written for it, against the
/// lowered layouts.
fn check_surface(
    name: &str,
    dir: &Path,
    surface: &Surface,
    manifest: &str,
    wasm: &[u8],
    generator: &Path,
    failures: &mut Vec<String>,
) {
    let mut fail = |m: String| failures.push(format!("{name}: {m}"));
    let m: serde_json::Value = serde_json::from_str(manifest).unwrap();
    let list = |v: &serde_json::Value| -> Vec<String> {
        v.as_array()
            .map(|xs| xs.iter().map(|x| x.as_str().unwrap().to_string()).collect())
            .unwrap_or_default()
    };
    // The manifest's entries have their members' and operations' types.
    let mut by_c = BTreeMap::new();
    for o in m["imports"].as_array().unwrap() {
        let (params, results) = (list(&o["params"]), list(&o["results"]));
        let k = (
            o["module"].as_str().unwrap().to_string(),
            o["name"].as_str().unwrap().to_string(),
        );
        match surface.imports.get(&k) {
            Some(t) if *t == ty(&params, &results) => {}
            Some(t) => fail(format!(
                "manifest import {k:?} is {}, the layout says {t}",
                ty(&params, &results)
            )),
            None => fail(format!(
                "manifest import {k:?} is no member's or operation's"
            )),
        }
        let throws = !o["throws"].is_null();
        by_c.insert(
            o["c"].as_str().unwrap().to_string(),
            through_shim(&params, &results, throws),
        );
    }
    for o in m["exports"].as_array().unwrap() {
        let (params, results) = (list(&o["params"]), list(&o["results"]));
        let n = o["name"].as_str().unwrap().to_string();
        match surface.exports.get(&n) {
            Some(t) if *t == ty(&params, &results) => {}
            Some(t) => fail(format!(
                "manifest export {n} is {}, the layout says {t}",
                ty(&params, &results)
            )),
            None => fail(format!(
                "manifest export {n} is no member's or trampoline's"
            )),
        }
    }
    // The module's imports through the shim are the manifest's.
    let sigs = signatures(wasm);
    for ((module, n), t) in &sigs.imports {
        if module != "shim" {
            if surface.imports.get(&(module.clone(), n.clone())) != Some(t) {
                fail(format!("direct import ({module}, {n}) is {t}"));
            }
            continue;
        }
        if n.starts_with("tsgen_") {
            continue;
        }
        match by_c.get(n) {
            Some(want) if want == t => {}
            Some(want) => fail(format!("shim import {n} is {t}, the manifest says {want}")),
            None => fail(format!("shim import {n} isn't in the manifest")),
        }
    }
    for (n, t) in &sigs.exports {
        if let Some(want) = surface.exports.get(n) {
            if want != t {
                fail(format!("export {n} is {t}, the layout says {want}"));
            }
        }
    }
    // The shim validates, and what it imports and exports has the layouts'
    // types.
    let shim = dir.join("shim.wat");
    run(Command::new(generator)
        .arg("shim")
        .arg(dir.join("manifest.json"))
        .arg(dir.join("probe.wasm"))
        .arg("-o")
        .arg(&shim));
    let bytes = match wat::parse_file(&shim) {
        Ok(b) => b,
        Err(e) => return fail(format!("shim.wat: {e}")),
    };
    if let Err(e) = wasmparser::Validator::new().validate_all(&bytes) {
        return fail(format!("the shim doesn't validate: {e}"));
    }
    let shim_sigs = signatures(&bytes);
    for ((module, n), t) in &shim_sigs.imports {
        if module == "zig" {
            continue;
        }
        if surface.imports.get(&(module.clone(), n.clone())) != Some(t) {
            fail(format!("the shim imports ({module}, {n}) as {t}"));
        }
    }
    for (n, t) in &shim_sigs.exports {
        if n.starts_with("tsgen") {
            continue;
        }
        match surface.exports.get(n) {
            Some(want) if want == t => {}
            Some(want) => fail(format!(
                "the shim exports {n} as {t}, the layout says {want}"
            )),
            None => fail(format!("the shim exports {n}, no member's or trampoline's")),
        }
    }
}

/// `examples/zig-bindgen/example` end to end in node, through the merged
/// module and its bridge: the routes node can serve.
#[test]
fn zig_worker() {
    if skipped(true) {
        return;
    }
    tour("node", "tour.node.txt");
}

/// `examples/zig-bindgen/example` served by workerd (`WORKERD`, else
/// `workerd` on the path): the whole tour, with its Durable Object and
/// second service. Without workerd it is skipped, and fails under
/// `TSGEN_REQUIRE_ZIG`.
#[test]
fn zig_worker_workerd() {
    if skipped(true) {
        return;
    }
    let workerd = std::env::var_os("WORKERD").unwrap_or_else(|| "workerd".into());
    if Command::new(workerd).arg("--version").output().is_err() {
        assert!(!required(), "workerd is required under TSGEN_REQUIRE_ZIG");
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
    let dir = zig_dir().join("example");
    let stdout = run(Command::new(dir.join("run.sh"))
        .arg(mode)
        .env("TSGEN_ZIG_BUILT", "1"));
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
