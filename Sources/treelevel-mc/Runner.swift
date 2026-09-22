import Foundation

/// Runs one job: prepares the generator's configuration, starts it, follows its output to keep status.json
/// current, and checks that events came out.
struct Runner {
    var folder: MCJobFolder
    var job: MCJob
    var engineVersion: String
    /// Number of the job in this run of the engine, shown in its window and in TreeLevel.
    var number: Int = 0

    /// Writes the status in the job folder and keeps the engine's list of jobs in step.
    private func publish(_ status: MCStatus) {
        try? folder.write(status: status)
        JobHistory.record(JobHistory.entry(job: job, folder: folder, status: status))
    }

    func run() -> Bool {
        let start = Date()
        var status = MCStatus(state: .running, jobID: job.id)
        status.number = number
        status.started = start
        status.message = "préparation"
        publish(status)
        guard FileManager.default.fileExists(atPath: folder.inputURL(job).path) else {
            return finish(failed: "the job has no input file (\(job.input))", start: start)
        }
        do {
            switch job.generator {
            case .passthrough: return try passthrough(start: start)
            case .pythia8: return try pythia(start: start)
            case .herwig7: return try herwig(start: start)
            }
        } catch {
            return finish(failed: error.localizedDescription, start: start)
        }
    }

    // MARK: Backends

    /// No shower: the parton-level events are converted to HepMC3 as they are. Useful to check the plumbing
    /// and to compare a showered sample with the hard process it came from.
    private func passthrough(start: Date) throws -> Bool {
        let events = try LesHouchesLite.read(folder.inputURL(job))
        try LesHouchesLite.writeHepMC(events, to: folder.outputURL(job), crossSection: events.crossSection)
        var status = MCStatus(state: .finished, jobID: job.id)
        status.number = number
        status.started = start
        status.finished = Date()
        status.eventsWritten = events.events.count
        status.crossSection = events.crossSection
        status.generatorVersion = "TreeLevel MC Engine \(engineVersion) (sans gerbe)"
        status.progress = 1
        status.seconds = Date().timeIntervalSince(start)
        publish(status)
        return true
    }

    /// Pythia 8 through our small driver, which reads the LHE file and writes HepMC3.
    private func pythia(start: Date) throws -> Bool {
        guard let driver = Installation.pythiaDriver else {
            return finish(failed: "the Pythia 8 module is not installed", start: start)
        }
        // The generators run with the job folder as their working directory and are given relative names:
        // Pythia reads `Beams:LHEF` as a single word, so a path with spaces (and the job folder lives under
        // "Application Support") would be cut short.
        var settings = """
        Beams:frameType = 4
        Beams:LHEF = \(job.input)
        Main:numberOfEvents = \(job.events)
        Random:setSeed = on
        Random:seed = \(job.seed % 900_000_000)
        PartonLevel:ISR = \(job.shower ? "on" : "off")
        PartonLevel:FSR = \(job.shower ? "on" : "off")
        PartonLevel:MPI = \(job.multipleInteractions ? "on" : "off")
        HadronLevel:all = \(job.hadronisation ? "on" : "off")
        HadronLevel:Decay = \(job.decays ? "on" : "off")
        Print:quiet = on
        Next:numberShowEvent = 0
        """
        if let tune = job.tune, !tune.isEmpty { settings += "\nTune:pp = \(tune)" }
        if let extra = job.extraSettings, !extra.isEmpty { settings += "\n" + extra }
        let config = folder.url.appendingPathComponent("pythia.cmnd")
        try settings.write(to: config, atomically: true, encoding: .utf8)
        return try runProcess(driver, ["--config", config.lastPathComponent, "--out", job.output], start: start,
                              name: "Pythia 8 " + (Installation.capabilities(engineVersion: engineVersion).versions["pythia8"] ?? ""))
    }

    /// Herwig 7: written as a `.in` file, then `Herwig read` and `Herwig run`.
    private func herwig(start: Date) throws -> Bool {
        guard let herwig = Installation.herwig else {
            return finish(failed: "the Herwig 7 module is not installed", start: start)
        }
        let name = "job"
        let input = """
        read snippets/EPCollider.in
        cd /Herwig/EventHandlers
        library LesHouches.so
        create ThePEG::LesHouchesFileReader LesHouchesReader
        set LesHouchesReader:FileName \(job.input)
        set LesHouchesReader:CacheFileName cache.tmp
        set LesHouchesReader:MaxScan 5
        create ThePEG::Cuts NoCuts
        set LesHouchesReader:Cuts NoCuts
        create ThePEG::LesHouchesEventHandler LesHouchesHandler
        insert LesHouchesHandler:LesHouchesReaders 0 LesHouchesReader
        set LesHouchesHandler:PartonExtractor /Herwig/Partons/EEExtractor
        set LesHouchesHandler:CascadeHandler \(job.shower ? "/Herwig/Shower/ShowerHandler" : "NULL")
        set LesHouchesHandler:HadronizationHandler \(job.hadronisation ? "/Herwig/Hadronization/ClusterHadHandler" : "NULL")
        set LesHouchesHandler:DecayHandler \(job.decays ? "/Herwig/Decays/DecayHandler" : "NULL")
        set LesHouchesHandler:WeightOption VarNegWeight
        cd /Herwig/Generators
        set EventGenerator:EventHandler /Herwig/EventHandlers/LesHouchesHandler
        set EventGenerator:NumberOfEvents \(job.events)
        set EventGenerator:RandomNumberGenerator:Seed \(job.seed % 900_000_000)
        set EventGenerator:PrintEvent 0
        set EventGenerator:MaxErrors 10000
        insert EventGenerator:AnalysisHandlers 0 /Herwig/Analysis/HepMCFile
        set /Herwig/Analysis/HepMCFile:PrintEvent \(job.events)
        set /Herwig/Analysis/HepMCFile:Format GenEvent
        set /Herwig/Analysis/HepMCFile:Units GeV_mm
        set /Herwig/Analysis/HepMCFile:Filename \(job.output)
        \(job.extraSettings ?? "")
        saverun \(name) EventGenerator
        """
        try input.write(to: folder.url.appendingPathComponent("\(name).in"), atomically: true, encoding: .utf8)
        let version = Installation.capabilities(engineVersion: engineVersion).versions["herwig7"] ?? "Herwig 7"
        guard try runProcess(herwig, ["read", "\(name).in"], start: start, name: version, step: "lecture de la configuration", finishNow: false) else { return false }
        return try runProcess(herwig, ["run", "\(name).run", "-N", "\(job.events)"], start: start, name: version)
    }

