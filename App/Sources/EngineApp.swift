import SwiftUI
import AppKit

/// The engine as an application: TreeLevel asks LaunchServices to open it with `run <job folder>`, which
/// starts it outside TreeLevel's sandbox. The window shows what is running and where the modules are.
@main
struct EngineApp: App {
    @NSApplicationDelegateAdaptor(EngineDelegate.self) private var delegate
    @StateObject private var state = EngineState.shared

    var body: some Scene {
        Window("TreeLevel MC Engine", id: "main") {
            EngineWindow().environmentObject(state)
        }
        .defaultSize(width: 620, height: 460)
    }
}

final class EngineDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineState.shared.refreshCapabilities()
        EngineState.shared.reloadHistory()
        // `run <folder>` on the command line, or a job folder dropped on the application.
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count >= 2, args[0] == "run" { EngineState.shared.run(folder: URL(fileURLWithPath: args[1], isDirectory: true)) }
        EngineState.shared.takePendingJobs()
        // Opening the engine again is another way of saying "look for work".
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            EngineState.shared.takePendingJobs()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // treelevel-mc://run?job=<path> — this reaches the engine whether it was running or not — or a folder.
            if url.isFileURL { EngineState.shared.run(folder: url) }
            else if let job = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "job" })?.value {
                EngineState.shared.run(folder: URL(fileURLWithPath: job, isDirectory: true))
            }
        }
    }

    /// The engine keeps running with its window closed (a job may be under way); opening it again must bring
    /// the window back rather than just activate an invisible application.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func showWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// What the window shows: the jobs this launch has run, and the modules found.
@MainActor
final class EngineState: ObservableObject {
    static let shared = EngineState()
    @Published var entries: [JobHistory.Entry] = []
    @Published var capabilities: MCCapabilities?
    let version = "0.1.1"


    func refreshCapabilities() { capabilities = Installation.publishCapabilities(engineVersion: version) }

    /// The list of jobs lives in the support folder and survives between launches.
    func reloadHistory() { entries = JobHistory.load() }

    /// Runs the jobs TreeLevel has left queued in its container, ignoring the ones already taken.
    func takePendingJobs() {
        for folder in Installation.pendingJobs() where !taken.contains(folder.url.path) {
            run(folder: folder.url)
        }
    }
    private var taken = Set<String>()

    func clearHistory() {
        JobHistory.save([])
        entries = []
    }

    /// Runs a job on a background queue and keeps the window in step with its status file.
    func run(folder url: URL) {
        let folder = MCJobFolder(url)
        guard let job = try? folder.readJob(), !taken.contains(url.path) else { return }
        taken.insert(url.path)
        let number = Installation.nextJobNumber()
        var queued = MCStatus(state: .queued, jobID: job.id)
        queued.number = number
        entries = JobHistory.record(JobHistory.entry(job: job, folder: folder, status: queued))
        let version = version
        Task.detached(priority: .userInitiated) {
            let runner = Runner(folder: folder, job: job, engineVersion: version, number: number)
            // The runner keeps the list up to date as it goes; the window follows it.
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.reloadHistory()
                }
            }
            _ = runner.run()
            watcher.cancel()
            await MainActor.run {
                self.reloadHistory()
                self.refreshCapabilities()
            }
        }
    }
}

struct EngineWindow: View {
    @EnvironmentObject var state: EngineState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TreeLevel MC Engine").font(.title2.bold())
            Text("Gerbe partonique et hadronisation des événements de TreeLevel, sur cette machine. Les générateurs (Pythia 8, Herwig 7) sont sous licence GPL ; ce programme les pilote, TreeLevel ne les contient pas.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Modules") {
                VStack(alignment: .leading, spacing: 4) {
                    if let caps = state.capabilities {
                        ForEach(caps.generators, id: \.rawValue) { g in
                            Text("• \(g.label)" + (caps.versions[g.rawValue].map { " \($0)" } ?? ""))
                        }
                    } else {
                        Text("Aucun module trouvé.")
                    }
                    Text("Emplacement : ~/Library/Application Support/TreeLevel MC Engine/Modules")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Travaux").font(.headline)
                Spacer()
                if !state.entries.isEmpty {
                    Button("Vider la liste") { state.clearHistory() }
                        .help("Oublie les travaux passés ; les dossiers et leurs journaux restent où ils sont")
                }
            }
            if state.entries.isEmpty {
                Text("Rien pour l'instant. TreeLevel ouvre ce programme quand vous choisissez un générateur externe.")
                    .foregroundStyle(.secondary)
            }
            // A plain scrolling stack rather than a List: the first row of a List was starting scrolled,
            // which hid the number and the process of the newest job.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.entries) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(e.number).")
                                .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(e.process) — \(e.generator)").bold()
                                Text(label(e) + (times(e).isEmpty ? "" : " · " + times(e)))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Révéler le dossier du travail") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.folder)]) }
                            Button("Ouvrir le journal") { NSWorkspace.shared.open(URL(fileURLWithPath: e.folder).appendingPathComponent(MCEngineProtocol.logFileName)) }
                        }
                        Divider()
                    }
                }
            }
            .frame(minHeight: 160)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    /// "22 sept. 22:41:07 → 22:41:14 (6,4 s)"
    private func times(_ e: JobHistory.Entry) -> String {
        guard let started = e.started else { return "" }
        let day = Date.FormatStyle(date: .abbreviated, time: .standard)
        let clock = Date.FormatStyle(date: .omitted, time: .standard)
        var text = started.formatted(Calendar.current.isDateInToday(started) ? clock : day)
        if let finished = e.finished {
            let seconds = e.seconds ?? finished.timeIntervalSince(started)
            text += " → " + finished.formatted(clock) + String(format: " (%.1f s)", seconds)
        }
        return text
    }

    private func label(_ e: JobHistory.Entry) -> String {
        switch e.state {
        case .queued: return "en attente"
        case .running: return "\(e.events) événements…"
        case .finished: return "terminé — \(e.events) événements"
        case .failed: return "échec : " + (e.message ?? "")
        case .cancelled: return "annulé"
        }
    }
}
