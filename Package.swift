// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Remark",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Remark",
            path: "Sources/Remark"
        )
    ]
)
