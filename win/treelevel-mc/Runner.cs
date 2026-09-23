using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace TreeLevel.MC;

/// <summary>Runs one job: prepares the generator's configuration, starts it, follows its output to keep
/// status.json current, and checks that events came out.</summary>
public sealed class Runner
{
    readonly MCJobFolder folder;
    readonly MCJob job;
    readonly string engineVersion;
    readonly int number;

    public Runner(MCJobFolder folder, MCJob job, string engineVersion, int number)
    {
        this.folder = folder; this.job = job; this.engineVersion = engineVersion; this.number = number;
    }

    void Publish(MCStatus status)
    {
        try { folder.WriteStatus(status); } catch (Exception) { }
    }

    public bool Run()
    {
        var start = DateTimeOffset.Now;
        var status = new MCStatus(MCStatus.State.Running, job.Id) { Number = number, Started = start, Message = "préparation" };
        Publish(status);
        // A generator that computes its own matrix elements is given a process, not events.
        if (MCJob.ReadsLesHouches(job.UseGenerator) && !File.Exists(folder.InputPath(job)))
            return Failed($"the job has no input file ({job.Input})", start);
        try
        {
            return job.UseGenerator switch
            {
                MCJob.Generator.Passthrough => Passthrough(start),
                MCJob.Generator.Pythia8 => Pythia(start),
                MCJob.Generator.Herwig7 => Herwig(start),
                MCJob.Generator.Sherpa3 => Sherpa(start),
                _ => Failed($"{MCJob.Label(job.UseGenerator)} is not available on Windows yet", start),
            };
        }
        catch (Exception e) { return Failed(e.Message, start); }
    }

    // Backends

    /// <summary>No shower: the parton-level events are converted to HepMC3 as they are. Useful to check the
    /// plumbing and to compare a showered sample with the hard process it came from.</summary>
    bool Passthrough(DateTimeOffset start)
    {
        var events = LesHouchesLite.Read(folder.InputPath(job));
        LesHouchesLite.WriteHepMC(events, folder.OutputPath(job), events.CrossSection);
        Publish(new MCStatus(MCStatus.State.Finished, job.Id)
        {
            Number = number, Started = start, Finished = DateTimeOffset.Now,
            EventsWritten = events.Events.Count, CrossSection = events.CrossSection,
            GeneratorVersion = $"TreeLevel MC Engine {engineVersion} (sans gerbe)",
            Progress = 1, Seconds = (DateTimeOffset.Now - start).TotalSeconds,
        });
        return true;
    }

    /// <summary>Pythia 8 through our small driver, which reads the LHE file and writes HepMC3.</summary>
    bool Pythia(DateTimeOffset start)
    {
        if (Installation.PythiaDriver is not string driver) return Failed("the Pythia 8 module is not installed", start);
        // The generator runs with the job folder as its working directory and is given relative names: Pythia
        // reads `Beams:LHEF` as a single word, so a path with spaces would be cut short.
        var settings = new StringBuilder();
        settings.Append("Beams:frameType = 4\n");
        settings.Append($"Beams:LHEF = {job.Input}\n");
        settings.Append($"Main:numberOfEvents = {job.Events}\n");
        settings.Append("Random:setSeed = on\n");
        settings.Append($"Random:seed = {job.Seed % 900_000_000}\n");
        settings.Append($"PartonLevel:ISR = {(job.Shower ? "on" : "off")}\n");
        settings.Append($"PartonLevel:FSR = {(job.Shower ? "on" : "off")}\n");
        settings.Append($"PartonLevel:MPI = {(job.MultipleInteractions ? "on" : "off")}\n");
        settings.Append($"HadronLevel:all = {(job.Hadronisation ? "on" : "off")}\n");
        settings.Append($"HadronLevel:Decay = {(job.Decays ? "on" : "off")}\n");
        settings.Append("Print:quiet = on\n");
        settings.Append("Next:numberShowEvent = 0");
        if (!string.IsNullOrEmpty(job.Tune)) settings.Append($"\nTune:pp = {job.Tune}");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) settings.Append("\n" + job.ExtraSettings);
        File.WriteAllText(Path.Combine(folder.Path, "pythia.cmnd"), settings.ToString(), MCEngineProtocol.Utf8);

