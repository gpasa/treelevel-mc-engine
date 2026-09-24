import Foundation

/// Where the generators are, and which ones are usable. The engine looks, in order, for a module installed
/// beside itself (what the download button fetches), then for a system installation (Homebrew, MacPorts, a
/// local build), so that a developer's machine works without downloading anything.
enum Installation {
    /// The modules shipped inside the application: TreeLevel MC Engine.app/Contents/Resources/Modules.
    /// Everything the engine needs travels with it — the user installs one application and nothing else.
    static var bundledModules: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let modules = resources.appendingPathComponent("Modules", isDirectory: true)
        return FileManager.default.fileExists(atPath: modules.path) ? modules : nil
    }

    /// The token the packaging script leaves where the build prefix was, in the modules' text files.
    static let modulePlaceholder = "@TREELEVEL_MODULE@"

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
        if let bundled = bundledModules { candidates.insert(bundled.appendingPathComponent("pythia8/treelevel-pythia"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Herwig's command line (`Herwig read` then `Herwig run`).
    static var herwig: URL? {
        var candidates = [modulesDirectory.appendingPathComponent("herwig7/bin/Herwig"),
                          URL(fileURLWithPath: "/opt/local/bin/Herwig"),                // MacPorts
                          URL(fileURLWithPath: "/usr/local/bin/Herwig"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/Herwig")]
        if let bundled = bundledModules { candidates.insert(bundled.appendingPathComponent("herwig7/bin/Herwig"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Sherpa's command line. It computes its own matrix elements, so it needs no driver of ours.
    static var sherpa: URL? {
        var candidates = [modulesDirectory.appendingPathComponent("sherpa3/bin/Sherpa"),
                          URL(fileURLWithPath: "/opt/local/bin/Sherpa"),                // MacPorts
                          URL(fileURLWithPath: "/usr/local/bin/Sherpa"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/Sherpa")]
        if let bundled = bundledModules { candidates.insert(bundled.appendingPathComponent("sherpa3/bin/Sherpa"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// WHIZARD's command line. Like Sherpa it computes its own matrix elements — through O'Mega, which
    /// generates and compiles Fortran for each new process.
    static var whizard: URL? {
        var candidates = [modulesDirectory.appendingPathComponent("whizard3/bin/whizard"),
                          URL(fileURLWithPath: "/opt/local/bin/whizard"),                // MacPorts
                          URL(fileURLWithPath: "/usr/local/bin/whizard"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/whizard")]
        if let bundled = bundledModules { candidates.insert(bundled.appendingPathComponent("whizard3/bin/whizard"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// CalcHEP's tree. It is not a single program: a job runs in a working copy made by `mkWORKdir`,
    /// so what we look for is the root, and the version is the one its headers carry.
    static var calchep: URL? {
        var candidates = [modulesDirectory.appendingPathComponent("calchep3"),
                          URL(fileURLWithPath: "/opt/local/share/calchep"),
                          URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("calchep")]
        if let bundled = bundledModules { candidates.insert(bundled.appendingPathComponent("calchep3"), at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("mkWORKdir").path) }
    }

    static func calchepVersion(_ root: URL) -> String? {
        guard let header = try? String(contentsOf: root.appendingPathComponent("include/version.h"), encoding: .utf8),
              let quoted = header.split(separator: "\"").dropFirst().first else { return nil }
        return "CalcHEP " + quoted
    }


    // MARK: Le conteneur — la seconde manière d'avoir les générateurs

    /// L'image qui porte les cinq générateurs, pour qui préfère Docker à l'installation des modules.
    /// TREELEVEL_MC_IMAGE la remplace, le temps d'essayer une construction locale.
    static func image(engineVersion: String) -> String {
        if let set = ProcessInfo.processInfo.environment["TREELEVEL_MC_IMAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !set.isEmpty { return set }
        return "ghcr.io/gpasa/treelevel-mc-engine:" + engineVersion
    }

    /// Docker — ou Podman —, mais seulement quand son démon répond. L'application s'installe longtemps avant
    /// que son moteur ne tourne, et une machine sans virtualisation ne le fera jamais démarrer : un client
    /// présent ne prouve rien.
    static var docker: URL? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker",
                          NSHomeDirectory() + "/.docker/bin/docker",
                          "/opt/homebrew/bin/podman", "/opt/local/bin/podman", "/usr/local/bin/podman"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let (code, out) = run(url, ["version", "--format", "{{.Server.Version}}"])
            if code == 0, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return url }
        }
        return nil
    }

    /// L'image est-elle déjà là ? On ne la tire jamais de soi-même : un gigaoctet ne se télécharge pas dans
    /// le dos de quelqu'un.
    static func imageIsPresent(_ docker: URL, _ image: String) -> Bool {
        run(docker, ["image", "inspect", image]).code == 0
    }

    /// Docker et l'image ensemble. Les modules installés restent prioritaires : ils tournent nativement,
    /// sans machine virtuelle, et n'imposent pas que Docker soit démarré.
    static func container(engineVersion: String) -> (docker: URL, image: String)? {
        guard let docker else { return nil }
        // L'étiquette de la version d'abord, puis « latest » : le moteur et l'image ne changent pas de
        // version en même temps — celui-ci est en 0.3.0 quand l'image en est à 0.2.0 —, et refuser une image
        // présente pour un chiffre serait absurde. Un réglage explicite, lui, n'est pas contourné.
        var tags = [image(engineVersion: engineVersion)]
        if ProcessInfo.processInfo.environment["TREELEVEL_MC_IMAGE"] == nil {
            tags.append("ghcr.io/gpasa/treelevel-mc-engine:latest")
        }
        for tag in tags where imageIsPresent(docker, tag) { return (docker, tag) }
        return nil
    }

    /// Ce que le moteur de l'image déclare, obtenu en le lui demandant.
    static func imageCapabilities(_ docker: URL, _ image: String) -> MCCapabilities? {
        let (code, out) = run(docker, ["run", "--rm", image, "capabilities"], timeout: 120)
        guard code == 0, let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MCCapabilities.self, from: data)
    }

    /// Comme `output`, mais le code de sortie compte : une commande Docker qui échoue écrit sur la sortie
    /// d'erreur et rend un texte qu'on prendrait pour une réponse.
    static func run(_ url: URL, _ arguments: [String], timeout: TimeInterval = 20) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }



    /// D'où vient un générateur, quand ce n'est pas de nous. Cette machine porte MacPorts et Homebrew côte à
    /// côte, et l'un des deux est souvent désactivé : voir « WHIZARD 3.1.4 (Homebrew) » là où le module en
    /// installe 3.1.6 explique d'un coup d'œil un numéro de version qui surprend.
    static func origin(of url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        if path.hasPrefix(modulesDirectory.path) { return nil }
        if let bundled = bundledModules, path.hasPrefix(bundled.path) { return nil }
        if path.hasPrefix("/opt/homebrew") { return "Homebrew" }
        if path.hasPrefix("/opt/local") { return "MacPorts" }
        if path.hasPrefix("/usr/local") { return "/usr/local" }
        return nil
    }

    /// La version telle qu'on l'affiche : le numéro, puis sa provenance si elle n'est pas la nôtre.
    static func labelled(_ version: String, from url: URL) -> String {
        origin(of: url).map { version + " (\($0))" } ?? version
    }

    /// Le premier numéro de version d'une bannière. Une installation d'une autre version majeure ne doit pas
    /// être offerte : Sherpa 2 lit un `Run.dat` là où le moteur écrit un YAML de Sherpa 3, et l'échec
    /// arriverait au milieu d'un travail, avec un message incompréhensible.
    static func majorVersion(in banner: String) -> Int? {
        guard let range = banner.range(of: "[0-9]+\\.[0-9]", options: .regularExpression) else { return nil }
        return Int(banner[range].prefix(while: { $0.isNumber }))
    }

    /// Ce que les modules installés offrent, en les interrogeant vraiment : une installation cassée — une
    /// bibliothèque disparue après une mise à jour du système — ou d'une autre version majeure n'est pas
    /// offerte. C'est aussi le critère que le lanceur emploie pour décider s'il passe la main au conteneur.
    static func nativeCapabilities(engineVersion: String) -> MCCapabilities {
        var generators: [MCJob.Generator] = [.passthrough]
        var versions: [String: String] = [:]
        if let driver = pythiaDriver, let v = Process.output(driver, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            generators.append(.pythia8)
            versions[MCJob.Generator.pythia8.rawValue] = labelled(v, from: driver)
        }
        // A broken installation (a missing library after a system upgrade, say) must not be offered.
        if let herwig, let v = Process.output(herwig, ["--version"])?.split(separator: "\n").first,
           !v.contains("dyld"), !v.contains("not loaded"), v.lowercased().contains("herwig"),
           majorVersion(in: String(v)) == 7 {
            generators.append(.herwig7)
            versions[MCJob.Generator.herwig7.rawValue] = labelled(String(v).trimmingCharacters(in: .whitespaces), from: herwig)
        }
        if let sherpa, let v = Process.output(sherpa, ["--version"])?.split(separator: "\n").first,
           !v.contains("dyld"), !v.contains("not loaded"), v.lowercased().contains("sherpa"),
           majorVersion(in: String(v)) == 3 {
            generators.append(.sherpa3)
            versions[MCJob.Generator.sherpa3.rawValue] = labelled(String(v).trimmingCharacters(in: .whitespaces), from: sherpa)
        }
        // WHIZARD prints its banner on --version and returns 0; the version is on the first line.
        if let whizard, let v = Process.output(whizard, ["--version"])?.split(separator: "\n")
                                       .first(where: { $0.lowercased().contains("whizard") }),
           !v.contains("dyld"), !v.contains("not loaded"), majorVersion(in: String(v)) == 3 {
            generators.append(.whizard3)
            versions[MCJob.Generator.whizard3.rawValue] = labelled(String(v).trimmingCharacters(in: .whitespaces), from: whizard)
        }
        if let calchep, let v = calchepVersion(calchep) {
            generators.append(.calchep3)
            versions[MCJob.Generator.calchep3.rawValue] = labelled(v, from: calchep)
        }
        var caps = MCCapabilities(engineVersion: engineVersion, generators: generators)
        caps.versions = versions
        return caps
    }

    /// Tout ce que cette machine sait faire : les modules d'abord, puis ce que l'image ajoute. Les deux
    /// voies coexistent — on n'interroge le conteneur que pour les générateurs qui manquent, et on dit d'où
    /// ils viennent, pour que personne ne s'étonne d'un numéro de version différent.
    static func capabilities(engineVersion: String) -> MCCapabilities {
        var caps = nativeCapabilities(engineVersion: engineVersion)
        guard MCJob.Generator.allCases.contains(where: { !caps.generators.contains($0) }),
              let container = container(engineVersion: engineVersion),
              let fromImage = imageCapabilities(container.docker, container.image) else { return caps }
        for generator in fromImage.generators where !caps.generators.contains(generator) {
            caps.generators.append(generator)
            caps.versions[generator.rawValue] = (fromImage.versions[generator.rawValue] ?? generator.label) + " (conteneur)"
        }
        return caps
    }

    /// Writes the capabilities where TreeLevel looks for them. TreeLevel is sandboxed and can only read its
    /// own container, so the file goes there as well as in the engine's own folder.
    @discardableResult
    static func publishCapabilities(engineVersion: String) -> MCCapabilities {
        let caps = capabilities(engineVersion: engineVersion)
        guard let data = try? MCJobFolder.encoder.encode(caps) else { return caps }
        try? data.write(to: supportDirectory.appendingPathComponent(MCEngineProtocol.capabilitiesFileName))
        let inTreeLevel = MCEngineProtocol.treeLevelSupportDirectory.appendingPathComponent(MCEngineProtocol.supportFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: MCEngineProtocol.treeLevelSupportDirectory.path) {
            try? FileManager.default.createDirectory(at: inTreeLevel, withIntermediateDirectories: true)
            try? data.write(to: inTreeLevel.appendingPathComponent(MCEngineProtocol.capabilitiesFileName))
        }
        return caps
    }

    /// Jobs are numbered once and for all, in the order the engine takes them, whichever way it was started.
    static func nextJobNumber() -> Int {
        let url = supportDirectory.appendingPathComponent("counter.txt")
        let current = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let next = current + 1
        try? "\(next)\n".write(to: url, atomically: true, encoding: .utf8)
        return next
    }

    /// Jobs TreeLevel has left in its container and that nobody has started: the engine picks them up when it
    /// is opened, so a job is never lost if the URL does not reach it.
    static func pendingJobs(newerThan age: TimeInterval = 3600) -> [MCJobFolder] {
        let jobs = MCEngineProtocol.treeLevelSupportDirectory.appendingPathComponent(MCEngineProtocol.jobsFolderName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let limit = Date().addingTimeInterval(-age)
        return entries.compactMap { url -> (MCJobFolder, Date)? in
            let folder = MCJobFolder(url)
            guard folder.readStatus()?.state == .queued, (try? folder.readJob()) != nil else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return date > limit ? (folder, date) : nil
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }
}

extension Process {
    /// Runs a program and returns its output, or nil when it cannot be run.
    static func output(_ url: URL, _ arguments: [String], timeout: TimeInterval = 20,
                       environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
