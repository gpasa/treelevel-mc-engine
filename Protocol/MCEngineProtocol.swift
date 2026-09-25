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
    /// 2: a job may describe a process instead of carrying events, for the generators that compute their own.
    public static let version = 2

    /// La version des outils : le moteur de chaque système et l'image qui porte les générateurs sont une même
    /// chose sous deux formes, et ils répondent à un seul numéro. Il est écrit ici, dans le fichier que les deux
    /// plateformes partagent, pour qu'aucune ne puisse demander une image que l'autre ne demanderait pas.
    ///
    /// Il se déduisait auparavant de la version de chaque moteur, et macOS s'accrochait alors à une étiquette
    /// pendant que Windows retombait sur une autre — la même image aujourd'hui, aucune garantie demain. Les deux
    /// moteurs sont publiés ensemble et portent aussi ce numéro dans leur fichier de projet ; quand il bouge, il
    /// bouge partout.
    public static let toolsVersion = "0.3.0"

    public static let jobFileName = "job.json"
    public static let inputFileName = "events.lhe"
    public static let statusFileName = "status.json"
    public static let outputFileName = "events.hepmc"
    public static let logFileName = "engine.log"
    /// Bundle identifier of the engine application, and the URL scheme it answers to.
    ///
    /// Le programme s'appelait « TreeLevel MC Engine » pendant son développement. Le nom ne disait plus
    /// ce qu'il fait — il ne porte pas que des moteurs Monte-Carlo — et l'image qui offre les mêmes outils
    /// s'appelle déjà `treelevel-tools`. Rien n'ayant été publié sous l'ancien nom, il n'en reste aucune
    /// trace à ménager : pas de repli, pas de migration.
    public static let bundleIdentifier = "org.pasahome.TreeLevelTools"
    public static let urlScheme = "treelevel-tools"
    /// Where the engine publishes what it can do, inside its own support folder.
    public static let capabilitiesFileName = "capabilities.json"

    /// TreeLevel is sandboxed: everything the two programs share lives in its container, which the engine —
    /// which is not sandboxed — can read and write. Seen from the engine, that is:
    ///   ~/Library/Containers/org.pasahome.Feyn/Data/Library/Application Support/{MCJobs,TreeLevel Tools}
    /// Seen from TreeLevel, it is simply its own Application Support folder.
    public static let treeLevelBundleIdentifier = "org.pasahome.Feyn"
    public static let jobsFolderName = "MCJobs"
    public static let supportFolderName = "TreeLevel Tools"

    /// Only meaningful in a process that is not sandboxed (the engine).
    public static var treeLevelSupportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(treeLevelBundleIdentifier)/Data/Library/Application Support", isDirectory: true)
    }

    /// The URL that asks a running engine to take a job: it reaches it whether it is already open or not.
    public static func runURL(job folder: URL) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "run"
        components.queryItems = [URLQueryItem(name: "job", value: folder.path)]
        return components.url
    }
}

