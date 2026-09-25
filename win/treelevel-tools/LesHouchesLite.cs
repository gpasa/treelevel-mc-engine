using System.Globalization;
using System.Text;

namespace TreeLevel.MC;

/// <summary>Just enough Les Houches and HepMC3 to pass events through without a shower: the engine does not
/// carry TreeLevel's physics library, and the real generators read and write these formats themselves.</summary>
public static class LesHouchesLite
{
    public sealed record Particle(int Pdg, int Status, int Mother1, int Mother2, int Colour1, int Colour2,
                                  double Px, double Py, double Pz, double E, double M);

    public sealed record Event(List<Particle> Particles, double Weight, double Scale);

    public sealed record File(List<Event> Events, double? CrossSection);

    public static File Read(string path)
    {
        var events = new List<Event>();
        double? crossSection = null;
        var lines = System.IO.File.ReadAllLines(path);
        int cursor = 0;
        string? Next()
        {
            while (cursor < lines.Length)
            {
                var t = lines[cursor++].Trim();
                if (t.Length > 0 && !t.StartsWith("#", StringComparison.Ordinal)) return t;
            }
            return null;
        }
        double D(string s) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : 0;
        int I(string s) => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : 0;
        string[] Fields(string l) => l.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);

        while (Next() is string line)
        {
            if (line.StartsWith("<init", StringComparison.Ordinal))
            {
                Next();
                if (Next() is string l && Fields(l) is { Length: > 0 } f) crossSection = D(f[0]);
            }
            // The tag, and nothing that merely starts like it: CalcHEP writes a hepML header holding
            // <eventsNumber>, which a looser test takes for the beginning of an event.
            else if (line.StartsWith("<event>", StringComparison.Ordinal) || line.StartsWith("<event ", StringComparison.Ordinal))
            {
                if (Next() is not string header) break;
                var h = Fields(header);
                // A line that is not an event header is skipped, not the end of the file: reading stopped at
                // the first surprise and a whole sample came out empty without a word.
                if (h.Length < 6) continue;
                int n = I(h[0]);
                double weight = D(h[2]), scale = D(h[3]);
                var particles = new List<Particle>();
                for (int k = 0; k < n; k++)
                {
                    if (Next() is not string pl) break;
                    var p = Fields(pl);
                    if (p.Length < 11) continue;
                    particles.Add(new Particle(I(p[0]), I(p[1]), I(p[2]), I(p[3]), I(p[4]), I(p[5]),
                                               D(p[6]), D(p[7]), D(p[8]), D(p[9]), D(p[10])));
                }
                events.Add(new Event(particles, weight, scale));
                while (Next() is string tag && !tag.StartsWith("</event", StringComparison.Ordinal)) { }
            }
        }
        return new File(events, crossSection);
    }

    /// <summary>The same events as HepMC3 (Asciiv3): beams with status 4, one vertex, the rest as they are.</summary>
    public static void WriteHepMC(File file, string path, double? crossSection)
    {
        var s = new StringBuilder("HepMC::Version 3.02.00\nHepMC::Asciiv3-START_EVENT_LISTING\n");
        for (int n = 0; n < file.Events.Count; n++)
        {
            var e = file.Events[n];
            s.Append($"E {n} 1 {e.Particles.Count}\nU GEV MM\nW {Number(e.Weight)}\n");
            if (n == 0 && crossSection is double xs) s.Append($"A 0 GenCrossSection {Number(xs)} {Number(0)} -1 -1\n");
            var incoming = new List<int>();
            for (int k = 0; k < e.Particles.Count; k++) if (e.Particles[k].Status == -1) incoming.Add(k + 1);
            var body = new StringBuilder();
            for (int k = 0; k < e.Particles.Count; k++)
            {
                var p = e.Particles[k];
                int status = p.Status == -1 ? 4 : (p.Status == 1 ? 1 : 2);
                int parent = p.Status == -1 ? 0 : -1;
                body.Append($"P {k + 1} {parent} {p.Pdg} {Number(p.Px)} {Number(p.Py)} {Number(p.Pz)} {Number(p.E)} {Number(p.M)} {status}\n");
            }
            s.Append("V -1 0 [" + string.Join(",", incoming) + "]\n");
            s.Append(body);
        }
        s.Append("HepMC::Asciiv3-END_EVENT_LISTING\n");
        System.IO.File.WriteAllText(path, s.ToString(), MCEngineProtocol.Utf8);
    }

    static string Number(double x) => x.ToString("0.0000000000e+00", CultureInfo.InvariantCulture);
}
