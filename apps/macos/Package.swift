// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notes",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotesCore", resources: [.process("Resources")]),
        .executableTarget(name: "Notes", dependencies: ["NotesCore"], resources: [.process("Resources")]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
    ]
)
