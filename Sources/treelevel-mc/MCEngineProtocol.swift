// SPDX-License-Identifier: MIT
// Shared between TreeLevel and TreeLevel MC Engine — keep the two copies identical.
// Copyright (c) 2026 Guglielmo Pasa. Permission is hereby granted, free of charge, to any person obtaining a
// copy of this file, to deal in it without restriction, provided this notice is kept.

import Foundation

/// Exchange format between TreeLevel and the external "TreeLevel MC Engine": a job folder holding the job
/// description, the parton-level events written by TreeLevel, the status the engine updates as it runs and
/// the showered events it produces. Everything stays on the machine — nothing is uploaded anywhere.
///
/// This file is shared verbatim with TreeLevel (MIT), so that the two programs, which are distributed
/// separately and under different licences, always agree on the protocol.
public enum MCEngineProtocol {
    /// Bumped when the format changes in a way an older engine could not read.
    public static let version = 1
    public static let jobFileName = "job.json"
    public static let inputFileName = "events.lhe"
    public static let statusFileName = "status.json"
    public static let outputFileName = "events.hepmc"
    public static let logFileName = "engine.log"
    /// Bundle identifier of the engine application, and the URL scheme it answers to.
    public static let bundleIdentifier = "org.pasahome.TreeLevelMCEngine"
    public static let urlScheme = "treelevel-mc"
    /// Where the engine publishes what it can do, inside its own support folder.
    public static let capabilitiesFileName = "capabilities.json"
}

/// What to run on the parton-level events.
public struct MCJob: Codable, Equatable {
    public enum Generator: String, Codable, CaseIterable {
        case pythia8, herwig7
        /// No shower: the events are copied through, to check the plumbing.
        case passthrough
        public var label: String {
            switch self {
            case .pythia8: return "Pythia 8"
            case .herwig7: return "Herwig 7"
            case .passthrough: return "sans gerbe"
            }
        }
    }

    public var protocolVersion = MCEngineProtocol.version
    public var id: String
    public var generator: Generator
    /// Free description shown by the engine ("e⁻ e⁺ → W⁺ W⁻ at 200 GeV").
    public var process: String
    /// Number of events in the input file; the engine may write fewer if a shower fails.
    public var events: Int
    public var seed: Int
    /// Parton shower (initial and final state radiation).
    public var shower = true
    /// Hadronisation (string or cluster model).
    public var hadronisation = true
    /// Multiple parton interactions — only meaningful for hadron beams.
    public var multipleInteractions = false
    /// Let the generator decay the unstable hadrons it produces.
    public var decays = true
    /// Tune or settings preset, generator-specific ("Monash", "default").
    public var tune: String?
    /// Extra generator commands, one per line, passed through as they are (Pythia `readString`, Herwig `.in`).
    public var extraSettings: String?
    /// Files, relative to the job folder.
    public var input = MCEngineProtocol.inputFileName
    public var output = MCEngineProtocol.outputFileName

    public init(id: String = UUID().uuidString, generator: Generator, process: String, events: Int, seed: Int) {
        self.id = id
        self.generator = generator
        self.process = process
        self.events = events
        self.seed = seed
    }
}

/// How far the job has got; the engine rewrites it as it runs.
public struct MCStatus: Codable, Equatable {
    public enum State: String, Codable { case queued, running, finished, failed, cancelled }
    public var state: State
    public var jobID: String
    /// 0 to 1, or nil when the engine cannot tell.
    public var progress: Double?
    public var eventsWritten: Int = 0
    /// Cross section in pb as the generator sees it after showering (it may reweight).
    public var crossSection: Double?
    public var crossSectionError: Double?
    public var message: String?
    /// Name and version of what actually ran ("Pythia 8.310").
    public var generatorVersion: String?
    public var seconds: Double?

    public init(state: State, jobID: String) {
        self.state = state
        self.jobID = jobID
    }
}

/// What the engine can do, published in its support folder so that TreeLevel can show it without launching it.
public struct MCCapabilities: Codable, Equatable {
    public var protocolVersion = MCEngineProtocol.version
    public var engineVersion: String
    /// Generators actually available in this installation (a module may not be downloaded yet).
    public var generators: [MCJob.Generator]
    /// Version of each generator, by its raw value ("pythia8": "8.310").
    public var versions: [String: String] = [:]
    public init(engineVersion: String, generators: [MCJob.Generator]) {
        self.engineVersion = engineVersion
        self.generators = generators
    }
}

/// Reads and writes a job folder: TreeLevel fills it, the engine consumes it and writes back.
public struct MCJobFolder {
    public var url: URL
    public init(_ url: URL) { self.url = url }

    public var jobURL: URL { url.appendingPathComponent(MCEngineProtocol.jobFileName) }
    public var statusURL: URL { url.appendingPathComponent(MCEngineProtocol.statusFileName) }
    public var logURL: URL { url.appendingPathComponent(MCEngineProtocol.logFileName) }
    public func inputURL(_ job: MCJob) -> URL { url.appendingPathComponent(job.input) }
    public func outputURL(_ job: MCJob) -> URL { url.appendingPathComponent(job.output) }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Creates the folder and writes the job with its events.
    @discardableResult
    public func write(job: MCJob, lheText: String) throws -> MCJob {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try lheText.write(to: inputURL(job), atomically: true, encoding: .utf8)
        try Self.encoder.encode(job).write(to: jobURL)
        try write(status: MCStatus(state: .queued, jobID: job.id))
        return job
    }

    public func readJob() throws -> MCJob { try JSONDecoder().decode(MCJob.self, from: Data(contentsOf: jobURL)) }
    public func write(status: MCStatus) throws { try Self.encoder.encode(status).write(to: statusURL) }
    public func readStatus() -> MCStatus? {
        (try? Data(contentsOf: statusURL)).flatMap { try? JSONDecoder().decode(MCStatus.self, from: $0) }
    }
    public func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}
