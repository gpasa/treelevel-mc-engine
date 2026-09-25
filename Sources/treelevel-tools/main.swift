import Foundation

// TreeLevel Tools — runs a parton shower and hadronisation on the parton-level events of a TreeLevel job.
//
//   treelevel-tools run <job folder>     read job.json, produce events.hepmc, keep status.json up to date
//   treelevel-tools capabilities [--out file]   what this installation can do
//   treelevel-tools version
//
// The generators are separate programs: the Pythia driver built by Backends/pythia (treelevel-pythia) and
// Herwig's own command line. Nothing here links against them.

let engineVersion = "0.3.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("treelevel-tools: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("""
    usage: treelevel-tools <command>
      run <job folder>            run the job written by TreeLevel (job.json, events.lhe)
      capabilities [--out file]   list the generators this installation can run, as JSON
      version
    """)
    exit(2)
}

switch command {
case "version":
    print("TreeLevel MC Engine \(engineVersion)")
case "capabilities":
    let caps = Installation.capabilities(engineVersion: engineVersion)
    let data = try! MCJobFolder.encoder.encode(caps)
    if let k = args.firstIndex(of: "--out"), k + 1 < args.count {
        try! data.write(to: URL(fileURLWithPath: args[k + 1]))
    } else {
        print(String(decoding: data, as: UTF8.self))
    }
case "run":
    guard args.count >= 2 else { fail("run needs the job folder") }
    let folder = MCJobFolder(URL(fileURLWithPath: args[1], isDirectory: true))
    let job: MCJob
    do { job = try folder.readJob() } catch { fail("cannot read \(folder.jobURL.path): \(error.localizedDescription)") }
    guard job.protocolVersion <= MCEngineProtocol.version else {
        var status = MCStatus(state: .failed, jobID: job.id)
        status.message = "This job needs a newer engine (protocol \(job.protocolVersion))."
        try? folder.write(status: status)
        fail("job protocol \(job.protocolVersion) is newer than this engine (\(MCEngineProtocol.version))")
    }
    let runner = Runner(folder: folder, job: job, engineVersion: engineVersion, number: Installation.nextJobNumber())
    exit(runner.run() ? 0 : 1)
default:
    fail("unknown command '\(command)'")
}
