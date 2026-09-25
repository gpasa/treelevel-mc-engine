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
        // A generator that computes its own matrix elements is given a process, not events — and so is one
        // put in front of a machine in collider mode, which makes the hard process itself.
        if job.generator.readsLesHouches, job.hardProcess?.colliderMode != .collider,
           !FileManager.default.fileExists(atPath: folder.inputURL(job).path) {
            return finish(failed: "the job has no input file (\(job.input))", start: start)
        }
        do {
            switch job.generator {
            case .passthrough: return try passthrough(start: start)
            case .pythia8: return try pythia(start: start)
            case .herwig7: return try herwig(start: start)
            case .sherpa3: return try sherpa(start: start)
            case .whizard3: return try whizard(start: start)
            case .calchep3: return try calchep(start: start)
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
        if let result = containerIfNotNative(start) { return result }
        guard let driver = Installation.pythiaDriver else {
            return finish(failed: "the Pythia 8 module is not installed", start: start)
        }
        // Two ways in. Usually Pythia dresses the events TreeLevel computed, and reads them from the Les
        // Houches file. In collider mode it makes the hard process itself, from beams and open channels,
        // and the Les Houches file has no part in it — there is nothing to dress that we chose.
        // The generators run with the job folder as their working directory and are given relative names:
        // Pythia reads `Beams:LHEF` as a single word, so a path with spaces (and the job folder lives under
        // "Application Support") would be cut short.
        let beams: String
        if let p = job.hardProcess, p.colliderMode == .collider {
            // Pythia refuse ces cas en imprimant une table de processus vide, sans un mot d'explication,
            // et le journal ne montre alors qu'une bannière. On les nomme donc avant de le lancer.
            if let raison = Self.colliderObjection(p, driver: driver) {
                return finish(failed: raison, start: start)
            }
            guard let block = Self.pythiaCollider(p) else {
                return finish(failed: "collider mode needs two beams and their energies", start: start)
            }
            beams = block
        } else {
            beams = """
            Beams:frameType = 4
            Beams:LHEF = \(job.input)
            """
        }
        var settings = """
        \(beams)
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
                              name: "Pythia 8 " + (Installation.capabilities(engineVersion: engineVersion).versions["pythia8"] ?? ""),
                              environment: ModuleSetup.pythiaEnvironment(driver: driver))
    }

    /// Why this machine cannot work, in one sentence, or nil when nothing is obviously wrong.
    ///
    /// Two causes cover nearly every refusal, and Pythia names neither: it prints its banner, then an empty
    /// process table, then stops. Saying it ourselves turns a dead end into an instruction.
    static func colliderObjection(_ p: MCProcess, driver: URL) -> String? {
        guard p.beams.count == 2 else { return nil }
        let hadronic = p.beams.map { abs($0) >= 100 }
        // Les grilles de densités partoniques ne servent qu'aux faisceaux composites — c'est pourquoi leur
        // absence reste invisible tant qu'on ne fait que des leptons.
        if hadronic.contains(true) {
            let data = driver.deletingLastPathComponent()
                .appendingPathComponent("share/Pythia8/pdfdata", isDirectory: true)
            if !FileManager.default.fileExists(atPath: data.path) {
                return "a hadron beam needs Pythia's parton-density grids (share/Pythia8/pdfdata), "
                     + "which this module does not carry — reinstall the Pythia 8 module"
            }
        }
        // Les voies d'annihilation demandent une particule et son antiparticule, ou deux hadrons dont les
        // partons s'en chargent. La voie t n'exige rien de tel : elle n'objecte donc jamais, et une machine
        // électron-proton reste parfaitement légitime — c'est de la diffusion, pas de l'annihilation.
        let annihilent = (hadronic[0] && hadronic[1]) || p.beams[0] == -p.beams[1]
        let ouvertes = p.channels.filter { canal in
            switch canal {
            case .singleBoson, .bosonPair: return annihilent
            case .bosonExchange: return true
            }
        }
        if ouvertes.isEmpty && !p.channels.isEmpty {
            return "beams \(p.beams[0]) and \(p.beams[1]) cannot annihilate, so the channels asked for "
                 + "(ff̄ → γ*/Z, ff̄ → VV) have nothing to work with — these two scatter rather than "
                 + "annihilate, which is the boson-exchange family"
        }
        return nil
    }

    /// The Pythia settings that put it in front of a machine rather than in front of our events: the two
    /// beams, their energy, and the families of hard channels left open. What comes out is everything those
    /// channels make — the diagram's final state among the rest — and the selection happens afterwards, in
    /// TreeLevel, on the events as they are reconstructed. That is the whole point: a real ring cannot be
    /// asked for one final state, so the cross section we end up quoting is measured, not requested.
    static func pythiaCollider(_ p: MCProcess) -> String? {
        guard p.beams.count == 2, p.beamEnergies.count == 2 else { return nil }
        var lines = ["Beams:idA = \(p.beams[0])", "Beams:idB = \(p.beams[1])"]
        if p.fixedTarget {
            // Le repos de la cible se dit par ses trois composantes nulles, et non par une énergie égale à
            // sa masse : à donner un nombre voisin de la masse on lui laisse une petite impulsion, et
            // l'énergie de collision n'est plus tout à fait celle qu'on croit. `beamEnergies[0]` est alors
            // l'impulsion du faisceau, et Pythia tire l'énergie de la cible de sa propre table de masses.
            lines += ["Beams:frameType = 3",
                      "Beams:pxA = 0", "Beams:pyA = 0", "Beams:pzA = \(p.beamEnergies[0])",
                      "Beams:pxB = 0", "Beams:pyB = 0", "Beams:pzB = 0"]
        } else if abs(p.beamEnergies[0] - p.beamEnergies[1]) < 1e-9 {
            // Equal energies are said once, as the energy in the centre of mass; unequal ones oblige Pythia
            // to boost, and it wants them one by one.
            lines += ["Beams:frameType = 1", "Beams:eCM = \(p.centreOfMassEnergy)"]
        } else {
            lines += ["Beams:frameType = 2",
                      "Beams:eA = \(p.beamEnergies[0])", "Beams:eB = \(p.beamEnergies[1])"]
        }
        // A charged current needs a beam that can change flavour. Two leptons of opposite charge cannot,
        // so switching ffbar2W on there would only print a warning and produce nothing.
        let leptonic = p.beams.allSatisfy { (11...16).contains(abs($0)) }
        for channel in p.channels {
            switch channel {
            case .singleBoson:
                lines.append("WeakSingleBoson:ffbar2gmZ = on")
                if !leptonic { lines.append("WeakSingleBoson:ffbar2W = on") }
            case .bosonPair:
                lines += ["WeakDoubleBoson:ffbar2gmZgmZ = on", "WeakDoubleBoson:ffbar2ZW = on",
                          "WeakDoubleBoson:ffbar2WW = on"]
            case .bosonExchange:
                // La voie t : les deux faisceaux se diffusent en échangeant un boson. Rien ne s'annihile,
                // et c'est ce qui rend un anneau électron-proton possible. Le photon échangé diverge quand
                // Q² tend vers zéro ; Pythia pose son propre plancher (`pTHatMinDiverge`) faute de mieux,
                // et une coupure explicite le remplace dès qu'on en donne une.
                lines += ["WeakBosonExchange:ff2ff(t:gmZ) = on", "WeakBosonExchange:ff2ff(t:W) = on"]
            }
        }
        if let pt = p.minimumPT, pt > 0 { lines.append("PhaseSpace:pTHatMin = \(pt)") }
        return lines.joined(separator: "\n")
    }

    /// Herwig 7: written as a `.in` file, then `Herwig read` and `Herwig run`.
    private func herwig(start: Date) throws -> Bool {
        if let result = containerIfNotNative(start) { return result }
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
        // A module shipped inside the application carries paths from the machine that built it: its
        // repository is rebuilt here, once, and the search paths are named explicitly.
        let module = herwig.deletingLastPathComponent().deletingLastPathComponent()
        var extra = ModuleSetup.searchPaths(module: module)
        if let repository = ModuleSetup.herwigRepository(module: module, log: { self.append(toLog: $0) }) {
            extra += ["--repo", repository.path, "-I", module.appendingPathComponent("share/Herwig").path]
        }
        let environment = ModuleSetup.environment(module: module)
        guard try runProcess(herwig, ["read", "\(name).in"] + extra, start: start, name: version,
                             step: "lecture de la configuration", finishNow: false, environment: environment) else { return false }
        return try runProcess(herwig, ["run", "\(name).run", "-N", "\(job.events)"] + extra, start: start,
                              name: version, environment: environment)
    }

    /// Sherpa 3: it has no Les Houches reader, so it is given the process itself, as a YAML run card.
    /// It computes the matrix element (Comix), showers, hadronises and writes the HepMC3 itself.
    private func sherpa(start: Date) throws -> Bool {
        if let result = containerIfNotNative(start) { return result }
        guard let sherpa = Installation.sherpa else {
            return finish(failed: "the Sherpa 3 module is not installed", start: start)
        }
        guard let p = job.hardProcess, p.beams.count == 2, p.beamEnergies.count == 2, !p.finalState.isEmpty else {
            return finish(failed: "Sherpa computes the process itself and needs its description (beams, energies, final state)",
                          start: start)
        }
        let orders = p.couplingOrders.isEmpty ? "" :
            "\n    Order: {" + p.couplingOrders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        let outgoing = p.finalState.map { String($0) }.joined(separator: " ")
        var card = """
        BEAMS: [\(p.beams[0]), \(p.beams[1])]
        BEAM_ENERGIES: [\(p.beamEnergies[0]), \(p.beamEnergies[1])]
        EVENTS: \(job.events)
        RANDOM_SEED: \(job.seed % 900_000_000)
        PROCESSES:
        - \(p.beams[0]) \(p.beams[1]) -> \(outgoing):\(orders)
        SHOWER_GENERATOR: \(job.shower ? "CSS" : "None")
        FRAGMENTATION: \(job.hadronisation ? "Ahadic" : "None")
        MI_HANDLER: \(job.multipleInteractions ? "Amisic" : "None")
        HARD_DECAYS: {Enabled: \(job.decays)}
        EVENT_OUTPUT: HepMC3[\(job.output)]
        """
        // Sherpa donne d'office une structure aux faisceaux de leptons — la densité « PDFE », c'est-à-dire
        // le rayonnement initial de QED. La section efficace qu'il annonce n'est alors plus celle du
        // processus à √s : elle est dominée par le retour radiatif vers le Z, et sort six fois trop haut
        // (21 pb au lieu de 3,2 pour e⁻e⁺ → b b̄ à 200 GeV). Les autres générateurs calculent à énergie
        // fixe ; on aligne Sherpa, et qui veut le rayonnement le redemande dans les réglages libres.
        // Les faisceaux hadroniques, eux, ne sont rien sans leurs densités.
        if !p.beams.allSatisfy({ abs($0) > 100 }) { card += "\nPDF_LIBRARY: None" }
        if let pt = p.minimumPT {
            card += "\nSELECTORS:\n- [PT, \(p.finalState[0]), \(pt), E_CMS]"
        }
        if let extra = job.extraSettings, !extra.isEmpty { card += "\n" + extra }
        try (card + "\n").write(to: folder.url.appendingPathComponent("Sherpa.yaml"), atomically: true, encoding: .utf8)

        let version = Installation.capabilities(engineVersion: engineVersion).versions["sherpa3"] ?? "Sherpa 3"
        return try runProcess(sherpa, ["-f", "Sherpa.yaml"], start: start, name: version,
                              environment: ModuleSetup.sherpaEnvironment(binary: sherpa))
    }

    /// WHIZARD 3: a Sindarin script. O'Mega writes the matrix element in Fortran and compiles it on the
    /// spot, so the first run of a new process pays a few seconds of compiler before generating anything.
    private func whizard(start: Date) throws -> Bool {
        if let result = containerIfNotNative(start) { return result }
        // Sans conteneur il n'y a pas de voie : le dire ici, plutôt que de laisser le binaire natif
        // échouer plus loin sur un modèle introuvable ou un compilateur Fortran absent.
        // Celui de l'utilisateur, s'il l'a permis : lui sait où il est et a son compilateur.
        if Installation.systemWhizard != nil { return try whizardNative(start: start) }
        return finish(failed: Self.whizardNeedsContainer, start: start)
    }

    static let whizardNeedsContainer =
        "WHIZARD 3 only runs through the container on macOS: it compiles each process with gfortran, "
        + "which neither macOS nor Xcode provides. Turn the container on in the engine's window "
        + "(Docker required), or choose another generator."

    /// Le corps natif, conservé pour le jour où WHIZARD sera relogeable et son compilateur disponible.
    private func whizardNative(start: Date) throws -> Bool {
        guard let whizard = Installation.systemWhizard ?? Installation.whizard else {
            return finish(failed: "the WHIZARD 3 module is not installed", start: start)
        }
        guard let p = job.hardProcess, p.beams.count == 2, !p.finalState.isEmpty else {
            return finish(failed: "WHIZARD computes the process itself and needs its description (beams, energies, final state)",
                          start: start)
        }
        let all = p.beams + p.finalState
        guard let names = try? all.map({ code -> String in
            guard let name = Sindarin.name(of: code) else { throw Failure("WHIZARD does not know the particle \(code)") }
            return name
        }) else {
            return finish(failed: "WHIZARD does not know one of the particles of this process", start: start)
        }
        let sample = (job.output as NSString).deletingPathExtension     // it appends the format's extension
        // Initial-state radiation off the shower is WHIZARD's hadron-collision setting, and it refuses it
        // outright on a lepton machine; the QED radiation of a lepton beam is `?isr_active`, a different
        // thing, left to whoever asks for it in the extra settings — it would move the cross section.
        let hadronBeams = p.beams.allSatisfy { abs($0) > 100 }
        let script = """
        model = SM
        process job = \(names[0]), \(names[1]) => \(names.dropFirst(2).joined(separator: ", "))
        sqrts = \(p.centreOfMassEnergy) GeV
        seed = \(job.seed % 900_000_000)
        \(p.minimumPT.map { "cuts = all Pt > \($0) GeV [final]" } ?? "")
        ?ps_fsr_active = \(job.shower)
        ?ps_isr_active = \(job.shower && hadronBeams)
        ?hadronization_active = \(job.hadronisation)
        $hadronization_method = "PYTHIA6"
        n_events = \(job.events)
        $sample = "\(sample)"
        sample_format = lhef
        \(job.extraSettings ?? "")
        simulate (job)
        """
        try (script + "\n").write(to: folder.url.appendingPathComponent("job.sin"), atomically: true, encoding: .utf8)

        let version = Installation.capabilities(engineVersion: engineVersion).versions["whizard3"] ?? "WHIZARD 3"
        guard try runProcess(whizard, ["job.sin"], start: start, name: version,
                             finishNow: false, crossSection: Self.whizardCrossSection) else { return false }

        // WHIZARD écrit du Les Houches, et nous le convertissons — comme pour CalcHEP. Il sait aussi écrire
        // le HepMC3 lui-même, et c'est ce qu'il faisait : il s'arrêtait alors en fermant le fichier, sur
        // « pointer being freed was not allocated ». Sa colle C++ et la bibliothèque HepMC3 livrée avec lui
        // ne venaient pas de la même bibliothèque standard, l'une allouait et l'autre libérait. Passer par
        // le Les Houches supprime la question : le format est du Fortran de bout en bout, et le module n'a
        // plus besoin d'emporter HepMC3 du tout.
        let lhe = folder.url.appendingPathComponent(sample + ".lhe")
        guard FileManager.default.fileExists(atPath: lhe.path) else {
            return finish(failed: "\(version) wrote no event file — see engine.log", start: start)
        }
        let events = try LesHouchesLite.read(lhe)
        // La section efficace du journal porte son erreur d'intégration ; celle du fichier n'en a pas.
        let fromLog = Self.whizardCrossSection(in: (try? String(contentsOf: folder.logURL, encoding: .utf8)) ?? "")
        try LesHouchesLite.writeHepMC(events, to: folder.outputURL(job),
                                      crossSection: fromLog?.0 ?? events.crossSection)

        var done = MCStatus(state: .finished, jobID: job.id)
        done.number = number
        done.started = start
        done.finished = Date()
        done.eventsWritten = events.events.count
        done.crossSection = fromLog?.0 ?? events.crossSection
        done.crossSectionError = fromLog?.1
        done.generatorVersion = version
        done.progress = 1
        done.seconds = Date().timeIntervalSince(start)
        publish(done)
        return true
    }

    /// WHIZARD writes no cross section into its HepMC3, so it is read from the last line of its integration
    /// table — the combined result, in femtobarns.
    ///   "   6      29826  1.9440903E+04  6.30E+00    0.03    0.06   47.83    1.13   3"
    static func whizardCrossSection(in log: String) -> (Double, Double)? {
        var result: (Double, Double)?
        for line in log.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 4, Int(f[0]) != nil, Int(f[1]) != nil,
                  let value = Double(f[2]), let error = Double(f[3]),
                  f[2].contains("E"), value > 0 else { continue }
            result = (value / 1000, error / 1000)                       // fb → pb, as everywhere else here
        }
        return result
    }

    /// CalcHEP 3: it computes the hard process and stops there — no shower, no hadronisation. A job runs
    /// in a working copy of its tree, made by `mkWORKdir`, and leaves Les Houches events behind, which we
    /// turn into HepMC3 exactly as the passthrough backend does.
    private func calchep(start: Date) throws -> Bool {
        if let result = containerIfNotNative(start) { return result }
        guard let root = Installation.calchep else {
            return finish(failed: "the CalcHEP 3 module is not installed", start: start)
        }
        guard let p = job.hardProcess, p.beams.count == 2, !p.finalState.isEmpty else {
            return finish(failed: "CalcHEP computes the process itself and needs its description (beams, energies, final state)",
                          start: start)
        }
        let all = p.beams + p.finalState
        let names = all.map { CalcHEPNames.name(of: $0) }
        guard !names.contains(nil) else {
            return finish(failed: "CalcHEP does not know one of the particles of this process", start: start)
        }
        let incoming = names[0..<2].map { $0! }.joined(separator: ",")
        let outgoing = names[2...].map { $0! }.joined(separator: ",")

        // CalcHEP compile chaque processus à l'exécution, et ni `make` ni ses scripts ne savent traiter un
        // chemin qui contient une espace : `include $(CALCHEP)/FlagsForMake` devient deux fichiers, et
        // `make` n'offre aucune syntaxe pour le protéger. Or le dossier d'un travail vit dans le conteneur
        // de TreeLevel — « …/Application Support/MCJobs/… » —, qui en porte deux. On travaille donc dans le
        // temporaire du système, qui n'en a pas, et on rapatrie ensuite ce qui compte.
        let work = Self.spaceFreeWorkDirectory(for: job.id)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Le module aussi doit être atteignable sans espace : les Makefiles qu'engendre CalcHEP écrivent
        // `include $(CALCHEP)/FlagsForMake`. Et il porte le jeton que l'empaquetage a posé à la place du
        // préfixe de construction ; le remplacer par le vrai chemin y remettrait les espaces. On recopie
        // donc le module à côté du travail — dix-huit mégaoctets, une seconde — et on substitue le jeton
        // par cette copie-là, qui n'en a pas.
        let racine = work.deletingLastPathComponent().appendingPathComponent("module", isDirectory: true)
        try? FileManager.default.removeItem(at: racine)
        try FileManager.default.copyItem(at: root, to: racine)
        try ModuleSetup.replacePlaceholder(in: racine, with: racine.path)
        guard try runProcess(racine.appendingPathComponent("mkWORKdir"), [work.path], start: start,
                             name: "CalcHEP", step: "préparation du dossier de travail", finishNow: false) else { return false }

        let batch = """
        Model:         SM
        Model changed: False
        Gauge:         Feynman

        Process:   \(incoming)->\(outgoing)

        p1:        \(p.beamEnergies[0])
        p2:        \(p.beamEnergies[1])
        \(p.minimumPT.map { "Cut parameter:    T(\(names[2]!))\nCut invert:       False\nCut min:          \($0)\nCut max:" } ?? "")
        \(job.extraSettings ?? "")
        Number of events (per run step):  \(job.events)
        Filename:                         events
        NTuple:                           False
        Cleanup:                          False
        Parallelization method:           local
        Max number of nodes:              4
        Max number of processes per node: 1
        """
        try (batch + "\n").write(to: work.appendingPathComponent("batch_file"), atomically: true, encoding: .utf8)

        let version = Installation.calchepVersion(root) ?? "CalcHEP 3"
        guard try runProcess(work.appendingPathComponent("calchep_batch"), ["batch_file"], start: start,
                             name: version, workingDirectory: work, finishNow: false) else { bringBack(work); return false }

        // Le dossier de travail est dans le temporaire : on ramène le compte rendu tant qu'il existe, sinon
        // une panne ne laisserait rien à lire.
        bringBack(work)
        // CalcHEP gzips its Les Houches file; unpack it, then convert as the passthrough backend does.
        let packed = work.appendingPathComponent("batch_results/events-single.lhe.gz")
        guard FileManager.default.fileExists(atPath: packed.path) else {
            return finish(failed: "\(version) wrote no event file — see engine.log", start: start)
        }
        let lhe = folder.url.appendingPathComponent("events.lhe")
        guard try runProcess(URL(fileURLWithPath: "/usr/bin/gunzip"), ["-c", packed.path], start: start,
                             name: version, step: "lecture des événements", finishNow: false,
                             standardOutput: lhe) else { return false }
        let events = try LesHouchesLite.read(lhe)
        try LesHouchesLite.writeHepMC(events, to: folder.outputURL(job), crossSection: events.crossSection)

        var done = MCStatus(state: .finished, jobID: job.id)
        done.number = number
        done.started = start
        done.finished = Date()
        done.eventsWritten = events.events.count
        done.crossSection = events.crossSection
        done.generatorVersion = version + " (niveau partonique)"
        done.progress = 1
        done.seconds = Date().timeIntervalSince(start)
        publish(done)
        return true
    }

    // MARK: Running a generator

    /// Starts a program in the job folder, streams its output into engine.log, and updates the status from the
    /// lines that mention a number of events.
    /// Adds a line to the job's log, for the steps that happen outside a generator's own output.
    private func append(toLog message: String) {
        guard let handle = try? FileHandle(forWritingTo: folder.logURL) ?? nil else {
            try? (message + "\n").write(to: folder.logURL, atomically: true, encoding: .utf8); return
        }
        handle.seekToEndOfFile()
        handle.write(Data((message + "\n").utf8))
        try? handle.close()
    }

    private func runProcess(_ url: URL, _ arguments: [String], start: Date, name: String,
                            step: String? = nil, workingDirectory: URL? = nil, finishNow: Bool = true,
                            crossSection: ((String) -> (Double, Double)?)? = nil,
                            standardOutput: URL? = nil, environment givenEnvironment: [String: String]? = nil) throws -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory ?? folder.url
        var environment = givenEnvironment ?? ProcessInfo.processInfo.environment
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
        // Only a program whose output *is* the result writes elsewhere than the log (gunzip, here).
        if let standardOutput {
            FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: standardOutput)
        } else {
            process.standardOutput = pipe
        }
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
        // Not every generator writes its cross section into the events; some only print it.
        if done.crossSection == nil, let crossSection,
           let text = try? String(contentsOf: folder.logURL, encoding: .utf8),
           let (value, error) = crossSection(text) {
            done.crossSection = value
            done.crossSectionError = error
        }
        publish(done)
        return true
    }



    /// Passe la main au conteneur quand ce générateur-ci n'est pas disponible nativement — soit qu'aucun
    /// module ne soit installé, soit que celui qui l'est ne réponde pas. Le critère est exactement celui de
    /// `nativeCapabilities` : ce que TreeLevel voit dans la liste est ce qui tournera.
    private func containerIfNotNative(_ start: Date) -> Bool? {
        // Le conteneur ne se substitue à rien : il ne sert que si l'utilisateur l'a demandé.
        guard Installation.allowsContainer,
              !Installation.nativeCapabilities(engineVersion: engineVersion).generators.contains(job.generator),
              let container = Installation.container() else { return nil }
        return inContainer(container, start: start)
    }

    /// Le même travail, mené par le moteur qui tourne dans l'image. Le dossier est monté tel quel : rien
    /// n'est copié ni converti, le montage *est* le protocole, et le conteneur écrit lui-même sa progression
    /// dans le `status.json` que TreeLevel relit.
    ///
    /// C'est la seconde manière d'avoir les générateurs sur un Mac — celle de qui a déjà Docker et préfère
    /// ne pas installer une seconde fois sept cents mégaoctets de binaires. Les modules natifs restent
    /// prioritaires : ils tournent sans machine virtuelle.
    private func inContainer(_ container: (docker: URL, image: String), start: Date) -> Bool {
        var running = MCStatus(state: .running, jobID: job.id)
        running.number = number
        running.started = start
        running.message = "conteneur"
        running.generatorVersion = job.generator.label
        publish(running)

        let process = Process()
        process.executableURL = container.docker
        process.arguments = ["run", "--rm", "-v", folder.url.path + ":/job", container.image, "run", "/job"]
        process.currentDirectoryURL = folder.url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return finish(failed: "cannot start \(container.docker.lastPathComponent): \(error.localizedDescription)",
                          start: start)
        }
        // On vide le tuyau : un conteneur qui écrit beaucoup se bloquerait sur un tuyau plein. Son vrai
        // journal est celui qu'il écrit de l'intérieur, dans le dossier de travail.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        var status = folder.readStatus()
        if process.terminationStatus == 0, status?.state == .finished {
            // Le moteur de l'image a écrit le statut ; il ignore qu'il tournait dans une image. On le dit
            // ici, pour qu'un travail retrouvé six mois plus tard dise par où il est passé — et pour que
            // personne n'ait à deviner en comparant des sections efficaces.
            if var fini = status, !(fini.generatorVersion ?? "").contains("conteneur") {
                fini.generatorVersion = (fini.generatorVersion ?? job.generator.label) + " (conteneur)"
                publish(fini)
                status = fini
            }
            return true
        }
        if status?.state == .failed, let message = status?.message, !message.isEmpty {
            return finish(failed: message, start: start)
        }
        let reason = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                           .first(where: { !$0.isEmpty })
        return finish(failed: "the container stopped with code \(process.terminationStatus)"
                              + (reason.map { " — " + $0 } ?? ""), start: start)
    }

    /// Un dossier de travail sans espace, pour les générateurs dont les outils de compilation n'en
    /// supportent pas. Le temporaire du système convient : `/var/folders/…`, jamais d'espace, et le
    /// système le nettoie de lui-même si nous n'y parvenons pas.
    private static func spaceFreeWorkDirectory(for id: String) -> URL {
        let sain = id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("treelevel-calchep", isDirectory: true)
            .appendingPathComponent(String(sain), isDirectory: true)
    }

    /// Rapatrie ce qu'on voudra lire après coup : le compte rendu de CalcHEP et ses journaux de
    /// compilation. Les événements, eux, passent par `events.lhe` comme avant.
    private func bringBack(_ work: URL) {
        let fm = FileManager.default
        let cible = folder.url.appendingPathComponent("calchep", isDirectory: true)
        try? fm.removeItem(at: cible)
        try? fm.createDirectory(at: cible, withIntermediateDirectories: true)
        for nom in ["batch_file", "html", "Processes"] {
            let source = work.appendingPathComponent(nom)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.copyItem(at: source, to: cible.appendingPathComponent(nom))
        }
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

    /// "Pythia::next(): 1000 events have been generated" / "Herwig: 1000 events" / Sherpa's
    /// "XS = 16 pb ... Event 200 ( 0s elapsed / 0s left ) -> ETA: ...", whose other numbers — a cross
    /// section, a date — must not be mistaken for a count, hence the explicit "Event <n>" first.
    static func eventCount(in line: String) -> Int? {
        if let r = line.range(of: "Event ") {
            let digits = line[r.upperBound...].prefix { $0.isNumber }
            if let n = Int(digits) { return n }
        }
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


/// WHIZARD's own particle names, as its Standard Model calls them.
enum Sindarin {
    private static let names: [Int: (String, String)] = [       // (particle, antiparticle)
        1: ("d", "D"), 2: ("u", "U"), 3: ("s", "S"), 4: ("c", "C"), 5: ("b", "B"), 6: ("t", "T"),
        11: ("e1", "E1"), 12: ("n1", "N1"), 13: ("e2", "E2"), 14: ("n2", "N2"), 15: ("e3", "E3"), 16: ("n3", "N3"),
        21: ("gl", "gl"), 22: ("A", "A"), 23: ("Z", "Z"), 24: ("Wp", "Wm"), 25: ("H", "H"),
    ]
    static func name(of code: Int) -> String? {
        guard let pair = names[abs(code)] else { return nil }
        return code >= 0 ? pair.0 : pair.1
    }
}

struct Failure: Error { let message: String; init(_ m: String) { message = m } }


/// CalcHEP's own particle names, as its Standard Model calls them.
enum CalcHEPNames {
    private static let names: [Int: (String, String)] = [       // (particle, antiparticle)
        1: ("d", "D"), 2: ("u", "U"), 3: ("s", "S"), 4: ("c", "C"), 5: ("b", "B"), 6: ("t", "T"),
        11: ("e", "E"), 12: ("ne", "Ne"), 13: ("m", "M"), 14: ("nm", "Nm"), 15: ("l", "L"), 16: ("nl", "Nl"),
        21: ("G", "G"), 22: ("A", "A"), 23: ("Z", "Z"), 24: ("W+", "W-"), 25: ("h", "h"),
    ]
    static func name(of code: Int) -> String? {
        guard let pair = names[abs(code)] else { return nil }
        return code >= 0 ? pair.0 : pair.1
    }
}
