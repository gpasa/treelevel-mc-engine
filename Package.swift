// swift-tools-version:5.9
import PackageDescription

// The engine is a plain executable: it reads a job folder written by TreeLevel, runs the generator the job
// asks for, and writes the showered events back. The generators themselves are separate programs (a small
// Pythia driver built by Backends/pythia/Makefile, or Herwig's own command line), so nothing GPL is linked
// into anything else.
let package = Package(
    name: "TreeLevelMCEngine",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "treelevel-tools", path: "Sources/treelevel-tools")
    ]
)
