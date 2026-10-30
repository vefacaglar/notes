// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotesCore"),
        .executableTarget(name: "Notes", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
    ]
)
