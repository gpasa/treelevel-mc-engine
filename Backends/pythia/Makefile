# Builds the Pythia 8 driver of the engine.
#
#   make            build ./treelevel-pythia
#   make install    copy it into ~/Library/Application Support/TreeLevel MC Engine/Modules/pythia8
#
# Pythia is found through pythia8-config when it is in the PATH, otherwise in the usual MacPorts and Homebrew
# layouts. HepMC3 is not needed: the driver writes the HepMC3 file itself. If Pythia was built with its own
# HepMC3 interface and you would rather use it, build with:  make WITH_HEPMC3=1
CXX ?= c++
CXXFLAGS ?= -O2 -std=c++17
MODULES ?= $(HOME)/Library/Application Support/TreeLevel MC Engine/Modules/pythia8

# Le pilote et son xmldoc doivent venir du même Pythia. Sans cela — une machine qui porte MacPorts et
# Homebrew, l'un des deux désactivé, c'est courant — on lie 8.310 et on lui donne les données de 8.303 :
#     PYTHIA Abort from Pythia::checkVersion: unmatched version numbers
# et il s'arrête avant de lire une seule commande. On relève donc les deux ensemble, branche par branche.
PYTHIA_CONFIG := $(shell command -v pythia8-config 2>/dev/null)
ifneq ($(PYTHIA_CONFIG),)
  FLAGS := $(shell $(PYTHIA_CONFIG) --cxxflags) $(shell $(PYTHIA_CONFIG) --libs)
  XMLDOC := $(shell $(PYTHIA_CONFIG) --xmldoc 2>/dev/null)
else ifneq ($(wildcard /opt/local/include/pythia/Pythia8/Pythia.h),)
  # MacPorts: headers under include/pythia, no pythia8-config, xmldoc in share/doc/pythia
  FLAGS := -I/opt/local/include/pythia -L/opt/local/lib -lpythia8 -Wl,-rpath,/opt/local/lib
  XMLDOC := $(firstword $(wildcard /opt/local/share/doc/pythia/xmldoc /opt/local/share/Pythia8/xmldoc))
else ifneq ($(wildcard /opt/homebrew/include/Pythia8/Pythia.h),)
  FLAGS := -I/opt/homebrew/include -L/opt/homebrew/lib -lpythia8 -Wl,-rpath,/opt/homebrew/lib
  XMLDOC := $(firstword $(wildcard /opt/homebrew/share/Pythia8/xmldoc))
else ifneq ($(wildcard /usr/local/include/Pythia8/Pythia.h),)
  FLAGS := -I/usr/local/include -L/usr/local/lib -lpythia8 -Wl,-rpath,/usr/local/lib
  XMLDOC := $(firstword $(wildcard /usr/local/share/Pythia8/xmldoc))
else
  $(error Pythia 8 not found — install it (MacPorts: sudo port install pythia) or put pythia8-config in the PATH)
endif

ifdef WITH_HEPMC3
  HEPMC := $(shell pkg-config --cflags --libs HepMC3 2>/dev/null)
  ifeq ($(strip $(HEPMC)),)
    HEPMC := -I/opt/homebrew/include -L/opt/homebrew/lib -lHepMC3 -Wl,-rpath,/opt/homebrew/lib
  endif
  FLAGS += -DTREELEVEL_WITH_HEPMC3 $(HEPMC)
endif

treelevel-pythia: main.cpp
	$(CXX) $(CXXFLAGS) $< -o $@ $(FLAGS)

install: treelevel-pythia
	mkdir -p "$(MODULES)"
	cp treelevel-pythia "$(MODULES)/"
	@if [ -d "$(XMLDOC)" ]; then \
	  mkdir -p "$(MODULES)/share/Pythia8"; \
	  rm -rf "$(MODULES)/share/Pythia8/xmldoc"; \
	  /usr/bin/ditto "$(XMLDOC)" "$(MODULES)/share/Pythia8/xmldoc"; \
	  echo "  xmldoc $$(grep -o 'default=\"[0-9.]*\"' "$(XMLDOC)/Version.xml" | head -1) depuis $(XMLDOC)"; \
	else \
	  echo "  ⚠ xmldoc introuvable : le pilote et ses données risquent de ne pas s'accorder"; \
	fi

clean:
	rm -f treelevel-pythia
