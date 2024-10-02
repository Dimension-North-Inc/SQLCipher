// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SQLCipher",
    products: [
        .library(
            name: "SQLCipher",
            targets: ["SQLCipher"]),
    ],
    targets: [
        .target(
            name: "SQLCipher",
            dependencies: [],
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        )
    ]
)
