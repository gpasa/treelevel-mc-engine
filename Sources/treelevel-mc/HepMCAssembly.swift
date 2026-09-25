import Foundation

/// Assemble deux échantillons HepMC3 en un seul.
///
/// Certaines voies ne peuvent pas partager un tirage : allumer le flux de photons d'un lepton **remplace**
/// le faisceau, et Pythia ne fait pas collisionner le lepton et son photon dans la même passe. Le seul
/// moyen honnête de montrer les deux est donc de tirer deux configurations de machine et de les réunir.
///
/// On ne relit pas les événements : on les manipule comme du texte. L'Asciiv3 se découpe sans ambiguïté —
/// tout ce qui précède le premier `E ` est l'en-tête, et chaque `E ` ouvre un événement jusqu'au suivant.
/// Écrire un lecteur complet pour renuméroter et repondérer serait du travail pour rien, et un lecteur de
/// plus à tenir juste.
enum HepMCAssembly {
    struct Sample {
        var header: [String]
        var events: [[String]]
        var crossSection: Double
        var error: Double
    }

    /// Découpe un fichier, et relève la section efficace que porte sa dernière ligne d'attribut — c'est
    /// celle d'après le dernier événement, donc la seule qui vaille.
    static func read(_ url: URL) throws -> Sample {
        let texte = try String(contentsOf: url, encoding: .utf8)
        var header: [String] = [], events: [[String]] = [], courant: [String] = []
        var xs = 0.0, err = 0.0
        for ligne in texte.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if ligne.hasPrefix("E ") {
                if !courant.isEmpty { events.append(courant) }
                courant = [ligne]
            } else if courant.isEmpty {
                header.append(ligne)
            } else {
                courant.append(ligne)
            }
            let champs = ligne.split(separator: " ").map(String.init)
            if champs.count >= 5, champs[0] == "A", champs[1] == "0", champs[2] == "GenCrossSection",
               let v = Double(champs[3]), let e = Double(champs[4]) { xs = v; err = e }
        }
        if !courant.isEmpty { events.append(courant) }
        return Sample(header: header, events: events, crossSection: xs, error: err)
    }

    /// Le poids d'un échantillon dans l'assemblage.
    ///
    /// Il est choisi pour que la somme des poids de chaque échantillon reste sa propre section efficace,
    /// tout en gardant une moyenne de 1 sur l'ensemble — de sorte qu'à parts proportionnelles les deux
    /// valent exactement 1 et que l'échantillon reste non pondéré.
    static func weight(crossSection: Double, kept: Int, totalKept: Int, totalCrossSection: Double) -> Double {
        guard kept > 0, totalCrossSection > 0, totalKept > 0 else { return 1 }
        return (crossSection / Double(kept)) * (Double(totalKept) / totalCrossSection)
    }

    /// Réunit deux échantillons : `count` événements en tout, partagés selon leurs sections efficaces ou
    /// par moitiés, entremêlés pour que le résultat se lise comme un seul tirage.
    static func assemble(_ a: Sample, _ b: Sample, count: Int, equalShares: Bool, to url: URL) throws {
        let total = a.crossSection + b.crossSection
        var nA: Int
        if equalShares {
            nA = min(a.events.count, count / 2)
        } else if total > 0 {
            nA = Int((Double(count) * a.crossSection / total).rounded())
        } else {
            nA = count / 2
        }
        nA = max(0, min(nA, min(a.events.count, count)))
        let nB = max(0, min(count - nA, b.events.count))

        let gardes = nA + nB
        let wA = weight(crossSection: a.crossSection, kept: nA, totalKept: gardes, totalCrossSection: total)
        let wB = weight(crossSection: b.crossSection, kept: nB, totalKept: gardes, totalCrossSection: total)

        // La section efficace du fichier est la somme des deux, et l'erreur leur somme quadratique : ce sont
        // deux mesures indépendantes de deux parts disjointes de ce que fait la machine.
        let erreur = (a.error * a.error + b.error * b.error).squareRoot()

        var sortie = a.header
        var numero = 0
        func poser(_ evenement: [String], poids: Double) {
            for ligne in evenement {
                // La marque de fin clôt le fichier, pas l'événement : elle se retrouve dans le dernier bloc
                // découpé, et la laisser passer fermerait la liste au milieu de l'assemblage.
                if ligne.hasPrefix("HepMC::Asciiv3-END_EVENT_LISTING") || ligne.isEmpty { continue }
                if ligne.hasPrefix("E ") {
                    // « E <numéro> <sommets> <particules> » : renuméroter, sinon deux événements portent le
                    // même numéro et un lecteur attentif s'en plaint.
                    var champs = ligne.split(separator: " ").map(String.init)
                    if champs.count >= 2 { champs[1] = String(numero) }
                    sortie.append(champs.joined(separator: " "))
                } else if ligne.hasPrefix("W ") {
                    sortie.append("W \(format(poids))")
                } else if ligne.hasPrefix("A 0 GenCrossSection") {
                    sortie.append("A 0 GenCrossSection \(format(total)) \(format(erreur)) -1 -1")
                } else {
                    sortie.append(ligne)
                }
            }
            numero += 1
        }
        // Entremêlés plutôt que mis bout à bout : un échantillon dont la première moitié vient d'une machine
        // et la seconde d'une autre se trahit au premier coup d'œil sur une distribution cumulée.
        var i = 0, j = 0
        while i < nA || j < nB {
            if i < nA { poser(a.events[i], poids: wA); i += 1 }
            if j < nB { poser(b.events[j], poids: wB); j += 1 }
        }
        sortie.append("HepMC::Asciiv3-END_EVENT_LISTING")
        sortie.append("")
        try sortie.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func format(_ x: Double) -> String { String(format: "%.10e", x) }
}
