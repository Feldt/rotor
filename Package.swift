// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeAccounts",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ClaudeAccountsCore", targets: ["ClaudeAccountsCore"]),
        .executable(name: "ClaudeAccounts", targets: ["ClaudeAccounts"]),
        .executable(name: "claude-accounts", targets: ["ClaudeAccountsCLI"]),
    ],
    targets: [
        .target(
            name: "ClaudeAccountsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ClaudeAccounts",
            dependencies: ["ClaudeAccountsCore"]
        ),
        .executableTarget(
            name: "ClaudeAccountsCLI",
            dependencies: ["ClaudeAccountsCore"]
        ),
        .testTarget(
            name: "ClaudeAccountsCoreTests",
            dependencies: ["ClaudeAccountsCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
