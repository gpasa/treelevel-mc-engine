// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Guglielmo Pasa.

import Foundation

/// What a module needs done once, on this machine, before it can run.
///
/// The generators are built with a prefix compiled into them, and an application can live anywhere: the
/// packaging script replaces that prefix with a token in every text file, and what remains is fixed here,
/// in a writable folder — the application bundle stays read-only and signed, as it must.
enum ModuleSetup {
    /// ~/Library/Application Support/TreeLevel MC Engine/prepared/<module>
    static func preparedDirectory(for module: String) -> URL {
        let dir = Installation.supportDirectory.appendingPathComponent("prepared/\(module)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Herwig's repository holds absolute paths to its own data files, so it cannot travel. It is rebuilt
    /// here, once, from the `defaults` that ship with the module — copied out of the bundle with the token
    /// replaced by wherever the module really is.
    ///
    /// Returns the repository to hand to `Herwig read` and `Herwig run`, or nil if the module has none
    /// (a system installation whose compiled-in paths are already right).
    static func herwigRepository(module: URL, log: (String) -> Void = { _ in }) -> URL? {
        let defaults = module.appendingPathComponent("share/Herwig/defaults")
        guard FileManager.default.fileExists(atPath: defaults.appendingPathComponent("HerwigDefaults.in").path) else {
            return nil
        }
        let prepared = preparedDirectory(for: "herwig7")
        let repository = prepared.appendingPathComponent("HerwigDefaults.rpo")
        let stamp = prepared.appendingPathComponent("built-from.txt")
        let current = module.path

        // Already built for this module, at this place? Then nothing to do.
        if FileManager.default.fileExists(atPath: repository.path),
           let previous = try? String(contentsOf: stamp, encoding: .utf8), previous == current {
            return repository
        }

        log("préparation du module Herwig (une seule fois)")
        let copy = prepared.appendingPathComponent("defaults", isDirectory: true)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: defaults, to: copy)
            try substitute(Installation.modulePlaceholder, with: current, in: copy)
        } catch {
            log("copie des valeurs par défaut impossible : \(error.localizedDescription)")
            return nil
        }

        guard let herwig = Installation.herwig else { return nil }
        let arguments = ["init", copy.appendingPathComponent("HerwigDefaults.in").path,
                         "--repo", repository.path, "-I", copy.path] + searchPaths(module: module)
        guard let output = Process.output(herwig, arguments, environment: environment(module: module)),
              FileManager.default.fileExists(atPath: repository.path) else {
            log("Herwig init a échoué")
            return nil
        }
        if !output.isEmpty { log(output) }
        try? current.write(to: stamp, atomically: true, encoding: .utf8)
        return repository
    }

    /// The library search paths ThePEG needs: it loads its plugins by bare name.
    static func searchPaths(module: URL) -> [String] {
        ["-L", module.appendingPathComponent("lib/Herwig").path,
         "-L", module.appendingPathComponent("lib/ThePEG").path]
    }

    /// LHAPDF looks for its configuration where it was built; this says where it really is.
    static func environment(module: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let data = module.appendingPathComponent("share/LHAPDF").path
        if FileManager.default.fileExists(atPath: data) {
            environment["LHAPDF_DATA_PATH"] = data
            environment["LHAPATH"] = data
        }
        return environment
    }

    /// Pythia reads its particle data and settings from an `xmldoc` folder; when the driver travels with
    /// one, say where it is rather than relying on the system layouts it knows.
    static func pythiaEnvironment(driver: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let data = driver.deletingLastPathComponent().appendingPathComponent("share/Pythia8/xmldoc")
        if FileManager.default.fileExists(atPath: data.path) { environment["PYTHIA8DATA"] = data.path }
        return environment
    }

    /// Où Sherpa doit chercher ses propres greffons, ses données et ses en-têtes.
    ///
    /// Sans cela il les charge depuis l'arbre où il a été *construit*, dont le chemin est gravé à la
    /// compilation — et ces greffons-là tirent le libstdc++ du gestionnaire de paquets, pendant que les
    /// binaires du module utilisent celui qu'ils emportent. Deux bibliothèques standard C++ dans un même
    /// processus, deux jeux de symboles, et une chaîne allouée par l'une que l'autre libère :
    /// « pointer being freed was not allocated », au beau milieu de l'initialisation du modèle standard.
    /// Chez l'utilisateur, qui n'a pas cet arbre de construction, la panne serait différente mais réelle.
    static func sherpaEnvironment(binary: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let racine = binary.deletingLastPathComponent().deletingLastPathComponent()
        for (variable, sous) in [("SHERPA_LIBRARY_PATH", "lib/SHERPA-MC"),
                                 ("SHERPA_SHARE_PATH", "share/SHERPA-MC"),
                                 ("SHERPA_INCLUDE_PATH", "include/SHERPA-MC")] {
            let chemin = racine.appendingPathComponent(sous)
            if FileManager.default.fileExists(atPath: chemin.path) { environment[variable] = chemin.path }
        }
        return environment
    }

    /// Replaces a string in every text file of a folder, in place.
    /// Remplace le jeton du module par un chemin, dans tout un arbre. CalcHEP en a besoin : il compile chez
    /// l'utilisateur et ses fichiers de drapeaux portent le jeton, pas un chemin.
    static func replacePlaceholder(in folder: URL, with value: String) throws {
        try substitute(Installation.modulePlaceholder, with: value, in: folder)
    }

    private static func substitute(_ token: String, with value: String, in folder: URL) throws {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = files?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8), text.contains(token) else { continue }
            try text.replacingOccurrences(of: token, with: value).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
