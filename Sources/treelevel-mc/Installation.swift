import Foundation

/// Where the generators are, and which ones are usable. The engine looks, in order, for a module installed
/// beside itself (what the download button fetches), then for a system installation (Homebrew, MacPorts, a
/// local build), so that a developer's machine works without downloading anything.
enum Installation {
    /// Folder holding the downloaded modules: ~/Library/Application Support/TreeLevel MC Engine/Modules.
    static var modulesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TreeLevel MC Engine/Modules", isDirectory: true)
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TreeLevel MC Engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The Pythia driver: our own small program, built against the Pythia library. Looked up beside the
    /// engine first, so that a build directory works without installing anything.
    static var pythiaDriver: URL? {
        var candidates = [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("treelevel-pythia"),
                          modulesDirectory.appendingPathComponent("pythia8/treelevel-pythia"),
                          URL(fileURLWithPath: "/opt/local/bin/treelevel-pythia"),      // MacPorts
                          URL(fileURLWithPath: "/usr/local/bin/treelevel-pythia"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/treelevel-pythia")]
        if let resources = Bundle.main.resourceURL { candidates.insert(resources.appendingPathComponent("treelevel-pythia"), at: 1) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Herwig's command line (`Herwig read` then `Herwig run`).
    static var herwig: URL? {
        let candidates = [modulesDirectory.appendingPathComponent("herwig7/bin/Herwig"),
                          URL(fileURLWithPath: "/opt/local/bin/Herwig"),                // MacPorts
                          URL(fileURLWithPath: "/usr/local/bin/Herwig"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/Herwig")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func capabilities(engineVersion: String) -> MCCapabilities {
        var generators: [MCJob.Generator] = [.passthrough]
        var versions: [String: String] = [:]
        if let driver = pythiaDriver, let v = Process.output(driver, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            generators.append(.pythia8)
            versions[MCJob.Generator.pythia8.rawValue] = v
        }
        // A broken installation (a missing library after a system upgrade, say) must not be offered.
        if let herwig, let v = Process.output(herwig, ["--version"])?.split(separator: "\n").first,
           !v.contains("dyld"), !v.contains("not loaded"), v.lowercased().contains("herwig") {
            generators.append(.herwig7)
            versions[MCJob.Generator.herwig7.rawValue] = String(v).trimmingCharacters(in: .whitespaces)
        }
        var caps = MCCapabilities(engineVersion: engineVersion, generators: generators)
        caps.versions = versions
        return caps
    }

    /// Writes the capabilities where TreeLevel looks for them.
    @discardableResult
    static func publishCapabilities(engineVersion: String) -> MCCapabilities {
        let caps = capabilities(engineVersion: engineVersion)
        if let data = try? MCJobFolder.encoder.encode(caps) {
            try? data.write(to: supportDirectory.appendingPathComponent(MCEngineProtocol.capabilitiesFileName))
        }
        return caps
    }
}

extension Process {
    /// Runs a program and returns its output, or nil when it cannot be run.
    static func output(_ url: URL, _ arguments: [String], timeout: TimeInterval = 20) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
