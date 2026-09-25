// SPDX-License-Identifier: MIT
// Shared between TreeLevel and TreeLevel MC Engine — keep this copy and TreeLevel's
// (src/FeynCore/Events/MCEngine.cs) identical, as the Swift Protocol/MCEngineProtocol.swift is on macOS.
// Copyright (c) 2026 Guglielmo Pasa. Permission is hereby granted, free of charge, to any person obtaining a
// copy of this file, to deal in it without restriction, provided this notice is kept.

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TreeLevel.MC;

/// <summary>Exchange format between TreeLevel and the external "TreeLevel MC Engine": a job folder holding the
/// job description, the parton-level events written by TreeLevel, the status the engine updates as it runs and
/// the showered events it produces. Everything stays on the machine — nothing is uploaded anywhere.</summary>
public static class MCEngineProtocol
{
    /// <summary>Bumped when the format changes in a way an older engine could not read.
    /// 2: a job may describe a process instead of carrying events, for the generators that compute their own.</summary>
    public const int Version = 2;

    /// <summary>The version of the tools: the engine on each system and the container image that carries the
    /// generators are one thing under two forms, and they answer to one number. It is written here, in the file
    /// the two platforms share, so that neither can ask for an image the other would not.
    ///
    /// It was derived from each engine's own version before, and that let macOS pin one tag while Windows fell
    /// back to another — the same image today, and no guarantee tomorrow. Both engines are released together and
    /// carry this number in their project file too; when it moves, it moves everywhere.</summary>
    public const string ToolsVersion = "0.3.0";

    public const string JobFileName = "job.json";
    public const string InputFileName = "events.lhe";
    public const string StatusFileName = "status.json";
    public const string OutputFileName = "events.hepmc";
    public const string LogFileName = "engine.log";
    public const string CapabilitiesFileName = "capabilities.json";
    public const string JobsFolderName = "MCJobs";
    public const string SupportFolderName = "TreeLevel MC Engine";

    /// <summary>The JSON Swift's Codable writes: camel-cased keys, enums as their raw value, dates as seconds
    /// since the Apple reference date, and no key at all for a nil value.</summary>
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(new LowercaseEnumPolicy()), new AppleDateConverter() },
    };

    public static readonly UTF8Encoding Utf8 = new(false);
}

/// <summary>What to run on the parton-level events.</summary>
public sealed class MCJob
{
    public enum Generator { Pythia8, Herwig7, Sherpa3, Whizard3, CalcHep3, Passthrough }

    public static readonly Generator[] AllGenerators =
        { Generator.Pythia8, Generator.Herwig7, Generator.Sherpa3, Generator.Whizard3, Generator.CalcHep3, Generator.Passthrough };

    public static string Label(Generator g) => g switch
    {
        Generator.Pythia8 => "Pythia 8",
        Generator.Herwig7 => "Herwig 7",
        Generator.Sherpa3 => "Sherpa 3",
        Generator.Whizard3 => "WHIZARD 3",
        Generator.CalcHep3 => "CalcHEP 3",
        _ => "sans gerbe",
    };

    /// <summary>The raw value the JSON uses ("pythia8", "herwig7"…), as the Swift enum's rawValue.</summary>
    public static string RawValue(Generator g) => g switch
    {
        Generator.Pythia8 => "pythia8",
        Generator.Herwig7 => "herwig7",
        Generator.Sherpa3 => "sherpa3",
        Generator.Whizard3 => "whizard3",
        Generator.CalcHep3 => "calchep3",
        _ => "passthrough",
    };

    /// <summary>Whether the generator starts from the events TreeLevel wrote, or computes the process itself.</summary>
    public static bool ReadsLesHouches(Generator g) => g is Generator.Pythia8 or Generator.Herwig7 or Generator.Passthrough;

    /// <summary>A collider run: beams and an energy, and no final state at all — the generator produces
    /// whatever those beams produce, in the proportions it computes. TreeLevel then counts, among that
    /// mixture, the events that look like the process it drew, which is how a cross section is measured
    /// rather than calculated.</summary>
    public bool IsCollider => HardProcess is MCProcess p && p.Beams.Length == 2 && p.FinalState.Length == 0;

