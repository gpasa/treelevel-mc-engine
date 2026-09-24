using System.Diagnostics;

namespace TreeLevel.MC;

/// <summary>Where the generators are, and which ones are usable. Three places are looked at, in order: a
/// module installed beside the engine (what the release archive carries), the usual install folders, then the
/// PATH. Herwig and Sherpa have no Windows build at all: on Windows they are reached through the container
/// image, or failing that through WSL, and this same class — running inside that image — finds them sitting
/// in its own prefix.</summary>
public static class Installation
{
    /// <summary>%LocalAppData%\TreeLevel MC Engine — modules, job numbers and the published capabilities.</summary>
    public static string SupportDirectory
    {
        get
        {
            // Create, not None: on Unix the default only answers when the folder already exists, and a lean
            // image has no ~/.local/share. The empty string it returned then made a relative path, so the
            // support folder was created wherever the engine happened to stand — inside the user's own job.
            //
            // And a fallback, because a container told to run under the caller's own user id — which is how
            // a Linux user keeps ownership of what comes out — has no writable home at all. What lives here
            // is a counter and a copy of the capabilities: worth a second choice, not worth stopping for.
            foreach (var racine in new[] { Local(), Path.GetTempPath() })
            {
                if (string.IsNullOrEmpty(racine)) continue;
                try
                {
                    var dir = Path.Combine(racine, MCEngineProtocol.SupportFolderName);
                    Directory.CreateDirectory(dir);
                    return dir;
                }
                catch (Exception) { }
            }
            return Path.GetTempPath();
        }
    }

