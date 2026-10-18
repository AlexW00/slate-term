import Foundation

extension PluginContractSchemas {
    /// The archive contains portable input, while public installed registrations
    /// contain resolved runtime paths. Keep these shapes distinct.
    static var packageDefinitions: [String: JSONValue] {
        let path = S.string(format: "slate-package-relative-path")
        let rootPath = S.string(format: "slate-package-root-relative-path")
        func spec(command: Bool) -> JSONValue {
            var schema = (command ? self.command(input: true) : process(input: true)).object!
            var fields = schema["properties"]!.object!
            fields["executable"] = S.oneOf([absolutePath, S.annotated(path, ["pattern": .string("^\\./")])])
            fields["directory"] = S.defaulted(rootPath, .string("."))
            fields["arguments"] = defaulted(S.array(S.annotated(argument, ["format": .string("slate-package-argument")]), maximum: 128), .array([]), input: true)
            schema["properties"] = .object(fields)
            return .object(schema)
        }
        var manifest = registration(input: true).object!
        var fields = manifest["properties"]!.object!
        fields["source"] = S.nullable(S.reference("PluginPackageSource"))
        // The portable resolver handles present process/service/directory fields
        // before the older runtime decoder; explicit null is not omission here.
        fields["process"] = S.reference("PluginPackageProcess")
        fields["service"] = S.reference("PluginPackageProcess")
        fields["commands"] = defaulted(unique(S.reference("PluginPackageCommand"), maximum: 32, by: "id"), .array([]), input: true)
        manifest["properties"] = .object(fields)
        manifest["x-packageManifestResolution"] = .bool(true)
        return [
            "PluginPackageManifest": .object(manifest),
            "PluginPackageProcess": spec(command: false), "PluginPackageCommand": spec(command: true),
            "PluginPackageSource": S.oneOf([
                S.object(["kind": S.constant(.string("directory")), "path": rootPath,
                    "entry": defaulted(path, .string("index.html"), input: true)], required: ["kind", "path"]),
                S.object(["kind": S.constant(.string("url")), "url": S.string(format: "slate-plugin-url")], required: ["kind", "url"])
            ])
        ]
    }
}
