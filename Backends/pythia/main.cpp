// TreeLevel MC Engine — Pythia 8 driver.
//
// Reads a Pythia command file (written by the engine, pointing at the Les Houches events of the job) and
// writes the showered events as HepMC3 (Asciiv3). The HepMC3 output is written here, so that the module needs
// nothing but Pythia itself — MacPorts' `pythia` port ships neither Pythia8Plugins nor HepMC3.
// When Pythia's own HepMC3 interface is available, build with -DTREELEVEL_WITH_HEPMC3 to use it instead.
//
//   treelevel-pythia --config job/pythia.cmnd --out job/events.hepmc
//   treelevel-pythia --version
//
// Build:  make -C Backends/pythia            (MacPorts, Homebrew or a local build of Pythia 8)
//
// Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later (Pythia 8 is GPL).

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <vector>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define NOGDI
#include <windows.h>
#ifndef S_IFDIR
#define S_IFDIR _S_IFDIR
#endif
#endif
#include "Pythia8/Pythia.h"
#ifdef TREELEVEL_WITH_HEPMC3
#include "Pythia8Plugins/HepMC3.h"
#endif

namespace {

bool isDirectory(const std::string& path) {
  struct stat info;
  return stat(path.c_str(), &info) == 0 && (info.st_mode & S_IFDIR);
}

/// The folder the running program is in, so that a module can carry its own data next to it.
std::string executableFolder() {
#ifdef _WIN32
  char buffer[MAX_PATH];
  DWORD n = GetModuleFileNameA(nullptr, buffer, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return "";
  std::string path(buffer, n);
  const size_t cut = path.find_last_of("\\/");
  return cut == std::string::npos ? "" : path.substr(0, cut);
#else
  return "";
#endif
}

/// Where Pythia's xmldoc lives: the environment first, then the usual package layouts. Windows has no such
/// layout — the module that win/backends/pythia/build.ps1 installs carries xmldoc beside the driver.
std::string dataPath() {
  if (const char* env = std::getenv("PYTHIA8DATA")) return env;
#ifdef _WIN32
  std::vector<std::string> candidates;
  const std::string folder = executableFolder();
  if (!folder.empty())
    for (const char* relative : {"/xmldoc", "/share/Pythia8/xmldoc", "/../share/Pythia8/xmldoc"})
      candidates.push_back(folder + relative);
  if (const char* local = std::getenv("LOCALAPPDATA"))
    candidates.push_back(std::string(local) + "/TreeLevel MC Engine/Modules/pythia8/xmldoc");
  for (const std::string& path : candidates) if (isDirectory(path)) return path;
#else
  const char* candidates[] = {
    "/opt/local/share/doc/pythia/xmldoc",           // MacPorts
    "/opt/homebrew/share/Pythia8/xmldoc",           // Homebrew (Apple silicon)
    "/usr/local/share/Pythia8/xmldoc",              // Homebrew (Intel), local install
    "/usr/share/Pythia8/xmldoc",
  };
  for (const char* path : candidates) if (isDirectory(path)) return path;
#endif
  return "";
}

/// Minimal HepMC3 (Asciiv3) writer: one vertex per particle with two mothers, a parent id otherwise.
/// The syntax is the one TreeLevel reads back and the one Pythia's own writer produces.
class HepMCWriter {
public:
  explicit HepMCWriter(const std::string& path) : out(path) {
    out << "HepMC::Version 3.02.00\n" << "HepMC::Asciiv3-START_EVENT_LISTING\n";
    out << std::scientific << std::setprecision(10);
  }
  ~HepMCWriter() { out << "HepMC::Asciiv3-END_EVENT_LISTING\n"; }
  bool good() const { return out.good(); }

  void write(const Pythia8::Event& event, double weight, int number, double crossSectionPb, double errorPb) {
    // HepMC ids are 1-based and skip Pythia's entry 0 (the whole system).
    const int n = event.size() - 1;
    std::vector<std::string> vertices;
    std::string particles;
    for (int i = 1; i < event.size(); ++i) {
      const Pythia8::Particle& p = event[i];
      int status = p.isFinal() ? 1 : (i <= 2 ? 4 : 2);
      int parent = 0;
      if (p.mother1() > 0 && p.mother2() > p.mother1()) {
        // Several mothers: a vertex holding them all.
        std::string list;
        for (int m = p.mother1(); m <= p.mother2(); ++m) list += (list.empty() ? "" : ",") + std::to_string(m);
        vertices.push_back("V " + std::to_string(-(int)vertices.size() - 1) + " 0 [" + list + "]\n");
        parent = -(int)vertices.size();
      } else if (p.mother1() > 0) {
        parent = p.mother1();
      }
      particles += "P " + std::to_string(i) + " " + std::to_string(parent) + " " + std::to_string(p.id()) + " ";
      particles += number_(p.px()) + " " + number_(p.py()) + " " + number_(p.pz()) + " " + number_(p.e()) + " "
                 + number_(p.m()) + " " + std::to_string(status) + "\n";
    }
    out << "E " << number << " " << vertices.size() << " " << n << "\n";
    out << "U GEV MM\n";
    out << "W " << number_(weight) << "\n";
    if (number == 0) {
      // With Les Houches input Pythia reports the file's cross section and no useful error: write 0 rather
      // than an error as large as the value itself.
      const double error = (errorPb > 0 && errorPb < crossSectionPb) ? errorPb : 0.0;
      out << "A 0 GenCrossSection " << number_(crossSectionPb) << " " << number_(error) << " -1 -1\n";
    }
    for (const std::string& v : vertices) out << v;
    out << particles;
  }

private:
  static std::string number_(double x) {
    char buffer[32];
    snprintf(buffer, sizeof buffer, "%.10e", x);
    return buffer;
  }
  std::ofstream out;
};

}  // namespace

int main(int argc, char* argv[]) {
  std::string config, out;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--version") { std::cout << PYTHIA_VERSION << std::endl; return 0; }
    if (a == "--config" && i + 1 < argc) config = argv[++i];
    else if (a == "--out" && i + 1 < argc) out = argv[++i];
  }
  if (config.empty() || out.empty()) {
    std::cerr << "usage: treelevel-pythia --config file.cmnd --out events.hepmc" << std::endl;
    return 2;
  }