    public int ProtocolVersion { get; set; } = MCEngineProtocol.Version;
    public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonPropertyName("generator")]
    public Generator UseGenerator { get; set; }
    public string Process { get; set; } = "";
    public int Events { get; set; }
    public int Seed { get; set; }
    public bool Shower { get; set; } = true;
    public bool Hadronisation { get; set; } = true;
    public bool MultipleInteractions { get; set; }
    public bool Decays { get; set; } = true;
    public string? Tune { get; set; }
    public string? ExtraSettings { get; set; }
    public MCProcess? HardProcess { get; set; }
    public string Input { get; set; } = MCEngineProtocol.InputFileName;
    public string Output { get; set; } = MCEngineProtocol.OutputFileName;
}

/// <summary>A hard process described so that a generator can compute it by itself.</summary>
public sealed class MCProcess
{
    public int[] Beams { get; set; } = Array.Empty<int>();
    public double[] BeamEnergies { get; set; } = Array.Empty<double>();
    public int[] FinalState { get; set; } = Array.Empty<int>();
    public Dictionary<string, int> CouplingOrders { get; set; } = new(StringComparer.Ordinal);
    public double? MinimumPT { get; set; }
    public string Model { get; set; } = "SM";

    [JsonIgnore]
    public double CentreOfMassEnergy => BeamEnergies.Sum();
}

/// <summary>How far the job has got; the engine rewrites it as it runs.</summary>
public sealed class MCStatus
{
    public enum State { Queued, Running, Finished, Failed, Cancelled }

    [JsonPropertyName("state")]
    public State JobState { get; set; }
    public string JobID { get; set; } = "";
    public double? Progress { get; set; }
    public int EventsWritten { get; set; }
    public double? CrossSection { get; set; }
    public double? CrossSectionError { get; set; }
    public string? Message { get; set; }
    public string? GeneratorVersion { get; set; }
    public double? Seconds { get; set; }
    public int? Number { get; set; }
    public DateTimeOffset? Started { get; set; }
    public DateTimeOffset? Finished { get; set; }

    public MCStatus(State state, string jobID) { JobState = state; JobID = jobID; }

    [JsonConstructor]
    public MCStatus() { }

    public MCStatus Clone() => (MCStatus)MemberwiseClone();
}

/// <summary>What the engine can do, published in its support folder and printed by <c>treelevel-mc capabilities</c>.</summary>
public sealed class MCCapabilities
{
    public int ProtocolVersion { get; set; } = MCEngineProtocol.Version;
    public string EngineVersion { get; set; } = "";
    public List<MCJob.Generator> Generators { get; set; } = new();
    public Dictionary<string, string> Versions { get; set; } = new(StringComparer.Ordinal);
}

/// <summary>Reads and writes a job folder: TreeLevel fills it, the engine consumes it and writes back.</summary>
public sealed class MCJobFolder
{
    public string Path { get; }
    public MCJobFolder(string path) { Path = System.IO.Path.GetFullPath(path); }

    public string JobPath => System.IO.Path.Combine(Path, MCEngineProtocol.JobFileName);
    public string StatusPath => System.IO.Path.Combine(Path, MCEngineProtocol.StatusFileName);
    public string LogPath => System.IO.Path.Combine(Path, MCEngineProtocol.LogFileName);
    public string InputPath(MCJob job) => System.IO.Path.Combine(Path, job.Input);
    public string OutputPath(MCJob job) => System.IO.Path.Combine(Path, job.Output);

    public MCJob ReadJob() => JsonSerializer.Deserialize<MCJob>(File.ReadAllText(JobPath), MCEngineProtocol.JsonOptions)
        ?? throw new InvalidOperationException("unreadable job file");

    public void WriteStatus(MCStatus status)
        => File.WriteAllText(StatusPath, JsonSerializer.Serialize(status, MCEngineProtocol.JsonOptions), MCEngineProtocol.Utf8);

    public MCStatus? ReadStatus()
    {
        try { return File.Exists(StatusPath) ? JsonSerializer.Deserialize<MCStatus>(File.ReadAllText(StatusPath), MCEngineProtocol.JsonOptions) : null; }
        catch (Exception) { return null; }
    }
}
