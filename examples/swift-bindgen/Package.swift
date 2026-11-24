// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-bindgen",
    products: [
        .executable(name: "swift-bindgen", targets: ["swift-bindgen"]),
    ],
    targets: [
        // Runtime.swift is the runtime the generated bindings compile
        // against, shipped with the generator; it is not part of it.
        .executableTarget(
            name: "swift-bindgen",
            resources: [
                .copy("Resources/Runtime.swift"),
                .copy("Resources/runtime.ir"),
            ]
        ),
    ]
)