    /// <summary>%LocalAppData% on Windows, ~/.local/share on Linux — or nothing at all when there is no home
    /// to speak of, which is not an error worth an exception here.</summary>
    static string Local()
    {
        try { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create); }
        catch (Exception) { return ""; }
    }

    public static string ModulesDirectory => Path.Combine(SupportDirectory, "Modules");

    static string EngineDirectory => AppContext.BaseDirectory;

    /// <summary>First match among: beside the engine, the module folder, the usual install folders, the PATH.</summary>
    static string? Find(string executable, params string[] extraFolders)
    {
        var candidates = new List<string> { Path.Combine(EngineDirectory, executable) };
        candidates.AddRange(extraFolders.Select(f => Path.Combine(f, executable)));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (dir.Length > 0) candidates.Add(Path.Combine(dir, executable));
        foreach (var c in candidates)
        {
            try { if (File.Exists(c)) return Path.GetFullPath(c); }
            catch (Exception) { }
        }
        return null;
    }

    /// <summary>True when the engine is not the Windows one: inside the container image it runs the
    /// generators itself, with no WSL and no Docker in between.</summary>
    public static bool Native => !OperatingSystem.IsWindows();

    /// <summary>The name a program carries on this system: Windows wants the extension, Linux does not.</summary>
    static string Exe(string name) => OperatingSystem.IsWindows() ? name + ".exe" : name;

    /// <summary>The Pythia driver: our own small program, built against the Pythia library. The release
    /// archive carries it under <c>Modules\pythia8</c> beside the engine, so that unpacking one folder is the
    /// whole installation; a module built by hand lands in the support folder instead.</summary>
    public static string? PythiaDriver => Find(Exe("treelevel-pythia"),
        Path.Combine(EngineDirectory, "Modules", "pythia8"),
        Path.Combine(EngineDirectory, "Modules", "pythia8", "bin"),
        Path.Combine(ModulesDirectory, "pythia8"),
        Path.Combine(ModulesDirectory, "pythia8", "bin"));

    /// <summary>The Pythia driver, but only when it answers. A file that exists is not a program that runs:
    /// a module left behind by a half-finished install, or one whose Visual C++ runtime went missing, would
    /// otherwise be preferred to a container that works. This is the same question `capabilities` asks, and
    /// the two must not answer differently.</summary>
    public static string? WorkingPythiaDriver
        => PythiaDriver is string driver && VersionOf(driver) != null ? driver : null;

    /// <summary>Pythia's xmldoc folder, which the driver needs; passed through PYTHIA8DATA.</summary>
    public static string? PythiaData
    {
        get
        {
            if (Environment.GetEnvironmentVariable("PYTHIA8DATA") is string set && Directory.Exists(set)) return set;
            var roots = new List<string>();
            if (PythiaDriver is string driver && Path.GetDirectoryName(driver) is string dir)
            {
                roots.Add(dir);
                if (Path.GetDirectoryName(dir) is string parent) roots.Add(parent);
            }
            roots.Add(Path.Combine(ModulesDirectory, "pythia8"));
            foreach (var root in roots)
                foreach (var rel in new[] { "xmldoc", Path.Combine("share", "Pythia8", "xmldoc"), Path.Combine("..", "share", "Pythia8", "xmldoc") })
                {
                    var path = Path.GetFullPath(Path.Combine(root, rel));
                    if (Directory.Exists(path)) return path;
                }
            return null;
        }
    }

    /// <summary>WHIZARD, which computes its own matrix elements. It exists only where a shell can reach it —
    /// in the image, or in a WSL distribution.</summary>
    public static string? Whizard => Find(Exe("whizard"),
        Path.Combine(ModulesDirectory, "whizard3", "bin"),
        "/opt/treelevel-mc/bin");

    /// <summary>CalcHEP's tree, not a program: its scripts carry the absolute path of the place they were
    /// built in, so the folder is what matters.</summary>
    public static string? Calchep
    {
        get
        {
            var candidates = new[]
            {
                Path.Combine(ModulesDirectory, "calchep3"),
                "/opt/treelevel-mc/calchep",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "calchep"),
            };
            foreach (var c in candidates)
            {
                try { if (File.Exists(Path.Combine(c, "calchep_batch"))) return Path.GetFullPath(c); }
                catch (Exception) { }
            }
            return null;
        }
    }

    /// <summary>CalcHEP answers no --version; it carries its own in a header.</summary>
    public static string? CalchepVersion(string root)
    {
        try
        {
            var header = File.ReadAllText(Path.Combine(root, "include", "version.h"));
            var quoted = header.Split('"');
            return quoted.Length > 1 ? "CalcHEP " + quoted[1] : null;
        }
        catch (Exception) { return null; }
    }

    // Herwig and Sherpa: through a shell — our own on Linux, a WSL distribution's on Windows

    /// <summary>The shell the generators are run through: bash here when the engine is the Linux one, and on
    /// Windows the bash of a WSL distribution, since neither generator has a Windows build.</summary>
    public static string? Shell
    {
        get
        {
            if (Native) return File.Exists("/bin/bash") ? "/bin/bash" : null;
            var wsl = Find("wsl.exe");
            if (wsl == null) return null;
            // `wsl -l -q` prints nothing (and fails) when no distribution is installed.
            var (code, output) = Run(wsl, new[] { "-l", "-q" }, unicode: true);
            return code == 0 && output.Trim().Length > 0 ? wsl : null;
        }
    }

    /// <summary>How that shell is asked to run a command — a login shell either way, so that the PATH is the
    /// one the generators' installation set.</summary>
    public static string[] ShellArguments(string command)
        => Native ? new[] { "-lc", command } : new[] { "-e", "bash", "-lc", command };

    /// <summary>Runs a command through that shell and waits for it.</summary>
    public static (int Code, string Output) InShell(string command)
    {
        if (Shell is not string shell) return (127, "");
        return Run(shell, ShellArguments(command));
    }

    /// <summary>The path the generators see for one of ours: the very same one when they run beside us, and
    /// the one <c>wslpath</c> gives when they run inside a distribution.</summary>
    public static string? ShellPath(string path)
    {
        if (Native) return path;
        var (code, output) = InShell($"wslpath -a '{path.Replace("'", "'\\''")}'");
        var line = output.Trim();
        return code == 0 && line.Length > 0 ? line : null;
    }

    // Herwig and Sherpa without WSL: the container image, which carries them ready to run

    /// <summary>Where the image lives, without its tag.</summary>
    public const string Repository = "ghcr.io/gpasa/treelevel-tools";

    /// <summary>The image that carries the generators, as it should be named when telling someone to fetch
    /// it. TREELEVEL_MC_IMAGE overrides it, for a local build or a mirror.</summary>
    public static string Image(string engineVersion)
        => Environment.GetEnvironmentVariable("TREELEVEL_MC_IMAGE") is string set && set.Trim().Length > 0
            ? set.Trim() : Repository + ":" + engineVersion;

    /// <summary>Docker, but only when its daemon answers: Docker Desktop installs the client long before the
    /// engine can run, and on a machine without virtualisation it never will.</summary>
    public static string? Docker
    {
        get
        {
            var docker = Find(Exe("docker"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                             "Docker", "Docker", "resources", "bin"));
            if (docker == null) return null;
            var (code, output) = Run(docker, new[] { "version", "--format", "{{.Server.Version}}" });
            return code == 0 && output.Trim().Length > 0 ? docker : null;
        }
    }

    /// <summary>Whether the image is already on the machine. Nothing is ever pulled behind the user's back:
    /// TreeLevel offers the download, which is a visible act with a size attached to it.</summary>
    public static bool ImageIsPresent(string docker, string image)
        => Run(docker, new[] { "image", "inspect", image }).Code == 0;

    /// <summary>Docker and the image together, when both are there: this is how Herwig and Sherpa run on
    /// Windows, and it is preferred over WSL when the two are available.
    ///
    /// The engine's own version first, then <c>latest</c>. The two numbers drift apart — the engine is
    /// released more often than an image that takes two hours to build — and a tag that does not exist would
    /// look exactly like Docker being absent, which is a hard bug report to read.</summary>
    public static (string Docker, string Image)? Container(string engineVersion)
    {
        if (Native || Docker is not string docker) return null;
        if (Environment.GetEnvironmentVariable("TREELEVEL_MC_IMAGE") is string set && set.Trim().Length > 0)
            return ImageIsPresent(docker, set.Trim()) ? (docker, set.Trim()) : null;
        foreach (var image in new[] { Repository + ":" + engineVersion, Repository + ":latest" })
            if (ImageIsPresent(docker, image)) return (docker, image);
        return null;
    }

    /// <summary>What the engine inside the image reports, asked for by running it.</summary>
    static MCCapabilities? ImageCapabilities(string docker, string image)
    {
        var (code, output) = Run(docker, new[] { "run", "--rm", image, "capabilities" });
        if (code != 0) return null;
        try { return System.Text.Json.JsonSerializer.Deserialize<MCCapabilities>(output, MCEngineProtocol.JsonOptions); }
        catch (Exception) { return null; }
    }

    static (int Code, string Output) Run(string exe, string[] arguments, bool unicode = false)
    {
        try
        {
            var info = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            if (unicode) info.StandardOutputEncoding = System.Text.Encoding.Unicode;
            foreach (var a in arguments) info.ArgumentList.Add(a);
            using var p = Process.Start(info);
            if (p == null) return (127, "");
            string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            if (!p.WaitForExit(20000)) { try { p.Kill(true); } catch (Exception) { } return (124, output); }
            return (p.ExitCode, output);
        }
        catch (Exception) { return (127, ""); }
    }

    /// <summary>Where a program was found, when it is not where we put our own — the module folders, or the
    /// prefix inside the image. A version number that surprises has no visible explanation otherwise: the
    /// engine looks in the PATH too, and what it finds there is somebody else's build.</summary>
    static string Origin(string exe)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(exe)) ?? "";
        foreach (var notre in new[] { ModulesDirectory, Path.Combine(EngineDirectory, "Modules"), "/opt/treelevel-mc" })
            if (dir.StartsWith(notre, StringComparison.OrdinalIgnoreCase)) return "";
        return $" ({dir})";
    }

    /// <summary>The first version number in what a program answers: « Herwig 7.3.0 » gives 7, « Sherpa
    /// version 3.0.5 (Erebus) » gives 3. A generator of the wrong generation understands nothing of what the
    /// engine writes — the YAML meant for Sherpa 3 is meaningless to a Sherpa 2 — and the refusal would come
    /// in the middle of a job, with a message nobody can read.</summary>
    static int? MajorVersion(string text)
    {
        var m = System.Text.RegularExpressions.Regex.Match(text, @"(?<![\d.])(\d+)\.\d+");
        return m.Success && int.TryParse(m.Groups[1].Value, out int v) ? v : null;
    }

    /// <summary>Version string of a program, or null when it is missing or broken.</summary>
    static string? VersionOf(string exe, string argument = "--version")
    {
        var (code, output) = Run(exe, new[] { argument });
        var line = output.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim();
        return code == 0 && !string.IsNullOrEmpty(line) ? line : null;
    }

    static string? ShellVersionOf(string command)
    {
        var (code, output) = InShell(command);
        var line = output.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim();
        return code == 0 && !string.IsNullOrEmpty(line) ? line : null;
    }

    /// <summary>The next job number, kept in the support folder so that a number is never reused.</summary>
    public static int NextJobNumber()
    {
        var path = Path.Combine(SupportDirectory, "counter.txt");
        int n = 1;
        try { if (File.Exists(path) && int.TryParse(File.ReadAllText(path).Trim(), out int read)) n = read + 1; }
        catch (Exception) { }
        try { File.WriteAllText(path, n.ToString(System.Globalization.CultureInfo.InvariantCulture), MCEngineProtocol.Utf8); }
        catch (Exception) { }
        return n;
    }

    public static MCCapabilities Capabilities(string engineVersion)
    {
        var caps = new MCCapabilities { EngineVersion = engineVersion, Generators = { MCJob.Generator.Passthrough } };
        if (PythiaDriver is string driver && VersionOf(driver) is string pythia)
        {
            caps.Generators.Add(MCJob.Generator.Pythia8);
            caps.Versions[MCJob.RawValue(MCJob.Generator.Pythia8)] = "Pythia " + pythia + Origin(driver);
        }
        // The image first: on Windows it is the supported way to reach Herwig and Sherpa, and it answers for
        // itself. Nothing is downloaded here — an image that is not on the machine simply offers nothing.
        if (!Native && Docker is string docker && ImageIsPresent(docker, Image(engineVersion))
            && ImageCapabilities(docker, Image(engineVersion)) is MCCapabilities image)
        {
            foreach (var generator in image.Generators)
            {
                if (generator == MCJob.Generator.Passthrough || caps.Generators.Contains(generator)) continue;
                caps.Generators.Add(generator);
                string key = MCJob.RawValue(generator);
                caps.Versions[key] = (image.Versions.TryGetValue(key, out var v) ? v : MCJob.Label(generator)) + " (Docker)";
            }
        }
        if (Shell != null)
        {
            // A broken installation (a missing library after a distribution upgrade, say) must not be offered.
            string where = Native ? "" : " (WSL)";
            // The major version, not just the name: a Sherpa 2 answers to « Sherpa » and reads none of the
            // YAML the engine writes for a Sherpa 3.
            if (!caps.Generators.Contains(MCJob.Generator.Herwig7)
                && ShellVersionOf("Herwig --version 2>/dev/null") is string herwig
                && herwig.ToLowerInvariant().Contains("herwig") && MajorVersion(herwig) == 7)
            {
                caps.Generators.Add(MCJob.Generator.Herwig7);
                caps.Versions[MCJob.RawValue(MCJob.Generator.Herwig7)] = herwig + where;
            }
            if (!caps.Generators.Contains(MCJob.Generator.Sherpa3)
                && ShellVersionOf("Sherpa --version 2>/dev/null | head -1") is string sherpa
                && sherpa.ToLowerInvariant().Contains("sherpa") && MajorVersion(sherpa) == 3)
            {
                caps.Generators.Add(MCJob.Generator.Sherpa3);
                caps.Versions[MCJob.RawValue(MCJob.Generator.Sherpa3)] = sherpa + where;
            }
        }
        // WHIZARD and CalcHEP compute their own matrix elements, and both compile code as they run: they
        // exist where the engine itself runs on Linux, not through a shell of someone else's.
        if (Native)
        {
            if (Whizard is string whizard && VersionOf(whizard) is string w
                && w.ToLowerInvariant().Contains("whizard") && MajorVersion(w) == 3)
            {
                caps.Generators.Add(MCJob.Generator.Whizard3);
                caps.Versions[MCJob.RawValue(MCJob.Generator.Whizard3)] = w + Origin(whizard);
            }
            if (Calchep is string calchep && CalchepVersion(calchep) is string c)
            {
                caps.Generators.Add(MCJob.Generator.CalcHep3);
                caps.Versions[MCJob.RawValue(MCJob.Generator.CalcHep3)] = c + Origin(Path.Combine(calchep, "calchep_batch"));
            }
        }
        return caps;
    }

    /// <summary>Writes the capabilities where TreeLevel can read them without launching anything.</summary>
    public static void PublishCapabilities(string engineVersion)
    {
        try
        {
            var path = Path.Combine(SupportDirectory, MCEngineProtocol.CapabilitiesFileName);
            File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(Capabilities(engineVersion), MCEngineProtocol.JsonOptions), MCEngineProtocol.Utf8);
        }
        catch (Exception) { }
    }
}