    // MARK: Running a generator

    /// Starts a program in the job folder, streams its output into engine.log, and updates the status from the
    /// lines that mention a number of events.
    private func runProcess(_ url: URL, _ arguments: [String], start: Date, name: String,
                            step: String? = nil, finishNow: Bool = true) throws -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = folder.url
        var environment = ProcessInfo.processInfo.environment
        environment["TREELEVEL_JOB"] = job.id
        // A module's plugins ask for @rpath/libHepMC3, and the rpath they were linked with is the build
        // machine's. Ours is beside the program, so name it here rather than rewriting the binaries.
        let lib = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        if FileManager.default.fileExists(atPath: lib.path) {
            let paths = [lib.path, lib.appendingPathComponent("ThePEG").path, lib.appendingPathComponent("Herwig").path]
            environment["DYLD_FALLBACK_LIBRARY_PATH"] =
                (paths + [environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/local/lib:/usr/lib"]).joined(separator: ":")
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        FileManager.default.createFile(atPath: folder.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: folder.logURL)
        log.seekToEndOfFile()

        var status = MCStatus(state: .running, jobID: job.id)
        status.number = number
        status.started = start
        status.generatorVersion = name
        status.message = step ?? "génération"
        publish(status)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log.write(data)
            let text = String(decoding: data, as: UTF8.self)
            // Both generators print lines with the event number as they go.
            for line in text.split(separator: "\n") {
                guard let n = Self.eventCount(in: String(line)) else { continue }
                var s = status
                s.eventsWritten = n
                s.progress = job.events > 0 ? min(1, Double(n) / Double(job.events)) : nil
                publish(s)
            }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        try? log.close()
        guard process.terminationStatus == 0 else {
            return finish(failed: "\(name) stopped with code \(process.terminationStatus) — see engine.log", start: start)
        }
        guard finishNow else { return true }
        let (written, sigma, sigmaError) = summary(of: folder.outputURL(job))
        guard written > 0 else { return finish(failed: "\(name) wrote no event — see engine.log", start: start) }
        var done = MCStatus(state: .finished, jobID: job.id)
        done.number = number
        done.started = start
        done.finished = Date()
        done.eventsWritten = written
        done.generatorVersion = name
        done.progress = 1
        done.seconds = Date().timeIntervalSince(start)
        done.crossSection = sigma
        done.crossSectionError = sigmaError
        publish(done)
        return true
    }

    private func finish(failed message: String, start: Date) -> Bool {
        var status = MCStatus(state: .failed, jobID: job.id)
        status.number = number
        status.started = start
        status.finished = Date()
        status.message = message
        status.seconds = Date().timeIntervalSince(start)
        publish(status)
        FileHandle.standardError.write(("treelevel-mc: " + message + "\n").data(using: .utf8)!)
        return false
    }

    /// "Pythia::next(): 1000 events have been generated" / "Herwig: 1000 events".
    static func eventCount(in line: String) -> Int? {
        guard line.contains("event") else { return nil }
        let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.max()
    }

    /// One pass over the HepMC3 file: the `E` lines are the events, and the cross section is whatever the
    /// last event says — `C sigma error` in the Asciiv3 format Herwig writes, or the `GenCrossSection`
    /// attribute other writers attach. The last one wins: a generator refines it as it goes.
    private func summary(of url: URL) -> (events: Int, crossSection: Double?, error: Double?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, nil, nil) }
        var events = 0
        var sigma: Double?
        var sigmaError: Double?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("E ") {
                events += 1
            } else if line.hasPrefix("C ") {
                let f = line.split(separator: " ")
                if f.count >= 2, let v = Double(f[1]) { sigma = v }
                if f.count >= 3, let v = Double(f[2]) { sigmaError = v }
            } else if line.hasPrefix("A 0 GenCrossSection") {
                let f = line.split(separator: " ")
                if f.count >= 4, let v = Double(f[3]) { sigma = v }
                if f.count >= 5, let v = Double(f[4]) { sigmaError = v }
            }
        }
        return (events, sigma, sigmaError)
    }
}
