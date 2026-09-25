using System.Globalization;

namespace TreeLevel.MC;

/// <summary>The engine left running on a folder of jobs, for a workstation a group shares: one person drops a
/// job folder in, the engine takes it, runs it and writes the answers back where they were expected. Nothing
/// listens on a port and nothing leaves the machine — a job is still a folder, as everywhere else here.
///
/// In the container it needs no special arrangement, the entry point being the engine itself:
///   docker run -d -v /srv/mcjobs:/jobs ghcr.io/gpasa/treelevel-tools:0.3.0 serve /jobs
/// </summary>
public static class Serve
{
    /// <summary>A folder is waiting for us when it holds a job and nobody has answered it yet.</summary>
    static bool IsWaiting(string folder)
        => File.Exists(Path.Combine(folder, MCEngineProtocol.JobFileName))
        && !File.Exists(Path.Combine(folder, MCEngineProtocol.StatusFileName));

    /// <summary>Claims a job by creating its status file, and says whether the claim succeeded. Creating a
    /// file that must not already exist is atomic, so two engines watching the same folder cannot both take
    /// the same job — the loser is told the file is there and moves on.</summary>
    static bool Claim(MCJobFolder folder, MCJob job, int number)
    {
        try
        {
            using (new FileStream(folder.StatusPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        folder.WriteStatus(new MCStatus(MCStatus.State.Queued, job.Id) { Number = number, Message = "en attente" });
        return true;
    }

    static void Say(string message)
        => Console.WriteLine(DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message);

    public static int Run(string root, string engineVersion, double seconds)
    {
        if (!Directory.Exists(root)) { Console.Error.WriteLine($"treelevel-tools: no folder {root}"); return 1; }
        var delay = TimeSpan.FromSeconds(Math.Clamp(seconds, 0.2, 3600));

        // Ctrl-C finishes the job in hand rather than abandoning it half written.
        bool stopping = false;
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            if (stopping) return;
            stopping = true;
            Say("arrêt demandé — le travail en cours va jusqu'au bout");
        };

        Installation.PublishCapabilities(engineVersion);
        var caps = Installation.Capabilities(engineVersion);
        Say($"à l'écoute de {Path.GetFullPath(root)} — {string.Join(", ", caps.Generators.Select(MCJob.Label))}");

        while (!stopping)
        {
            string[] waiting;
            try { waiting = Directory.GetDirectories(root).Where(IsWaiting).OrderBy(Directory.GetCreationTimeUtc).ToArray(); }
            catch (Exception e) { Say("dossier illisible : " + e.Message); Thread.Sleep(delay); continue; }

            if (waiting.Length == 0) { Thread.Sleep(delay); continue; }

            foreach (var path in waiting)
            {
                if (stopping) break;
                var folder = new MCJobFolder(path);
                MCJob job;
                // A folder still being filled has no readable job yet; it will be there on the next pass.
                try { job = folder.ReadJob(); }
                catch (Exception) { continue; }
                // Nor is a job ready while the events it is supposed to shower are still being written: the
                // folder is left alone rather than claimed and failed, and will be taken when the file lands.
                if (MCJob.ReadsLesHouches(job.UseGenerator) && !File.Exists(folder.InputPath(job))) continue;

                int number = Installation.NextJobNumber();
                if (!Claim(folder, job, number)) continue;

                Say($"n° {number}  {job.Id}  {MCJob.Label(job.UseGenerator)}, {job.Events} événements");
                try
                {
                    new Runner(folder, job, engineVersion, number).Run();
                    var status = folder.ReadStatus();
                    Say(status?.JobState == MCStatus.State.Finished
                        ? $"n° {number}  terminé, {status.EventsWritten} événements"
                        + (status.Seconds is double s ? $", {s.ToString("0.0", CultureInfo.InvariantCulture)} s" : "")
                        : $"n° {number}  échoué : {status?.Message ?? "raison inconnue"}");
                }
                catch (Exception e)
                {
                    // A job that blows up must not take the engine with it.
                    Say($"n° {number}  échoué : {e.Message}");
                    try { folder.WriteStatus(new MCStatus(MCStatus.State.Failed, job.Id) { Number = number, Message = e.Message }); }
                    catch (Exception) { }
                }
            }
        }

        Say("arrêté");
        return 0;
    }
}
