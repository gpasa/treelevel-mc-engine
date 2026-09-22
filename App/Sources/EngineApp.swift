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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// What the window shows: the jobs this launch has run, and the modules found.
@MainActor
final class EngineState: ObservableObject {
    static let shared = EngineState()
    struct Entry: Identifiable { var id = UUID(); var process: String; var generator: String; var status: MCStatus }

    @Published var entries: [Entry] = []
    @Published var capabilities: MCCapabilities?
    let version = "0.1.1"

    func refreshCapabilities() { capabilities = Installation.publishCapabilities(engineVersion: version) }

    /// Runs the jobs TreeLevel has left queued in its container, ignoring the ones already taken.
    func takePendingJobs() {
        for folder in Installation.pendingJobs() where !taken.contains(folder.url.path) {
            run(folder: folder.url)
        }
    }
    private var taken = Set<String>()

    /// Runs a job on a background queue and keeps the window in step with its status file.
    func run(folder url: URL) {
        let folder = MCJobFolder(url)
        guard let job = try? folder.readJob(), !taken.contains(url.path) else { return }
        taken.insert(url.path)
        let entry = Entry(process: job.process, generator: job.generator.label, status: MCStatus(state: .queued, jobID: job.id))
        entries.insert(entry, at: 0)
        let id = entry.id
        let version = version
        Task.detached(priority: .userInitiated) {
            let runner = Runner(folder: folder, job: job, engineVersion: version)
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if let s = folder.readStatus(), let k = self.entries.firstIndex(where: { $0.id == id }) { self.entries[k].status = s }
                }
            }
            _ = runner.run()
            watcher.cancel()
            await MainActor.run {
                if let s = folder.readStatus(), let k = self.entries.firstIndex(where: { $0.id == id }) { self.entries[k].status = s }
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
            Text("Travaux").font(.headline)
            if state.entries.isEmpty {
                Text("Rien pour l'instant. TreeLevel ouvre ce programme quand vous choisissez un générateur externe.")
                    .foregroundStyle(.secondary)
            }
            List(state.entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.process) — \(e.generator)").bold()
                    HStack {
                        Text(label(e.status)).foregroundStyle(.secondary)
                        if let p = e.status.progress, e.status.state == .running { ProgressView(value: p).frame(width: 120) }
                    }
                    .font(.callout)
                }
            }
            .frame(minHeight: 140)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private func label(_ s: MCStatus) -> String {
        switch s.state {
        case .queued: return "en attente"
        case .running: return "\(s.eventsWritten) événements…"
        case .finished: return "terminé — \(s.eventsWritten) événements" + (s.seconds.map { String(format: " en %.1f s", $0) } ?? "")
        case .failed: return "échec : " + (s.message ?? "")
        case .cancelled: return "annulé"
        }
    }
}