  const std::string data = dataPath();
  Pythia8::Pythia pythia(data.empty() ? "../share/Pythia8/xmldoc" : data);
  if (!pythia.readFile(config)) { std::cerr << "cannot read " << config << std::endl; return 1; }
  if (!pythia.init()) { std::cerr << "Pythia failed to initialise" << std::endl; return 1; }

#ifdef TREELEVEL_WITH_HEPMC3
  Pythia8::Pythia8ToHepMC toHepMC(out);
#else
  HepMCWriter writer(out);
  if (!writer.good()) { std::cerr << "cannot write " << out << std::endl; return 1; }
#endif

  const int requested = pythia.mode("Main:numberOfEvents");
  int written = 0, failures = 0;
  for (int i = 0; i < requested; ++i) {
    if (!pythia.next()) {
      if (pythia.info.atEndOfFile()) break;         // the Les Houches file is exhausted
      if (++failures > requested / 10 + 10) { std::cerr << "too many failed events" << std::endl; break; }
      continue;
    }
#ifdef TREELEVEL_WITH_HEPMC3
    toHepMC.writeNextEvent(pythia);
#else
    // HepMC3 cross sections are in pb; Pythia reports mb.
    writer.write(pythia.event, pythia.info.weight(), written,
                 pythia.info.sigmaGen() * 1e9, pythia.info.sigmaErr() * 1e9);
#endif
    ++written;
    if (written % 100 == 0 || written == requested)
      std::cout << written << " events have been generated" << std::endl;
  }
  pythia.stat();
  std::cout << "written " << written << " events, sigma = " << pythia.info.sigmaGen()
            << " +- " << pythia.info.sigmaErr() << " mb" << std::endl;
  return written > 0 ? 0 : 1;
}
