using System.Text.Json;
using TreeLevel.MC;

// TreeLevel MC Engine (Windows) — runs a parton shower and hadronisation on the parton-level events of a
// TreeLevel job. The same protocol and the same commands as the macOS engine.
//
//   treelevel-mc run <job folder>              read job.json, produce events.hepmc, keep status.json up to date
//   treelevel-mc capabilities [--out file]     what this installation can do, as JSON
//   treelevel-mc version
//
// The generators are separate programs: the Pythia driver built by win/backends/pythia (treelevel-pythia.exe),
// and Herwig and Sherpa inside WSL. Nothing here links against them.
//
// Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later.

const string EngineVersion = "0.2.0";

Console.OutputEncoding = System.Text.Encoding.UTF8;
if (args.Length == 0)
{
    Console.WriteLine("""
    usage: treelevel-mc <command>
      run <job folder>            run the job written by TreeLevel (job.json, events.lhe)
      capabilities [--out file]   list the generators this installation can run, as JSON
      version
    """);
    return 2;
}

switch (args[0])
{
    case "version":
        Console.WriteLine($"TreeLevel MC Engine {EngineVersion}");
        return 0;

    case "capabilities":
    {
        var caps = Installation.Capabilities(EngineVersion);
        string json = JsonSerializer.Serialize(caps, MCEngineProtocol.JsonOptions);
        int k = Array.IndexOf(args, "--out");
        if (k >= 0 && k + 1 < args.Length) File.WriteAllText(args[k + 1], json, MCEngineProtocol.Utf8);
        else Console.WriteLine(json);
        // Publish it too, so that TreeLevel can read it without launching anything.
        Installation.PublishCapabilities(EngineVersion);
        return 0;
    }

    case "run":
    {
        if (args.Length < 2) return Fail("run needs the job folder");
        var folder = new MCJobFolder(args[1]);
        MCJob job;
        try { job = folder.ReadJob(); }
        catch (Exception e) { return Fail($"cannot read {folder.JobPath}: {e.Message}"); }
        if (job.ProtocolVersion > MCEngineProtocol.Version)
        {
            folder.WriteStatus(new MCStatus(MCStatus.State.Failed, job.Id)
            {
                Message = $"This job needs a newer engine (protocol {job.ProtocolVersion}).",
            });
            return Fail($"job protocol {job.ProtocolVersion} is newer than this engine ({MCEngineProtocol.Version})");
        }
        Installation.PublishCapabilities(EngineVersion);
        var runner = new Runner(folder, job, EngineVersion, Installation.NextJobNumber());
        return runner.Run() ? 0 : 1;
    }

    default:
        return Fail($"unknown command '{args[0]}'");
}

static int Fail(string message)
{
    Console.Error.WriteLine("treelevel-mc: " + message);
    return 1;
}
