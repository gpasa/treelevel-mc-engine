import Foundation

/// Just enough Les Houches and HepMC3 to pass events through without a shower: the engine does not carry
/// TreeLevel's physics library, and the real generators read and write these formats themselves.
enum LesHouchesLite {
    struct Particle {
        var pdg: Int, status: Int, mothers: (Int, Int), colour: (Int, Int)
        var px: Double, py: Double, pz: Double, e: Double, m: Double
    }
    struct Event { var particles: [Particle]; var weight: Double; var scale: Double }
    struct File { var events: [Event]; var crossSection: Double? }

    static func read(_ url: URL) throws -> File {
        let text = try String(contentsOf: url, encoding: .utf8)
        var events: [Event] = []
        var crossSection: Double?
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        func next() -> String? {
            while let l = lines.next() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.hasPrefix("#") { return t }
            }
            return nil
        }
        while let line = next() {
            if line.hasPrefix("<init") {
                _ = next()
                if let l = next() { crossSection = Double(l.split(separator: " ").first ?? "") }
            } else if line.hasPrefix("<event>") || line.hasPrefix("<event ") {
                guard let header = next() else { break }
                let h = header.split(separator: " ")
                guard h.count >= 6, let n = Int(h[0]), let weight = Double(h[2]), let scale = Double(h[3]) else { continue }
                var particles: [Particle] = []
                for _ in 0..<n {
                    guard let l = next() else { break }
                    let f = l.split(separator: " ").compactMap { Double($0) }
                    guard f.count >= 11 else { continue }
                    particles.append(Particle(pdg: Int(f[0]), status: Int(f[1]), mothers: (Int(f[2]), Int(f[3])),
                                              colour: (Int(f[4]), Int(f[5])), px: f[6], py: f[7], pz: f[8], e: f[9], m: f[10]))
                }
                events.append(Event(particles: particles, weight: weight, scale: scale))
                while let l = next(), !l.hasPrefix("</event") {}
            }
        }
        return File(events: events, crossSection: crossSection)
    }

    static func writeHepMC(_ file: File, to url: URL, crossSection: Double?) throws {
        var s = "HepMC::Version 3.02.00\nHepMC::Asciiv3-START_EVENT_LISTING\n"
        for (n, e) in file.events.enumerated() {
            let incoming = e.particles.enumerated().filter { $0.element.status == -1 }
            let others = e.particles.enumerated().filter { $0.element.status != -1 }
            s += "E \(n) 1 \(e.particles.count)\nU GEV MM\nW \(fmt(e.weight))\n"
            if n == 0, let xs = crossSection { s += "A 0 GenCrossSection \(fmt(xs)) 0 -1 -1\n" }
            var id: [Int: Int] = [:]
            var next = 1
            for (k, p) in incoming { id[k] = next; s += line(next, parent: 0, p, status: 4); next += 1 }
            s += "V -1 0 [" + incoming.map { String(id[$0.offset]!) }.joined(separator: ",") + "]\n"
            for (k, p) in others { id[k] = next; s += line(next, parent: -1, p, status: p.status == 1 ? 1 : 2); next += 1 }
        }
        s += "HepMC::Asciiv3-END_EVENT_LISTING\n"
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func line(_ id: Int, parent: Int, _ p: Particle, status: Int) -> String {
        "P \(id) \(parent) \(p.pdg) \(fmt(p.px)) \(fmt(p.py)) \(fmt(p.pz)) \(fmt(p.e)) \(fmt(p.m)) \(status)\n"
    }
    private static func fmt(_ x: Double) -> String { String(format: "%.10e", x) }
}
