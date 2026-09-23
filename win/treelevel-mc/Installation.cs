using System.Diagnostics;

namespace TreeLevel.MC;

/// <summary>Where the generators are on Windows, and which ones are usable. Three places are looked at, in
/// order: a module installed beside the engine (what the release archive carries), the usual install folders,
/// then the PATH. Herwig and Sherpa have no native Windows build; they are looked for inside WSL, which is
/// how they run here.</summary>
public static class Installation
{
    /// <summary>%LocalAppData%\TreeLevel MC Engine — modules, job numbers and the published capabilities.</summary>
    public static string SupportDirectory
    {
        get
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), MCEngineProtocol.SupportFolderName);
            Directory.CreateDirectory(dir);
            return dir;
        }
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

    /// <summary>The Pythia driver: our own small program, built against the Pythia library.</summary>
    public static string? PythiaDriver => Find("treelevel-pythia.exe",
        Path.Combine(ModulesDirectory, "pythia8"),
        Path.Combine(ModulesDirectory, "pythia8", "bin"));

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

    // Herwig and Sherpa through WSL

    /// <summary>WSL, when a distribution is installed. Herwig 7 and Sherpa 3 have no Windows build: they are
    /// built once inside a distribution and driven from here.</summary>
    public static string? Wsl
    {
        get
        {
            var wsl = Find("wsl.exe");
            if (wsl == null) return null;
            // `wsl -l -q` prints nothing (and fails) when no distribution is installed.
            var (code, output) = Run(wsl, new[] { "-l", "-q" }, unicode: true);
            return code == 0 && output.Trim().Length > 0 ? wsl : null;
        }
    }

    /// <summary>Runs a command inside WSL as a login shell, so that the module's PATH is the one its install set.</summary>
    public static (int Code, string Output) InWsl(string command)
    {
        if (Wsl is not string wsl) return (127, "");
        return Run(wsl, new[] { "-e", "bash", "-lc", command });
    }

    /// <summary>The Linux path a Windows path stands for inside WSL (<c>wslpath</c>).</summary>
    public static string? WslPath(string windowsPath)
    {
        var (code, output) = InWsl($"wslpath -a '{windowsPath.Replace("'", "'\\''")}'");
        var line = output.Trim();
        return code == 0 && line.Length > 0 ? line : null;
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

    /// <summary>Version string of a program, or null when it is missing or broken.</summary>
    static string? VersionOf(string exe, string argument = "--version")
    {
        var (code, output) = Run(exe, new[] { argument });
        var line = output.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim();
        return code == 0 && !string.IsNullOrEmpty(line) ? line : null;
    }

    static string? WslVersionOf(string command)
    {
        var (code, output) = InWsl(command);
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
            caps.Versions[MCJob.RawValue(MCJob.Generator.Pythia8)] = "Pythia " + pythia;
        }
        if (Wsl != null)
        {
            // A broken installation (a missing library after a distribution upgrade, say) must not be offered.
            if (WslVersionOf("Herwig --version 2>/dev/null") is string herwig && herwig.ToLowerInvariant().Contains("herwig"))
            {
                caps.Generators.Add(MCJob.Generator.Herwig7);
                caps.Versions[MCJob.RawValue(MCJob.Generator.Herwig7)] = herwig + " (WSL)";
            }
            if (WslVersionOf("Sherpa --version 2>/dev/null | head -1") is string sherpa && sherpa.ToLowerInvariant().Contains("sherpa"))
            {
                caps.Generators.Add(MCJob.Generator.Sherpa3);
                caps.Versions[MCJob.RawValue(MCJob.Generator.Sherpa3)] = sherpa + " (WSL)";
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
