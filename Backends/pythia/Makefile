# Builds the Pythia 8 driver of the engine. Needs Pythia 8 (with HepMC3 support) and pythia8-config in PATH.
#   make            build ./treelevel-pythia
#   make install    copy it beside the engine's modules (~/Library/Application Support/TreeLevel MC Engine/Modules/pythia8)
PYTHIA_CONFIG ?= pythia8-config
CXX ?= c++
CXXFLAGS ?= -O2 -std=c++17
HEPMC_PREFIX ?= $(shell $(PYTHIA_CONFIG) --prefix)
MODULES ?= $(HOME)/Library/Application Support/TreeLevel MC Engine/Modules/pythia8

FLAGS := $(shell $(PYTHIA_CONFIG) --cxxflags) $(shell $(PYTHIA_CONFIG) --libs)
HEPMC := $(shell pkg-config --cflags --libs HepMC3 2>/dev/null)
ifeq ($(strip $(HEPMC)),)
HEPMC := -I/opt/homebrew/include -L/opt/homebrew/lib -lHepMC3 -Wl,-rpath,/opt/homebrew/lib
endif

treelevel-pythia: main.cpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(FLAGS) $(HEPMC)

install: treelevel-pythia
	mkdir -p "$(MODULES)"
	cp treelevel-pythia "$(MODULES)/"

clean:
	rm -f treelevel-pythia
