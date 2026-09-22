import Foundation

/// The list of jobs the engine has run, kept between launches in its support folder, so that the numbers,
/// the times and the results stay readable long after the window was closed.
struct JobHistory {
    struct Entry: Codable, Identifiable, Equatable {
        var id: String            // the job's own identifier
        var number: Int
        var process: String
        var generator: String
        var folder: String
        var state: MCStatus.State
        var events: Int = 0
        var started: Date?
        var finished: Date?
        var seconds: Double?
        var message: String?
    }

    static var url: URL { Installation.supportDirectory.appendingPathComponent("jobs.json") }
    /// Older jobs are dropped beyond this; the log files stay in their folders.
    static let limit = 200

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(entries.prefix(limit))) else { return }
        try? data.write(to: url)
    }

    /// Adds a job, or brings the existing line up to date (same identifier).
    @discardableResult
    static func record(_ entry: Entry) -> [Entry] {
        var entries = load()
        if let k = entries.firstIndex(where: { $0.id == entry.id }) { entries[k] = entry } else { entries.insert(entry, at: 0) }
        entries.sort { $0.number > $1.number }
        save(entries)
        return entries
    }

    static func entry(job: MCJob, folder: MCJobFolder, status: MCStatus) -> Entry {
        Entry(id: job.id, number: status.number ?? 0, process: job.process, generator: job.generator.label,
              folder: folder.url.path, state: status.state, events: status.eventsWritten,
              started: status.started, finished: status.finished, seconds: status.seconds, message: status.message)
    }
}