        var environment = new Dictionary<string, string>();
        if (Installation.PythiaData is string data) environment["PYTHIA8DATA"] = data;
        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("pythia8", out var v) ? v : "Pythia 8";
        return RunProcess(driver, new[] { "--config", "pythia.cmnd", "--out", job.Output }, start, version, environment: environment);
    }

    /// <summary>Herwig 7 inside WSL: written as a <c>.in</c> file, then <c>Herwig read</c> and <c>Herwig run</c>.
    /// The job folder is reached through its <c>/mnt/…</c> path, so both sides see the same files.</summary>
    bool Herwig(DateTimeOffset start)
    {
        if (Installation.Wsl == null) return Failed("Herwig 7 runs inside WSL, which is not installed", start);
        if (Installation.WslPath(folder.Path) is not string inside)
            return Failed("the job folder is not reachable from WSL", start);
        const string name = "job";
        var input = new StringBuilder();
        input.Append("read snippets/EPCollider.in\n");
        input.Append("cd /Herwig/EventHandlers\n");
        input.Append("library LesHouches.so\n");
        input.Append("create ThePEG::LesHouchesFileReader LesHouchesReader\n");
        input.Append($"set LesHouchesReader:FileName {job.Input}\n");
        input.Append("set LesHouchesReader:CacheFileName cache.tmp\n");
        input.Append("set LesHouchesReader:MaxScan 5\n");
        input.Append("create ThePEG::Cuts NoCuts\n");
        input.Append("set LesHouchesReader:Cuts NoCuts\n");
        input.Append("create ThePEG::LesHouchesEventHandler LesHouchesHandler\n");
        input.Append("insert LesHouchesHandler:LesHouchesReaders 0 LesHouchesReader\n");
        input.Append("set LesHouchesHandler:PartonExtractor /Herwig/Partons/EEExtractor\n");
        input.Append($"set LesHouchesHandler:CascadeHandler {(job.Shower ? "/Herwig/Shower/ShowerHandler" : "NULL")}\n");
        input.Append($"set LesHouchesHandler:HadronizationHandler {(job.Hadronisation ? "/Herwig/Hadronization/ClusterHadHandler" : "NULL")}\n");
        input.Append($"set LesHouchesHandler:DecayHandler {(job.Decays ? "/Herwig/Decays/DecayHandler" : "NULL")}\n");
        input.Append("set LesHouchesHandler:WeightOption VarNegWeight\n");
        input.Append("cd /Herwig/Generators\n");
        input.Append("set EventGenerator:EventHandler /Herwig/EventHandlers/LesHouchesHandler\n");
        input.Append($"set EventGenerator:NumberOfEvents {job.Events}\n");
        input.Append($"set EventGenerator:RandomNumberGenerator:Seed {job.Seed % 900_000_000}\n");
        input.Append("set EventGenerator:PrintEvent 0\n");
        input.Append("set EventGenerator:MaxErrors 10000\n");
        input.Append("insert EventGenerator:AnalysisHandlers 0 /Herwig/Analysis/HepMCFile\n");
        input.Append($"set /Herwig/Analysis/HepMCFile:PrintEvent {job.Events}\n");
        input.Append("set /Herwig/Analysis/HepMCFile:Format GenEvent\n");
        input.Append("set /Herwig/Analysis/HepMCFile:Units GeV_mm\n");
        input.Append($"set /Herwig/Analysis/HepMCFile:Filename {job.Output}\n");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) input.Append(job.ExtraSettings + "\n");
        input.Append($"saverun {name} EventGenerator\n");
        // Unix line endings: ThePEG reads the file line by line and a trailing CR ends up in the values.
        File.WriteAllText(Path.Combine(folder.Path, name + ".in"), input.ToString().Replace("\r\n", "\n"), MCEngineProtocol.Utf8);

        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("herwig7", out var v) ? v : "Herwig 7";
        string quoted = Quote(inside);
        if (!RunInWsl($"cd {quoted} && Herwig read {name}.in", start, version, step: "lecture de la configuration", finishNow: false)) return false;
        return RunInWsl($"cd {quoted} && Herwig run {name}.run -N {job.Events}", start, version);
    }

    /// <summary>Sherpa 3 inside WSL: it has no Les Houches reader, so it is given the process itself, as a YAML
    /// run card. It computes the matrix element (Comix), showers, hadronises and writes the HepMC3 itself.</summary>
    bool Sherpa(DateTimeOffset start)
    {
        if (Installation.Wsl == null) return Failed("Sherpa 3 runs inside WSL, which is not installed", start);
        if (job.HardProcess is not MCProcess p || p.Beams.Length != 2 || p.BeamEnergies.Length != 2 || p.FinalState.Length == 0)
            return Failed("Sherpa computes the process itself and needs its description (beams, energies, final state)", start);
        if (Installation.WslPath(folder.Path) is not string inside)
            return Failed("the job folder is not reachable from WSL", start);
        string orders = p.CouplingOrders.Count == 0 ? ""
            : "\n    Order: {" + string.Join(", ", p.CouplingOrders.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => $"{kv.Key}: {kv.Value}")) + "}";
        string outgoing = string.Join(" ", p.FinalState);
        var card = new StringBuilder();
        card.Append($"BEAMS: [{p.Beams[0]}, {p.Beams[1]}]\n");
        card.Append($"BEAM_ENERGIES: [{N(p.BeamEnergies[0])}, {N(p.BeamEnergies[1])}]\n");
        card.Append($"EVENTS: {job.Events}\n");
        card.Append($"RANDOM_SEED: {job.Seed % 900_000_000}\n");
        card.Append("PROCESSES:\n");
        card.Append($"- {p.Beams[0]} {p.Beams[1]} -> {outgoing}:{orders}\n");
        card.Append($"SHOWER_GENERATOR: {(job.Shower ? "CSS" : "None")}\n");
        card.Append($"FRAGMENTATION: {(job.Hadronisation ? "Ahadic" : "None")}\n");
        card.Append($"MI_HANDLER: {(job.MultipleInteractions ? "Amisic" : "None")}\n");
        card.Append($"HARD_DECAYS: {{Enabled: {(job.Decays ? "true" : "false")}}}\n");
        card.Append($"EVENT_OUTPUT: HepMC3[{Path.GetFileNameWithoutExtension(job.Output)}]\n");
        if (p.MinimumPT is double pt) card.Append($"SELECTORS:\n- [PT, {p.FinalState[0]}, {N(pt)}, E_CMS]\n");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) card.Append(job.ExtraSettings + "\n");
        File.WriteAllText(Path.Combine(folder.Path, "Sherpa.yaml"), card.ToString().Replace("\r\n", "\n"), MCEngineProtocol.Utf8);

        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("sherpa3", out var v) ? v : "Sherpa 3";
        // Sherpa appends its own extension to EVENT_OUTPUT; the job expects events.hepmc.
        string quoted = Quote(inside);
        string stem = Path.GetFileNameWithoutExtension(job.Output);
        return RunInWsl($"cd {quoted} && Sherpa -f Sherpa.yaml && (test -f {stem}.hepmc || (test -f {stem}.hepmc3 && mv {stem}.hepmc3 {stem}.hepmc) || (test -f {stem}.hepmc.gz && gunzip -f {stem}.hepmc.gz)) ",
                        start, version);
    }

    static string N(double v) => v.ToString("G", CultureInfo.InvariantCulture);
    static string Quote(string path) => "'" + path.Replace("'", "'\\''") + "'";

    // Running a program and following it

    bool RunInWsl(string command, DateTimeOffset start, string name, string? step = null, bool finishNow = true)
        => RunProcess(Installation.Wsl!, new[] { "-e", "bash", "-lc", command }, start, name, step, finishNow, workingDirectory: folder.Path);

    bool RunProcess(string exe, string[] arguments, DateTimeOffset start, string name,
                    string? step = null, bool finishNow = true, string? workingDirectory = null,
                    IReadOnlyDictionary<string, string>? environment = null)
    {
        var info = new ProcessStartInfo(exe)
        {
            WorkingDirectory = workingDirectory ?? folder.Path,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in arguments) info.ArgumentList.Add(a);
        info.Environment["TREELEVEL_JOB"] = job.Id;
        if (environment != null) foreach (var (k, v) in environment) info.Environment[k] = v;

        var status = new MCStatus(MCStatus.State.Running, job.Id)
        {
            Number = number, Started = start, GeneratorVersion = name, Message = step ?? "génération",
        };
        Publish(status);

        using var log = new StreamWriter(folder.LogPath, append: true, MCEngineProtocol.Utf8);
        log.AutoFlush = true;
        var gate = new object();
        void OnLine(string? line)
        {
            if (line == null) return;
            lock (gate) log.WriteLine(line);
            if (EventCount(line) is not int n) return;
            var s = status.Clone();
            s.EventsWritten = n;
            s.Progress = job.Events > 0 ? Math.Min(1, (double)n / job.Events) : null;
            Publish(s);
        }
        using var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => OnLine(e.Data);
        process.ErrorDataReceived += (_, e) => OnLine(e.Data);
        if (!process.Start()) return Failed($"cannot start {exe}", start);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        process.WaitForExit();
        if (process.ExitCode != 0) return Failed($"{name} stopped with code {process.ExitCode} — see engine.log", start);
        if (!finishNow) return true;

        var (written, sigma, sigmaError) = Summary(folder.OutputPath(job));
        if (written <= 0) return Failed($"{name} wrote no event — see engine.log", start);
        Publish(new MCStatus(MCStatus.State.Finished, job.Id)
        {
            Number = number, Started = start, Finished = DateTimeOffset.Now, EventsWritten = written,
            GeneratorVersion = name, Progress = 1, Seconds = (DateTimeOffset.Now - start).TotalSeconds,
            CrossSection = sigma, CrossSectionError = sigmaError,
        });
        return true;
    }

    bool Failed(string message, DateTimeOffset start)
    {
        Publish(new MCStatus(MCStatus.State.Failed, job.Id)
        {
            Number = number, Started = start, Finished = DateTimeOffset.Now, Message = message,
            Seconds = (DateTimeOffset.Now - start).TotalSeconds,
        });
        Console.Error.WriteLine("treelevel-mc: " + message);
        return false;
    }

    /// <summary>"Pythia::next(): 1000 events have been generated" / "Herwig: 1000 events" / Sherpa's
    /// "XS = 16 pb ... Event 200 ( 0s elapsed / 0s left )", whose other numbers — a cross section, a date —
    /// must not be mistaken for a count, hence the explicit "Event &lt;n&gt;" first.</summary>
    public static int? EventCount(string line)
    {
        int k = line.IndexOf("Event ", StringComparison.Ordinal);
        if (k >= 0)
        {
            var digits = new string(line.Substring(k + 6).TakeWhile(char.IsDigit).ToArray());
            if (digits.Length > 0 && int.TryParse(digits, NumberStyles.Integer, CultureInfo.InvariantCulture, out int n)) return n;
        }
        if (!line.Contains("event", StringComparison.Ordinal)) return null;
        var numbers = line.Split(new[] { ' ', '\t', ':', ',', '(', ')' }, StringSplitOptions.RemoveEmptyEntries)
            .Where(s => s.All(char.IsDigit) && s.Length > 0)
            .Select(s => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : 0)
            .ToList();
        return numbers.Count > 0 ? numbers.Max() : null;
    }

    /// <summary>One pass over the HepMC3 file: the <c>E</c> lines are the events, and the cross section is
    /// whatever the last event says — <c>C sigma error</c> in the Asciiv3 format Herwig writes, or the
    /// <c>GenCrossSection</c> attribute other writers attach. The last one wins.</summary>
    static (int Events, double? CrossSection, double? Error) Summary(string path)
    {
        if (!File.Exists(path)) return (0, null, null);
        int events = 0;
        double? sigma = null, sigmaError = null;
        double D(string s) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : 0;
        foreach (var line in File.ReadLines(path))
        {
            if (line.StartsWith("E ", StringComparison.Ordinal)) events += 1;
            else if (line.StartsWith("C ", StringComparison.Ordinal))
            {
                var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (f.Length >= 2) sigma = D(f[1]);
                if (f.Length >= 3) sigmaError = D(f[2]);
            }
            else if (line.StartsWith("A 0 GenCrossSection", StringComparison.Ordinal))
            {
                var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (f.Length >= 4) sigma = D(f[3]);
                if (f.Length >= 5) sigmaError = D(f[4]);
            }
        }
        return (events, sigma, sigmaError);
    }
}
