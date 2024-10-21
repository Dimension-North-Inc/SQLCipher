// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SQLCipher",
    platforms: [
        .iOS(.v17), .macOS(.v14),
    ],
    products: [
        .library( name: "CSQLCipher", targets: ["CSQLCipher"]),
        .library(name: "SQLCipher", targets: ["SQLCipher"]),
    ],
    targets: [
        .target(
            name: "CSQLCipher",
            dependencies: [],
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLITE_TEMP_STORE", to: "3"),
                
                .define("SQLCIPHER_CRYPTO_CC"),
                
                .define("NDEBUG"),

                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "SQLCipher",
            dependencies: ["CSQLCipher"],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLITE_TEMP_STORE", to: "3"),
                
                .define("SQLCIPHER_CRYPTO_CC"),
                
                .define("NDEBUG"),

                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
    ]
)
