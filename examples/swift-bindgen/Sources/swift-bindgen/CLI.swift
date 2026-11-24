import Foundation

let usage = """
    usage: swift-bindgen bindings <lowered.json> [--lib <lib.json>]... --out <dir> [--roots A,B,...] [--app App]
                         [--no-callbacks | --callbacks-for <wasm>] [--public] [--runtime] [--scaffold <file.swift>]
           swift-bindgen shim <manifest.json> <swift.wasm> -o <shim.wat>
           swift-bindgen runtime-ir

    bindings  writes Swift bindings for a lowered IR (`ts-gen-abi lower --profile
              "all-linear, jspi = on"`): <dir>/Bindings.swift,
              <dir>/include/{TSGenImports.h,module.modulemap} and <dir>/manifest.json.
              --roots limits them to those declarations and global members and
              everything their members reach (the module's exports always count);
              the members skipped, as not mapped yet, are listed in manifest.json.
              A callback's trampoline is exported only when the app uses an
              import taking one: --callbacks-for names a build of the app
              without any (--no-callbacks). --public keeps the declarations
              public; --runtime also writes <dir>/Runtime.swift; --scaffold writes
              an app adopting every export protocol, with stub bodies, to <file>
              if it does not exist.
    shim      writes the Wasm shim for the imports and exports the linked
              Swift module kept.
    runtime-ir  prints the declarations Runtime.swift needs, to append to an IR
              before lowering.
    """

/// The value after the first `name` in `args`, if any.
func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(msg)\n".utf8))
    exit(1)
}

func readBytes(_ path: String) -> [UInt8] {
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return [UInt8](d)
}

func readJSON(_ path: String) -> JSON {
    do {
        return try JSONReader.read(readBytes(path))
    } catch {
        fail("\(path): \(error)")
    }
}

func write(_ path: String, _ text: String) {
    do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

func resource(_ name: String) -> String {
    let ext = (name as NSString).pathExtension
    guard let url = Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext),
        let d = FileManager.default.contents(atPath: url.path)
    else { fail("missing resource \(name)") }
    return String(decoding: d, as: UTF8.self)
}

/// The names a Wasm module imports from the shim.
func shimImports(_ path: String) -> Set<String> {
    do {
        return Set(try WasmModule(readBytes(path)).imports.filter { $0.module == "shim" }.map(\.name))
    } catch {
        fail("\(path): \(error)")
    }
}

func bindings(_ args: [String]) {
    guard args.count > 1 else { fail("a lowered JSON is required") }
    let lowered = readJSON(args[1])
    var libs: [JSON] = []
    for (i, a) in args.enumerated() where a == "--lib" && i + 1 < args.count { libs.append(readJSON(args[i + 1])) }
    guard let outDir = option(args, "--out") else { fail("--out is required") }
    let appType = option(args, "--app") ?? "App"
    let roots = option(args, "--roots").map { $0.split(separator: ",").map(String.init) }
    let profile = lowered["profile"]
    if profile?.s("str") != "linear+utf8" || profile?.s("handles") != "linear" || profile?.s("results") != "multi" || profile?.s("throws") != "tag" {
        fail("swift-bindgen needs the all-linear profile; got \(profile.map { jsonWrite($0, indent: 0) } ?? "undefined")")
    }
    let g = Gen(lowered: lowered, libs: libs, appType: appType)
    g.select(roots)
    if let cbFor = option(args, "--callbacks-for") {
        g.keepCallbacksFor = shimImports(cbFor)
    } else if args.contains("--no-callbacks") {
        g.keepCallbacksFor = []
    }
    do {
        try g.emitAll()
    } catch let e as Unsupported {
        fail("Unsupported: \(e.message)")
    } catch {
        fail("\(error)")
    }
    let include = (outDir as NSString).appendingPathComponent("include")
    do {
        try FileManager.default.createDirectory(atPath: include, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(include): \(error)")
    }
    write((outDir as NSString).appendingPathComponent("Bindings.swift"), g.swift(keepPublic: args.contains("--public")))
    write((include as NSString).appendingPathComponent("TSGenImports.h"), g.header())
    write((include as NSString).appendingPathComponent("module.modulemap"), "module TSGenImports {\n  header \"TSGenImports.h\"\n  export *\n}\n")
    write((outDir as NSString).appendingPathComponent("manifest.json"), jsonWrite(g.manifest(), indent: 1))
    if args.contains("--runtime") {
        write((outDir as NSString).appendingPathComponent("Runtime.swift"), resource("Runtime.swift"))
    }
    if let file = option(args, "--scaffold"), !FileManager.default.fileExists(atPath: file), let app = scaffold(g.protocols, appType: appType) {
        write(file, app)
    }
    print("swift-bindgen: \(g.stats())")
}

func shim(_ args: [String]) {
    guard args.count > 2 else { fail("a manifest and a Swift module are required") }
    let manifest = readJSON(args[1])
    let bytes = readBytes(args[2])
    guard let out = option(args, "-o") else { fail("-o is required") }
    let mod: WasmModule
    do {
        mod = try WasmModule(bytes)
    } catch {
        fail("\(args[2]): \(error)")
    }
    let used = Set(mod.imports.filter { $0.module == "shim" }.map(\.name))
    write(out, shimWat(manifest: manifest, used: used, exported: Set(mod.exports)))
}

@main
struct SwiftBindgen {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "bindings": bindings(args)
        case "shim": shim(args)
        case "runtime-ir": print(resource("runtime.ir"), terminator: "")
        case "-h", "--help": print(usage)
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
    }
}
