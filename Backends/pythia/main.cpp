// TreeLevel MC Engine — Pythia 8 driver.
//
// Reads a Pythia command file (written by the engine, pointing at the Les Houches events of the job) and
// writes the showered events as HepMC3. Nothing else: the job logic stays in the engine, so this file only
// has to be rebuilt when Pythia itself changes.
//
//   treelevel-pythia --config job/pythia.cmnd --out job/events.hepmc
//   treelevel-pythia --version
//
// Build:  make -C Backends/pythia            (uses pythia8-config; needs Pythia built with HepMC3)
//
// Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later (Pythia 8 is GPL).

#include <iostream>
#include <string>
#include "Pythia8/Pythia.h"
#include "Pythia8Plugins/HepMC3.h"

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

  Pythia8::Pythia pythia;
  if (!pythia.readFile(config)) { std::cerr << "cannot read " << config << std::endl; return 1; }
  if (!pythia.init()) { std::cerr << "Pythia failed to initialise" << std::endl; return 1; }

  Pythia8::Pythia8ToHepMC toHepMC(out);
  const int requested = pythia.mode("Main:numberOfEvents");
  int written = 0, failures = 0;
  for (int i = 0; i < requested; ++i) {
    if (!pythia.next()) {
      if (pythia.info.atEndOfFile()) break;         // the Les Houches file is exhausted
      if (++failures > requested / 10 + 10) { std::cerr << "too many failed events" << std::endl; break; }
      continue;
    }
    toHepMC.writeNextEvent(pythia);
    ++written;
    if (written % 100 == 0 || written == requested)
      std::cout << written << " events have been generated" << std::endl;
  }
  pythia.stat();
  std::cout << "written " << written << " events, sigma = " << pythia.info.sigmaGen()
            << " +- " << pythia.info.sigmaErr() << " mb" << std::endl;
  return written > 0 ? 0 : 1;
}