/// What to run on the parton-level events.
public struct MCJob: Codable, Equatable {
    public enum Generator: String, Codable, CaseIterable {
        case pythia8, herwig7, sherpa3, whizard3, calchep3
        /// No shower: the events are copied through, to check the plumbing.
        case passthrough
        public var label: String {
            switch self {
            case .pythia8: return "Pythia 8"
            case .herwig7: return "Herwig 7"
            case .sherpa3: return "Sherpa 3"
            case .whizard3: return "WHIZARD 3"
            case .calchep3: return "CalcHEP 3"
            case .passthrough: return "sans gerbe"
            }
        }
        /// Whether the generator starts from the events TreeLevel wrote, or computes the process itself.
        /// Sherpa has no Les Houches reader — it only writes that format — and WHIZARD and CalcHEP are
        /// matrix-element generators to begin with, so all three belong to the second family.
        public var readsLesHouches: Bool {
            switch self {
            case .pythia8, .herwig7, .passthrough: return true
            case .sherpa3, .whizard3, .calchep3: return false
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
    /// Parton shower (initial and final state radiation). Ignored by a generator that only computes the
    /// hard process: CalcHEP stops at parton level and says so.
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
    /// What to compute, for a generator that does not read the events TreeLevel wrote (`readsLesHouches`
    /// is false). TreeLevel fills it from the diagram; it is ignored by the others.
    public var hardProcess: MCProcess?
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

/// A hard process described so that a generator can compute it by itself: beams, energies, final state and
/// the coupling orders that pick the right diagrams. Deliberately small — everything else is the generator's
/// own business, and its defaults are better than anything we would invent.
public struct MCProcess: Codable, Equatable {
    /// PDG codes of the two beams (11 and -11 for an electron–positron machine).
    public var beams: [Int]
    /// Energy of each beam in GeV, so that asymmetric machines can be written down.
    public var beamEnergies: [Double]
    /// PDG codes of the hard final state.
    public var finalState: [Int]
    /// Coupling orders of the hard process, by the name generators use ("QCD", "EW").
    public var couplingOrders: [String: Int]
    /// Minimum transverse momentum of the final state in GeV; nil keeps the generator's own cuts.
    public var minimumPT: Double?
    /// Physics model. Only "SM" for now, but a generator that reads UFO files could take more.
    public var model: String

    /// What we ask the machine for. In `exclusive` mode — the historic one — the generator produces the
    /// diagram's process and nothing else, and its cross section *is* the answer. In `collider` mode it
    /// opens whole families of hard channels, the way a real ring does: `finalState` then says what to look
    /// for in the events rather than what to produce, and the measured cross section comes out of that
    /// selection. The two disagree for an honest reason — a real machine cannot be told to make only one
    /// thing — and showing them side by side is the point of the mode.
    public enum Mode: String, Codable, CaseIterable { case exclusive, collider }
    public var colliderMode: Mode = .exclusive

    /// A fixed target: one beam moves, the other sits still in the laboratory.
    ///
    /// `beamEnergies[0]` is then the momentum of the moving beam and the second entry is ignored — the
    /// target's energy is its own mass, and saying so exactly matters more than it looks: giving it a
    /// number close to its mass leaves it a small momentum, and the collision energy is no longer quite
    /// the one intended. What this buys is modest and worth seeing: 400 GeV on a proton at rest is a
    /// 27 GeV machine, because only √(2 m E) of it is available.
    public var fixedTarget = false

    /// The families of hard channels left open in `collider` mode.
    ///
    /// `singleBoson` is annihilation — ff̄ → γ*/Z, ff̄' → W — and needs two beams that can annihilate.
    /// `bosonPair` covers WW, ZZ and ZW, above their threshold, and needs the same.
    /// `bosonExchange` is the t channel: the two beams scatter off each other by passing a γ, a Z or a W
    /// between them. Nothing has to annihilate, which is why an electron and a proton make a perfectly
    /// good machine — HERA was one — and why leaving this family out would rule out a whole kind of
    /// collider rather than a mistaken setting.
    /// `qcd` is hard parton scattering, which is the bulk of what a proton ring makes: without it a hadron
    /// machine produces Drell–Yan and nothing else, which is a channel rather than a collider. It diverges
    /// as the transverse momentum goes to zero, so it is the one family that insists on a floor.
    /// `photoproduction` fait entrer un lepton par le flux de photons qu'il rayonne : la photoproduction
    /// sur un hadron, la physique à deux photons entre deux leptons. Elle **remplace** le faisceau au lieu
    /// de s'y ajouter — Pythia ne fait pas collisionner le lepton et son photon dans le même tirage — et
    /// c'est pourquoi le moteur refuse de la combiner sans `mixConfigurations`.
    ///
    /// `soft` est la QCD molle : élastique, diffractif, fond non diffractif. C'est la seule famille qui
    /// rende « tout ce que la machine produit » littéralement vrai — 100 mb à 13 TeV contre 0,7 pour la
    /// diffusion dure. Elle n'admet aucun seuil en impulsion transverse, qui retrancherait précisément ce
    /// qu'on vient voir, et elle ne se combine pas avec `qcd` : son fond non diffractif contient déjà la
    /// diffusion dure, que ses interactions multiples fabriquent.
    public enum Channel: String, Codable, CaseIterable {
        case singleBoson, bosonPair, bosonExchange, qcd, photoproduction, soft
    }
    public var channels: [Channel] = [.singleBoson]

    /// Tirer deux configurations de machine et les assembler, quand les voies demandées ne peuvent pas
    /// vivre dans le même tirage — le flux de photons remplaçant le faisceau. Le moteur produit alors un
    /// échantillon par configuration et les entremêle ; la section efficace du fichier est leur somme.
    public var mixConfigurations = false

    /// Dans un assemblage, donner à chaque configuration la moitié des événements plutôt que la part que
    /// sa section efficace lui vaut. La configuration rare devient regardable, au prix d'un échantillon
    /// pondéré : les événements ne comptent plus pour un, et les barres d'erreur s'élargissent.
    public var mixEqualShares = false

    public init(beams: [Int], beamEnergies: [Double], finalState: [Int],
                couplingOrders: [String: Int] = [:], minimumPT: Double? = nil, model: String = "SM",
                colliderMode: Mode = .exclusive, channels: [Channel] = [.singleBoson]) {
        self.colliderMode = colliderMode
        self.channels = channels
        self.beams = beams
        self.beamEnergies = beamEnergies
        self.finalState = finalState
        self.couplingOrders = couplingOrders
        self.minimumPT = minimumPT
        self.model = model
    }

    /// Centre-of-mass energy of a head-on collision.
    public var centreOfMassEnergy: Double { beamEnergies.reduce(0, +) }

    /// Written by hand because the two fields above arrived after job folders had already been saved: a
    /// synthesised decoder would reject every one of them for a key that did not exist yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beams = try c.decode([Int].self, forKey: .beams)
        beamEnergies = try c.decode([Double].self, forKey: .beamEnergies)
        finalState = try c.decode([Int].self, forKey: .finalState)
        couplingOrders = try c.decodeIfPresent([String: Int].self, forKey: .couplingOrders) ?? [:]
        minimumPT = try c.decodeIfPresent(Double.self, forKey: .minimumPT)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "SM"
        colliderMode = try c.decodeIfPresent(Mode.self, forKey: .colliderMode) ?? .exclusive
        channels = try c.decodeIfPresent([Channel].self, forKey: .channels) ?? [.singleBoson]
        mixConfigurations = try c.decodeIfPresent(Bool.self, forKey: .mixConfigurations) ?? false
        mixEqualShares = try c.decodeIfPresent(Bool.self, forKey: .mixEqualShares) ?? false
        fixedTarget = try c.decodeIfPresent(Bool.self, forKey: .fixedTarget) ?? false
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
    /// Number given by the engine when it takes the job, so that the two programs and the user name it the
    /// same way ("travail 7").
    public var number: Int?
    public var started: Date?
    public var finished: Date?

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
        // A generator that computes its own matrix elements is given the process, and no events to dress —
        // et il en va de même d'un travail en mode collisionneur, qui produit les siens. Y déposer un
        // fichier Les Houches vide ne tromperait personne longtemps, mais un moteur qui décide à la
        // présence du fichier plutôt qu'au contenu du travail s'y laisserait prendre.
        if job.generator.readsLesHouches, job.hardProcess?.colliderMode != .collider {
            try lheText.write(to: inputURL(job), atomically: true, encoding: .utf8)
        }
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
