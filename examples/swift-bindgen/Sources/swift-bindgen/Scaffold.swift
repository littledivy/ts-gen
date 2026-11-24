/// An app adopting every export protocol, each requirement a stub: the
/// namespaces' on the app type, and a final class per exported class.
func scaffold(_ protocols: [ExportProtocol], appType: String) -> String {
    func stubs(_ p: ExportProtocol) -> [String] {
        p.requirements.map { "  \($0) { fatalError(\"scaffold\") }" }
    }
    var decls: [String] = []
    let namespaces = protocols.filter { !$0.isClass }
    if !namespaces.isEmpty {
        decls.append((["enum \(appType): \(namespaces.map(\.name).joined(separator: ", ")) {"] + namespaces.flatMap(stubs) + ["}"]).joined(separator: "\n"))
    }
    for p in protocols where p.isClass {
        decls.append((["final class \(p.typeName): \(p.name) {"] + stubs(p) + ["}"]).joined(separator: "\n"))
    }
    return "// The app's side of the module's exports, to fill in.\n\n" + decls.joined(separator: "\n\n") + "\n"
}
