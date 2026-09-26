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
        if (MCJob.ReadsLesHouches(job.UseGenerator) && !job.IsCollider && !File.Exists(folder.InputPath(job)))
            return Failed($"the job has no input file ({job.Input})", start);
        try
        {
            // A collider job handed to a generator that does not know the mode would not fail: it would compute
            // the exclusive process the final state names — which here is the signature to look for, not what to
            // produce — and the sample would come back entirely made of the drawn process. The measurement would
            // then hand back the number it was meant to measure: wrong, and convincing. So each generator either
            // knows the mode or says it does not.
            if (job.IsCollider && ColliderRefusal(job.UseGenerator, job.HardProcess!) is string no)
                return Failed(no, start);
            return job.UseGenerator switch
            {
                MCJob.Generator.Passthrough => Passthrough(start),
                MCJob.Generator.Pythia8 => Pythia(start),
                MCJob.Generator.Herwig7 => Herwig(start),
                MCJob.Generator.Sherpa3 => Sherpa(start),
                MCJob.Generator.Whizard3 => Whizard(start),
                MCJob.Generator.CalcHep3 => CalcHep(start),
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
            GeneratorVersion = $"TreeLevel Tools {engineVersion} (sans gerbe)",
            Progress = 1, Seconds = (DateTimeOffset.Now - start).TotalSeconds,
        });
        return true;
    }

    /// <summary>Pythia 8 through our small driver, which reads the LHE file and writes HepMC3.</summary>
    bool Pythia(DateTimeOffset start)
    {
        // The native module first — 6.5 MB that run where no virtualisation is to be had — and the container
        // behind it. The module must answer, not merely exist: a broken one would otherwise be preferred to
        // an image that works, and the job would fail for a reason nobody could guess.
        if (Installation.WorkingPythiaDriver is not string driver)
        {
            if (Installation.Container() is { } container) return InContainer(container, start);
            return Failed("the Pythia 8 module is not installed", start);
        }
        if (job.IsCollider && job.HardProcess is MCProcess hard)
        {
            if (ColliderObjection(hard) is string objection) return Failed(objection, start);
            var beamsAsThey = hard.Channels.Where(c => c != MCProcess.Channel.Photoproduction).ToArray();
            var photonFlux = hard.Channels.Where(c => c == MCProcess.Channel.Photoproduction).ToArray();
            if (beamsAsThey.Length > 0 && photonFlux.Length > 0)
            {
                if (!hard.MixConfigurations)
                    return Failed("photoproduction turns the lepton beam into the flux of photons it radiates, "
                                + "which leaves nothing to annihilate or exchange: Pythia accepts no event from "
                                + "the other families once it is on. Ask for the two configurations to be mixed, "
                                + "and both are run and put together in proportion to their cross sections",
                                  start);
                return PythiaMixed(driver, beamsAsThey, photonFlux, start);
            }
        }
        return PythiaOnce(driver, job.HardProcess?.Channels, job.Output, job.Events, job.Seed, start, true);
    }

    /// <summary>One pass of Pythia, over one set of channels, into one file.</summary>
    bool PythiaOnce(string driver, MCProcess.Channel[]? channels, string output, int events, int seed,
                    DateTimeOffset start, bool finishNow, string? step = null)
    {
        // The generator runs with the job folder as its working directory and is given relative names: Pythia
        // reads `Beams:LHEF` as a single word, so a path with spaces would be cut short.
        var settings = new StringBuilder();
        if (job.IsCollider) settings.Append(ColliderBeams(job.HardProcess!, channels));
        else
        {
            settings.Append("Beams:frameType = 4\n");
            settings.Append($"Beams:LHEF = {job.Input}\n");
        }
        settings.Append($"Main:numberOfEvents = {events}\n");
        settings.Append("Random:setSeed = on\n");
        settings.Append($"Random:seed = {seed % 900_000_000}\n");
        settings.Append($"PartonLevel:ISR = {(job.Shower ? "on" : "off")}\n");
        settings.Append($"PartonLevel:FSR = {(job.Shower ? "on" : "off")}\n");
        // The whole cross section is built out of the multiple interactions — its non-diffractive part is made
        // of them — so asking for it turns them on whatever the job says. Written here rather than beside the
        // channel that needs it, because this line comes later and would otherwise put them back off.
        bool wholeCrossSection = channels?.Contains(MCProcess.Channel.Soft) ?? false;
        settings.Append($"PartonLevel:MPI = {(job.MultipleInteractions || wholeCrossSection ? "on" : "off")}\n");
        settings.Append($"HadronLevel:all = {(job.Hadronisation ? "on" : "off")}\n");
        settings.Append($"HadronLevel:Decay = {(job.Decays ? "on" : "off")}\n");
        settings.Append("Print:quiet = on\n");
        settings.Append("Next:numberShowEvent = 0");
        if (!string.IsNullOrEmpty(job.Tune)) settings.Append($"\nTune:pp = {job.Tune}");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) settings.Append("\n" + job.ExtraSettings);
        string config = output == job.Output ? "pythia.cmnd"
                                             : "pythia." + Path.GetFileNameWithoutExtension(output) + ".cmnd";
        File.WriteAllText(Path.Combine(folder.Path, config), settings.ToString(), MCEngineProtocol.Utf8);

        var environment = new Dictionary<string, string>();
        if (Installation.PythiaData is string data) environment["PYTHIA8DATA"] = data;
        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("pythia8", out var v) ? v : "Pythia 8";
        return RunProcess(driver, new[] { "--config", config, "--out", output }, start, version,
                          step: step, finishNow: finishNow, environment: environment);
    }

    /// <summary>The two machine configurations, run one after the other and put together in proportion to their
    /// cross sections. A lepton beam either collides as a lepton or enters as the flux of photons it radiates;
    /// Pythia does one or the other, never both, so seeing both means running both.
    ///
    /// The events are kept, not reweighted: from each sample the share its cross section earns, so that what
    /// comes out is still a plain list of events in the proportions the machine makes them — which is the thing
    /// worth looking at. The whole cross section is their sum.</summary>
    bool PythiaMixed(string driver, MCProcess.Channel[] beamsAsThey, MCProcess.Channel[] photonFlux,
                     DateTimeOffset start)
    {
        const string fileA = "events.beams.hepmc", fileB = "events.photons.hepmc";
        if (!PythiaOnce(driver, beamsAsThey, fileA, job.Events, job.Seed, start, false, "faisceaux tels quels"))
            return false;
        if (!PythiaOnce(driver, photonFlux, fileB, job.Events, job.Seed + 1, start, false, "flux de photons"))
            return false;

        var (countA, sigmaA, errorA) = Summary(Path.Combine(folder.Path, fileA));
        var (countB, sigmaB, errorB) = Summary(Path.Combine(folder.Path, fileB));
        if (countA <= 0 || countB <= 0 || sigmaA is not double sA || sigmaB is not double sB || sA + sB <= 0)
            return Failed("one of the two configurations produced nothing — see engine.log", start);

        int written = Merge(Path.Combine(folder.Path, fileA), Path.Combine(folder.Path, fileB),
                            folder.OutputPath(job), job.Events, sA, sB, errorA ?? 0, errorB ?? 0,
                            job.HardProcess?.MixEqualShares ?? false);
        if (written <= 0) return Failed("the two samples could not be put together", start);
        foreach (var scratch in new[] { fileA, fileB })
            try { File.Delete(Path.Combine(folder.Path, scratch)); } catch (Exception) { }

        double error = Math.Sqrt((errorA ?? 0) * (errorA ?? 0) + (errorB ?? 0) * (errorB ?? 0));
        Publish(new MCStatus(MCStatus.State.Finished, job.Id)
        {
            Number = number, Started = start, Finished = DateTimeOffset.Now, EventsWritten = written,
            GeneratorVersion = Installation.Capabilities(engineVersion).Versions.TryGetValue("pythia8", out var v) ? v : "Pythia 8",
            Progress = 1, Seconds = (DateTimeOffset.Now - start).TotalSeconds,
            CrossSection = sA + sB, CrossSectionError = error,
        });
        return true;
    }

    /// <summary>Puts two HepMC3 samples together, keeping from each the share its cross section earns and taking
    /// them in turn so that the result reads as one sample rather than two stuck end to end.</summary>
    static int Merge(string a, string b, string @out, int wanted, double sigmaA, double sigmaB,
                     double errorA, double errorB, bool equalShares)
    {
        var (header, eventsA) = Split(a);
        var (_, eventsB) = Split(b);
        if (eventsA.Count == 0 || eventsB.Count == 0) return 0;
        double total = sigmaA + sigmaB;
        int fromA, fromB;
        if (equalShares)
        {
            // Half from each, whatever their cross sections: the rarer configuration becomes visible instead of
            // being a handful of events lost in the other. What the proportion loses in the counting it regains
            // in the weights, so every sum over the sample is still a cross section.
            fromA = Math.Min(wanted / 2, eventsA.Count);
            fromB = Math.Min(wanted - fromA, eventsB.Count);
        }
        else
        {
            fromA = Math.Clamp((int)Math.Round(wanted * sigmaA / total, MidpointRounding.AwayFromZero), 0, eventsA.Count);
            fromB = Math.Clamp(wanted - fromA, 0, eventsB.Count);
        }
        if (fromA + fromB == 0) return 0;
        // The weight an event carries so that the weights of each sample add up to its own cross section. In
        // proportion they come out equal, and the sample stays one where every event counts for one.
        double weightA = fromA > 0 ? sigmaA / fromA * (fromA + fromB) / total : 1;
        double weightB = fromB > 0 ? sigmaB / fromB * (fromA + fromB) / total : 1;

        string attribute = $"A 0 GenCrossSection {E(total)} {E(Math.Sqrt(errorA * errorA + errorB * errorB))} -1 -1";
        using var writer = new StreamWriter(@out, false, MCEngineProtocol.Utf8);
        foreach (var line in header) writer.WriteLine(line);
        int takenA = 0, takenB = 0, n = 0;
        while (takenA < fromA || takenB < fromB)
        {
            // Take from whichever sample is furthest behind the share it is owed: the two end up interleaved in
            // their true proportion instead of one following the other.
            bool takeA = takenA < fromA
                         && (takenB >= fromB || fromA == 0 || fromB == 0
                             || (double)takenA / fromA <= (double)takenB / fromB);
            double weight = takeA ? weightA : weightB;
            foreach (var line in takeA ? eventsA[takenA++] : eventsB[takenB++])
            {
                if (line.StartsWith("E ", StringComparison.Ordinal))
                {
                    var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (f.Length >= 4) { writer.WriteLine($"E {n} {f[2]} {f[3]}"); continue; }
                }
                if (line.StartsWith("W ", StringComparison.Ordinal)) { writer.WriteLine($"W {E(weight)}"); continue; }
                if (line.StartsWith("A 0 GenCrossSection", StringComparison.Ordinal)) { writer.WriteLine(attribute); continue; }
                writer.WriteLine(line);
            }
            n += 1;
        }
        writer.WriteLine("HepMC::Asciiv3-END_EVENT_LISTING");
        return n;
    }

    static string E(double x) => x.ToString("0.0000000000e+00", CultureInfo.InvariantCulture);

    /// <summary>A HepMC3 file cut into its header and one block per event.</summary>
    static (List<string> Header, List<List<string>> Events) Split(string path)
    {
        var header = new List<string>();
        var events = new List<List<string>>();
        List<string>? current = null;
        foreach (var raw in File.ReadLines(path))
        {
            string line = raw.TrimEnd();
            if (line.Contains("END_EVENT_LISTING", StringComparison.Ordinal)) break;
            if (line.StartsWith("E ", StringComparison.Ordinal)) { current = new List<string>(); events.Add(current); }
            if (current != null) current.Add(line);
            else header.Add(line);
        }
        return (header, events);
    }

    /// <summary>A collider run: the beams, their energy, and the families of hard channels left open. What comes
    /// out is everything those channels make — the drawn final state among the rest — and the selection happens
    /// afterwards, in TreeLevel, on the events as they are reconstructed. That is the whole point: a real ring
    /// cannot be asked for one final state, so the cross section quoted at the end is measured, not requested.
    ///
    /// These settings are the ones the Mac writes, switch for switch. The two engines read the same job and must
    /// hand Pythia the same thing, or the same document would give two samples depending on the machine it ran
    /// on — which is worse than either being wrong, because nothing would say so.</summary>
    static string ColliderBeams(MCProcess p, MCProcess.Channel[]? only = null)
    {
        if (p.Beams.Length != 2 || p.BeamEnergies.Length != 2) return "";
        var s = new StringBuilder();
        s.Append($"Beams:idA = {p.Beams[0]}\n");
        s.Append($"Beams:idB = {p.Beams[1]}\n");
        if (p.FixedTarget)
        {
            // A target at rest is said by its three vanishing components, not by an energy equal to its mass:
            // give it a number near the mass and it keeps a small momentum, and the collision energy is no
            // longer quite the one intended. BeamEnergies[0] is then the beam's momentum, and Pythia takes the
            // target's energy from its own mass table.
            s.Append("Beams:frameType = 3\n");
            s.Append($"Beams:pxA = 0\nBeams:pyA = 0\nBeams:pzA = {N(p.BeamEnergies[0])}\n");
            s.Append("Beams:pxB = 0\nBeams:pyB = 0\nBeams:pzB = 0\n");
        }
        else if (Math.Abs(p.BeamEnergies[0] - p.BeamEnergies[1]) < 1e-9)
        {
            // Equal energies are said once, as the energy in the centre of mass; unequal ones oblige Pythia to
            // boost, and it wants them one by one.
            s.Append("Beams:frameType = 1\n");
            s.Append($"Beams:eCM = {N(p.CentreOfMassEnergy)}\n");
        }
        else
        {
            s.Append("Beams:frameType = 2\n");
            s.Append($"Beams:eA = {N(p.BeamEnergies[0])}\nBeams:eB = {N(p.BeamEnergies[1])}\n");
        }

        // A charged current needs a beam that can change flavour. Two leptons of opposite charge cannot, so
        // switching ffbar2W on there would only print a warning and produce nothing.
        bool leptonic = p.Beams.All(b => Math.Abs(b) >= 11 && Math.Abs(b) <= 16);
        foreach (var channel in only ?? p.Channels)
        {
            switch (channel)
            {
                case MCProcess.Channel.SingleBoson:
                    s.Append("WeakSingleBoson:ffbar2gmZ = on\n");
                    if (!leptonic) s.Append("WeakSingleBoson:ffbar2W = on\n");
                    break;
                case MCProcess.Channel.BosonPair:
                    s.Append("WeakDoubleBoson:ffbar2gmZgmZ = on\n");
                    s.Append("WeakDoubleBoson:ffbar2ZW = on\n");
                    s.Append("WeakDoubleBoson:ffbar2WW = on\n");
                    break;
                case MCProcess.Channel.BosonExchange:
                    // The t channel: the two beams scatter off each other by passing a boson between them.
                    // Nothing annihilates, which is what makes an electron–proton ring possible. The exchanged
                    // photon diverges as Q² goes to zero; Pythia sets its own floor for want of better, and an
                    // explicit cut replaces it as soon as one is given.
                    s.Append("WeakBosonExchange:ff2ff(t:gmZ) = on\n");
                    s.Append("WeakBosonExchange:ff2ff(t:W) = on\n");
                    break;
                case MCProcess.Channel.Qcd:
                    // Hard parton scattering: the bulk of what a proton ring makes. Without it a hadron machine
                    // produces Drell–Yan and nothing else, which is a channel rather than a collider.
                    s.Append("HardQCD:all = on\n");
                    break;
                case MCProcess.Channel.Soft:
                    // Everything two hadrons do: elastic, diffractive, and the non-diffractive bulk. This is the
                    // total cross section — a hundred millibarns at 13 TeV against the odd millibarn of hard
                    // scattering — and it is the only setting under which "everything the beams make" is
                    // literally true. It needs the multiple interactions, which are what build the
                    // non-diffractive part, and it takes no transverse-momentum floor: a floor would cut away
                    // precisely the soft part it is here to show.
                    s.Append("SoftQCD:all = on\n");
                    s.Append("PartonLevel:MPI = on\n");
                    break;
                case MCProcess.Channel.Photoproduction:
                    // The lepton enters as the flux of quasi-real photons it radiates, and those interact
                    // hadronically. This replaces the beam: Pythia's own accounting shows the annihilation and
                    // t-channel processes accepting nothing once it is on, which is why this family cannot share
                    // a run with them.
                    s.Append("PDF:lepton2gamma = on\n");
                    s.Append("Photon:ProcessType = 0\n");
                    s.Append("HardQCD:all = on\n");
                    break;
            }
        }
        // The QCD cross section grows without bound as the transverse momentum goes to zero, so that family
        // insists on a floor: given one, it is used; given none, twenty GeV, which keeps the sample the hard
        // scattering one meant to look at rather than an enormous soft one.
        double? floor = p.MinimumPT;
        bool needsFloor = p.Channels.Contains(MCProcess.Channel.Qcd)
                       || p.Channels.Contains(MCProcess.Channel.Photoproduction);
        if (floor is null or <= 0 && needsFloor) floor = 20;
        if (p.Channels.Contains(MCProcess.Channel.Soft)) floor = null;
        if (floor is double pt && pt > 0) s.Append($"PhaseSpace:pTHatMin = {N(pt)}\n");
        return s.ToString();
    }

    /// <summary>Why this generator cannot run this collider job, or null when it can.
    ///
    /// Pythia opens families of hard processes by name, Herwig by inserting matrix elements, Sherpa by declaring
    /// processes over particle containers. WHIZARD and CalcHEP are built the other way round: they compile the
    /// one process they are given, and a family is not a thing one can hand them — enumerating every channel
    /// would be writing the answer rather than asking the question. They say so instead of pretending.</summary>
    static string? ColliderRefusal(MCJob.Generator generator, MCProcess p)
    {
        if (generator is MCJob.Generator.Pythia8 or MCJob.Generator.Herwig7 or MCJob.Generator.Sherpa3)
            return ColliderChannelRefusal(generator, p);
        return $"{MCJob.Label(generator)} computes the one process it is given, compiling a matrix element for "
             + "it. Opening whole families of channels, which is what a collider does, is not something it can "
             + "be asked. Use Pythia 8, Herwig 7 or Sherpa 3 as the collider, or turn the collider off to "
             + $"compute the drawn process with {MCJob.Label(generator)}";
    }

    /// <summary>The families a generator knows, among those asked for. Said here rather than discovered in a
    /// log: a channel silently left out is a cross section quietly wrong.</summary>
    static string? ColliderChannelRefusal(MCJob.Generator generator, MCProcess p)
    {
        MCProcess.Channel[] known = generator switch
        {
            MCJob.Generator.Herwig7 => new[] { MCProcess.Channel.SingleBoson, MCProcess.Channel.BosonPair,
                                               MCProcess.Channel.Qcd, MCProcess.Channel.Soft },
            MCJob.Generator.Sherpa3 => new[] { MCProcess.Channel.SingleBoson, MCProcess.Channel.BosonPair,
                                               MCProcess.Channel.Qcd },
            _ => Enum.GetValues<MCProcess.Channel>(),
        };
        var missing = p.Channels.Where(c => !known.Contains(c)).ToArray();
        if (missing.Length == 0) return null;
        return $"{MCJob.Label(generator)} does not open " + string.Join(", ", missing.Select(ChannelName))
             + " as a collider channel. Pythia 8 opens all of them; otherwise leave that family out";
    }

    static string ChannelName(MCProcess.Channel c) => c switch
    {
        MCProcess.Channel.BosonPair => "boson pairs",
        MCProcess.Channel.BosonExchange => "boson exchange (the t channel)",
        MCProcess.Channel.Qcd => "hard QCD",
        MCProcess.Channel.Photoproduction => "photoproduction",
        MCProcess.Channel.Soft => "the whole cross section",
        _ => "single-boson annihilation",
    };

    /// <summary>Why these beams cannot do what the channels ask, said plainly rather than by producing nothing.
    /// Annihilation wants a particle and its antiparticle, or two hadrons whose partons see to it; the t channel
    /// asks for nothing of the sort, and so never objects.</summary>
    static string? ColliderObjection(MCProcess p)
    {
        if (p.Channels.Length == 0) return null;
        // The soft family already contains the hard scattering: its non-diffractive part builds it out of the
        // multiple interactions. Running both counts the same events twice, which no warning afterwards can
        // undo, so the two are refused together.
        if (p.Channels.Contains(MCProcess.Channel.Soft) && p.Channels.Contains(MCProcess.Channel.Qcd))
            return "the whole cross section already contains the hard scattering — its non-diffractive part "
                 + "builds it from the multiple interactions — so asking for both counts the same events twice. "
                 + "Choose the whole cross section, or the hard scattering above a transverse-momentum floor";
        bool hadronic0 = Math.Abs(p.Beams[0]) > 100, hadronic1 = Math.Abs(p.Beams[1]) > 100;
        bool annihilate = (hadronic0 && hadronic1) || p.Beams[0] == -p.Beams[1];
        // Hard QCD wants partons on both sides, which is to say two hadrons; the t channel asks for nothing; and
        // photoproduction wants a lepton, since the photon flux is what a lepton radiates.
        bool open = p.Channels.Any(c => c switch
        {
            MCProcess.Channel.BosonExchange => true,
            MCProcess.Channel.Qcd or MCProcess.Channel.Soft => hadronic0 && hadronic1,
            MCProcess.Channel.Photoproduction => !hadronic0 || !hadronic1,
            _ => annihilate,
        });
        if (open) return null;
        if (p.Channels.All(c => c == MCProcess.Channel.Photoproduction))
            return $"beams {p.Beams[0]} and {p.Beams[1]} are both hadrons, and neither radiates the photon flux "
                 + "photoproduction needs — that family wants a lepton on one side at least";
        // Name the obstacle that is actually there. Asking for hard QCD between two leptons is not a failure to
        // annihilate — e⁺ and e⁻ annihilate perfectly well — it is an absence of partons, and saying the wrong
        // thing sends whoever reads it looking in the wrong place.
        if (p.Channels.All(c => c == MCProcess.Channel.Qcd))
            return $"beams {p.Beams[0]} and {p.Beams[1]} carry no partons, so hard QCD has nothing to scatter "
                 + "— that family wants two hadrons";
        return $"beams {p.Beams[0]} and {p.Beams[1]} cannot annihilate, so the channels asked for "
             + "(ff̄ → γ*/Z, ff̄ → VV) have nothing to work with — these two scatter "
             + "rather than annihilate, which is the boson-exchange family";
    }

    /// <summary>Herwig 7: written as a <c>.in</c> file, then <c>Herwig read</c> and <c>Herwig run</c>. On
    /// Windows the whole job is handed to the container instead, which runs this very code inside itself; the
    /// WSL path below is what remains for someone who built Herwig there by hand.</summary>
    bool Herwig(DateTimeOffset start)
    {
        if (Installation.Container() is { } container) return InContainer(container, start);
        if (Installation.Shell == null) return Failed(Missing("Herwig 7"), start);
        if (Installation.ShellPath(folder.Path) is not string inside)
            return Failed("the job folder is not reachable from the shell that runs Herwig", start);
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
        if (!RunInShell($"cd {quoted} && Herwig read {name}.in", start, version, step: "lecture de la configuration", finishNow: false)) return false;
        return RunInShell($"cd {quoted} && Herwig run {name}.run -N {job.Events}", start, version);
    }

    /// <summary>Sherpa 3 inside WSL: it has no Les Houches reader, so it is given the process itself, as a YAML
    /// run card. It computes the matrix element (Comix), showers, hadronises and writes the HepMC3 itself.</summary>
    bool Sherpa(DateTimeOffset start)
    {
        if (job.HardProcess is not MCProcess p || p.Beams.Length != 2 || p.BeamEnergies.Length != 2 || p.FinalState.Length == 0)
            return Failed("Sherpa computes the process itself and needs its description (beams, energies, final state)", start);
        if (Installation.Container() is { } container) return InContainer(container, start);
        if (Installation.Shell == null) return Failed(Missing("Sherpa 3"), start);
        if (Installation.ShellPath(folder.Path) is not string inside)
            return Failed("the job folder is not reachable from the shell that runs Sherpa", start);
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
        // Sherpa donne d'office une structure aux faisceaux de leptons — la densité « PDFE », c'est-à-dire le
        // rayonnement initial de QED. La section efficace qu'il annonce n'est alors plus celle du processus à
        // √s : elle est dominée par le retour radiatif vers le Z, et sort six fois trop haut (21 pb au lieu de
        // 3,2 pour e⁻e⁺ → b b̄ à 200 GeV). Les autres générateurs calculent à énergie fixe ; on aligne Sherpa,
        // et qui veut le rayonnement le redemande dans les réglages libres. Les faisceaux hadroniques, eux, ne
        // sont rien sans leurs densités.
        if (!p.Beams.All(b => Math.Abs(b) > 100)) card.Append("PDF_LIBRARY: None\n");
        if (p.MinimumPT is double pt) card.Append($"SELECTORS:\n- [PT, {p.FinalState[0]}, {N(pt)}, E_CMS]\n");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) card.Append(job.ExtraSettings + "\n");
        File.WriteAllText(Path.Combine(folder.Path, "Sherpa.yaml"), card.ToString().Replace("\r\n", "\n"), MCEngineProtocol.Utf8);

        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("sherpa3", out var v) ? v : "Sherpa 3";
        // Sherpa appends its own extension to EVENT_OUTPUT; the job expects events.hepmc.
        string quoted = Quote(inside);
        string stem = Path.GetFileNameWithoutExtension(job.Output);
        // Sherpa 3.0.5 adds nothing at all to the name in EVENT_OUTPUT: HepMC3[events] — it writes a file
        // called `events`, full stop. Older ones append .hepmc, .hepmc3 or .hepmc.gz. All four are accepted:
        // without the last, fifty perfectly good events were being reported as a failure.
        return RunInShell($"cd {quoted} && Sherpa -f Sherpa.yaml && (test -f {stem}.hepmc || (test -f {stem}.hepmc3 && mv {stem}.hepmc3 {stem}.hepmc) || (test -f {stem}.hepmc.gz && gunzip -f {stem}.hepmc.gz) || (test -f {stem} && mv {stem} {stem}.hepmc)) ",
                        start, version);
    }

    /// <summary>WHIZARD 3: it computes the process itself, from a Sindarin script, and showers and hadronises
    /// with its own PYTHIA 6. It exists only where the engine runs on Linux — that is, in the image.</summary>
    bool Whizard(DateTimeOffset start)
    {
        if (job.HardProcess is not MCProcess p || p.Beams.Length != 2 || p.BeamEnergies.Length != 2 || p.FinalState.Length == 0)
            return Failed("WHIZARD computes the process itself and needs its description (beams, energies, final state)", start);
        if (Installation.Container() is { } container) return InContainer(container, start);
        if (Installation.Whizard is not string whizard) return Failed(Missing("WHIZARD 3"), start);

        var names = new List<string>();
        foreach (var code in p.Beams.Concat(p.FinalState))
        {
            if (Sindarin.Name(code) is not string n) return Failed($"WHIZARD does not know the particle {code}", start);
            names.Add(n);
        }
        string sample = Path.GetFileNameWithoutExtension(job.Output);   // it appends the format's extension
        // Initial-state radiation off the shower is WHIZARD's hadron-collision setting, and it refuses it
        // outright on a lepton machine; the QED radiation of a lepton beam is `?isr_active`, a different
        // thing, left to whoever asks for it in the extra settings — it would move the cross section.
        bool hadronBeams = p.Beams.All(b => Math.Abs(b) > 100);
        var script = new StringBuilder();
        script.Append("model = SM\n");
        script.Append($"process job = {names[0]}, {names[1]} => {string.Join(", ", names.Skip(2))}\n");
        script.Append($"sqrts = {N(p.CentreOfMassEnergy)} GeV\n");
        script.Append($"seed = {job.Seed % 900_000_000}\n");
        if (p.MinimumPT is double pt) script.Append($"cuts = all Pt > {N(pt)} GeV [final]\n");
        script.Append($"?ps_fsr_active = {Yes(job.Shower)}\n");
        script.Append($"?ps_isr_active = {Yes(job.Shower && hadronBeams)}\n");
        script.Append($"?hadronization_active = {Yes(job.Hadronisation)}\n");
        script.Append("$hadronization_method = \"PYTHIA6\"\n");
        script.Append($"n_events = {job.Events}\n");
        script.Append($"$sample = \"{sample}\"\n");
        script.Append("sample_format = hepmc\n");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) script.Append(job.ExtraSettings + "\n");
        script.Append("simulate (job)\n");
        File.WriteAllText(Path.Combine(folder.Path, "job.sin"), script.ToString().Replace("\r\n", "\n"), MCEngineProtocol.Utf8);

        string version = Installation.Capabilities(engineVersion).Versions.TryGetValue("whizard3", out var v) ? v : "WHIZARD 3";
        return RunProcess(whizard, new[] { "job.sin" }, start, version, crossSection: WhizardCrossSection);
    }

    static string Yes(bool b) => b ? "true" : "false";

    /// <summary>WHIZARD writes no cross section into its HepMC3, so it is read from the last line of its
    /// integration table — the combined result, in femtobarns.
    ///   "   6      29826  1.9440903E+04  6.30E+00    0.03    0.06   47.83    1.13   3"</summary>
    public static (double Value, double Error)? WhizardCrossSection(string log)
    {
        (double, double)? result = null;
        foreach (var line in log.Split('\n'))
        {
            var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (f.Length < 4) continue;
            if (!int.TryParse(f[0], out _) || !int.TryParse(f[1], out _)) continue;
            if (!f[2].Contains('E', StringComparison.Ordinal)) continue;
            if (!double.TryParse(f[2], NumberStyles.Float, CultureInfo.InvariantCulture, out double value)) continue;
            if (!double.TryParse(f[3], NumberStyles.Float, CultureInfo.InvariantCulture, out double error)) continue;
            if (value <= 0) continue;
            result = (value / 1000, error / 1000);                      // fb → pb, as everywhere else here
        }
        return result;
    }

    /// <summary>CalcHEP 3: it computes the hard process and stops there — no shower, no hadronisation. A job
    /// runs in a working copy of its tree, made by <c>mkWORKdir</c>, and leaves Les Houches events behind,
    /// which we turn into HepMC3 exactly as the passthrough backend does.</summary>
    bool CalcHep(DateTimeOffset start)
    {
        if (job.HardProcess is not MCProcess p || p.Beams.Length != 2 || p.BeamEnergies.Length != 2 || p.FinalState.Length == 0)
            return Failed("CalcHEP computes the process itself and needs its description (beams, energies, final state)", start);
        if (Installation.Container() is { } container) return InContainer(container, start);
        if (Installation.Calchep is not string root) return Failed(Missing("CalcHEP 3"), start);

        var names = new List<string>();
        foreach (var code in p.Beams.Concat(p.FinalState))
        {
            if (CalcHepNames.Name(code) is not string n) return Failed($"CalcHEP does not know the particle {code}", start);
            names.Add(n);
        }
        string incoming = string.Join(",", names.Take(2));
        string outgoing = string.Join(",", names.Skip(2));

        var work = Path.Combine(folder.Path, "calchep");
        try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch (Exception) { }
        if (!RunProcess(Path.Combine(root, "mkWORKdir"), new[] { work }, start, "CalcHEP",
                        step: "préparation du dossier de travail", finishNow: false)) return false;
        // A job that was interrupted — a container stopped, a machine switched off — leaves a lock behind,
        // and every later run in that folder refuses to start. The fresh folder above normally settles it;
        // this closes the door for the day someone reuses one.
        try { File.Delete(Path.Combine(work, "lock.batch")); } catch (Exception) { }

        var batch = new StringBuilder();
        batch.Append("Model:         SM\nModel changed: False\nGauge:         Feynman\n\n");
        batch.Append($"Process:   {incoming}->{outgoing}\n\n");
        batch.Append($"p1:        {N(p.BeamEnergies[0])}\n");
        batch.Append($"p2:        {N(p.BeamEnergies[1])}\n");
        if (p.MinimumPT is double pt)
            batch.Append($"Cut parameter:    T({names[2]})\nCut invert:       False\nCut min:          {N(pt)}\nCut max:\n");
        if (!string.IsNullOrEmpty(job.ExtraSettings)) batch.Append(job.ExtraSettings + "\n");
        batch.Append($"Number of events (per run step):  {job.Events}\n");
        batch.Append("Filename:                         events\nNTuple:                           False\n");
        batch.Append("Cleanup:                          False\nParallelization method:           local\n");
        batch.Append("Max number of nodes:              4\nMax number of processes per node: 1\n");
        File.WriteAllText(Path.Combine(work, "batch_file"), batch.ToString().Replace("\r\n", "\n"), MCEngineProtocol.Utf8);

        string version = Installation.CalchepVersion(root) ?? "CalcHEP 3";
        if (!RunProcess(Path.Combine(work, "calchep_batch"), new[] { "batch_file" }, start, version,
                        workingDirectory: work, finishNow: false)) return false;

        // CalcHEP gzips its Les Houches file; unpack it, then convert as the passthrough backend does.
        var packed = Path.Combine(work, "batch_results", "events-single.lhe.gz");
        if (!File.Exists(packed)) return Failed($"{version} wrote no event file — see engine.log", start);
        var lhe = Path.Combine(folder.Path, "events.lhe");
        using (var source = File.OpenRead(packed))
        using (var unpacked = new System.IO.Compression.GZipStream(source, System.IO.Compression.CompressionMode.Decompress))
        using (var target = File.Create(lhe))
            unpacked.CopyTo(target);

        var events = LesHouchesLite.Read(lhe);
        LesHouchesLite.WriteHepMC(events, folder.OutputPath(job), events.CrossSection);
        Publish(new MCStatus(MCStatus.State.Finished, job.Id)
        {
            Number = number, Started = start, Finished = DateTimeOffset.Now, Progress = 1,
            EventsWritten = events.Events.Count, CrossSection = events.CrossSection,
            GeneratorVersion = version, Seconds = (DateTimeOffset.Now - start).TotalSeconds,
        });
        return true;
    }

    static string N(double v) => v.ToString("G", CultureInfo.InvariantCulture);
    static string Quote(string path) => "'" + path.Replace("'", "'\\''") + "'";

    // Running a program and following it

    bool RunInShell(string command, DateTimeOffset start, string name, string? step = null, bool finishNow = true)
        => RunProcess(Installation.Shell!, Installation.ShellArguments(command), start, name, step, finishNow,
                      workingDirectory: folder.Path);

    /// <summary>What to say when a generator that only exists on Linux has nowhere to run.</summary>
    static string Missing(string generator)
        => Installation.Native
            ? $"{generator} is not installed in this image"
            : $"{generator} has no Windows build: it runs in the TreeLevel Tools container, which is not installed";

    /// <summary>Herwig and Sherpa on Windows: the job folder is bind-mounted at <c>/job</c> and the engine
    /// inside the image runs the very same code on it. The container owns the folder while it works — it
    /// writes status.json, engine.log and the events itself — so nothing here touches them meanwhile.</summary>
    bool InContainer((string Docker, string Image) container, DateTimeOffset start)
    {
        Publish(new MCStatus(MCStatus.State.Running, job.Id)
        {
            Number = number, Started = start, Message = "conteneur",
            GeneratorVersion = MCJob.Label(job.UseGenerator),
        });
        // Docker takes the Windows path of the mount, but only with forward slashes.
        var mount = folder.Path.Replace('\\', '/') + ":/job";
        var info = new ProcessStartInfo(container.Docker)
        {
            WorkingDirectory = folder.Path,
            RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        foreach (var a in new[] { "run", "--rm", "-v", mount, container.Image, "run", "/job" })
            info.ArgumentList.Add(a);
        using var process = new Process { StartInfo = info };
        if (!process.Start()) return Failed("cannot start Docker", start);
        // Read both streams so that the container never blocks on a full pipe; its own log is the one in the
        // job folder, written from the inside.
        process.StandardOutput.ReadToEnd();
        string errors = process.StandardError.ReadToEnd();
        process.WaitForExit();

        var status = folder.ReadStatus();
        if (process.ExitCode == 0 && status?.JobState == MCStatus.State.Finished) return true;
        if (status?.JobState == MCStatus.State.Failed && !string.IsNullOrEmpty(status.Message))
            return Failed(status.Message, start);
        var reason = errors.Split('\n').FirstOrDefault(l => l.Trim().Length > 0)?.Trim();
        return Failed($"the container stopped with code {process.ExitCode}" + (reason == null ? "" : " — " + reason), start);
    }

    bool RunProcess(string exe, string[] arguments, DateTimeOffset start, string name,
                    string? step = null, bool finishNow = true, string? workingDirectory = null,
                    IReadOnlyDictionary<string, string>? environment = null,
                    Func<string, (double Value, double Error)?>? crossSection = null)
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
        // Kept only when someone will read it: WHIZARD writes no cross section into its HepMC3, so it has to
        // be picked out of what it printed.
        var printed = crossSection == null ? null : new StringBuilder();
        void OnLine(string? line)
        {
            if (line == null) return;
            lock (gate) { log.WriteLine(line); printed?.AppendLine(line); }
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
        if (printed != null && crossSection!(printed.ToString()) is { } read) { sigma = read.Value; sigmaError = read.Error; }
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
        Console.Error.WriteLine("treelevel-tools: " + message);
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

/// <summary>Sindarin's particle names, as WHIZARD's Standard Model calls them. Beware: they are not CalcHEP's
/// — there the electron is <c>e</c>, here it is <c>e1</c>.</summary>
public static class Sindarin
{
    static readonly Dictionary<int, (string Particle, string Anti)> Names = new()
    {
        [1] = ("d", "D"), [2] = ("u", "U"), [3] = ("s", "S"), [4] = ("c", "C"), [5] = ("b", "B"), [6] = ("t", "T"),
        [11] = ("e1", "E1"), [12] = ("n1", "N1"), [13] = ("e2", "E2"), [14] = ("n2", "N2"),
        [15] = ("e3", "E3"), [16] = ("n3", "N3"),
        [21] = ("gl", "gl"), [22] = ("A", "A"), [23] = ("Z", "Z"), [24] = ("Wp", "Wm"), [25] = ("H", "H"),
    };

    public static string? Name(int code)
        => Names.TryGetValue(Math.Abs(code), out var pair) ? (code >= 0 ? pair.Particle : pair.Anti) : null;
}

/// <summary>CalcHEP's own particle names, as its Standard Model calls them.</summary>
public static class CalcHepNames
{
    static readonly Dictionary<int, (string Particle, string Anti)> Names = new()
    {
        [1] = ("d", "D"), [2] = ("u", "U"), [3] = ("s", "S"), [4] = ("c", "C"), [5] = ("b", "B"), [6] = ("t", "T"),
        [11] = ("e", "E"), [12] = ("ne", "Ne"), [13] = ("m", "M"), [14] = ("nm", "Nm"),
        [15] = ("l", "L"), [16] = ("nl", "Nl"),
        [21] = ("G", "G"), [22] = ("A", "A"), [23] = ("Z", "Z"), [24] = ("W+", "W-"), [25] = ("h", "h"),
    };

    public static string? Name(int code)
        => Names.TryGetValue(Math.Abs(code), out var pair) ? (code >= 0 ? pair.Particle : pair.Anti) : null;
}
