# TreeLevel MC Engine — Herwig 7 and Sherpa 3 in a container.
#
# Neither has a Windows build, and building them by hand asks a lot of anyone who just wants to shower a few
# events. The image carries them ready to run, together with the engine itself, so that TreeLevel only has to
# hand over a job folder:
#
#   docker run --rm -v "<job folder>:/job" ghcr.io/gpasa/treelevel-mc-engine:<version> run /job
#
# The engine inside reads /job/job.json exactly as it does on the host, and writes status.json, engine.log and
# events.hepmc back into the same folder — the bind mount is the whole protocol.
#
# Build (both architectures, in CI):
#   docker buildx build --platform linux/amd64,linux/arm64 -f docker/Dockerfile .
#
# Herwig 7 is GPL-3.0-only, ThePEG GPL-3.0-or-later, Sherpa GPL-3.0; the engine is GPL v3. This file, with the
# versions it pins, is the recipe the licences ask to be published alongside the binaries — see docker/README.md.
#
# Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later.

# --- the generators ----------------------------------------------------------------------------------------
FROM debian:bookworm AS hep

ARG SHERPA_VERSION=3.0.5
ARG PYTHIA_VERSION=8318
ENV PREFIX=/opt/treelevel-mc
ENV DEBIAN_FRONTEND=noninteractive

# Failures in the middle of a pipeline must fail the layer: without this, `… | tee` reports the success of tee
# and a build that never happened sails on to the next step.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# python-is-python3: the bootstrap script asks for `python`, which Debian stopped providing years ago.
# cython: it rebuilds the Python interfaces of LHAPDF, YODA and Rivet and stops outright without it. Debian
# names the program cython3, and the bootstrap looks for cython.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential gfortran autoconf automake libtool make patch \
      python3 python3-dev python-is-python3 cython3 python3-setuptools \
      zlib1g-dev libgsl-dev libboost-all-dev \
      cmake libsqlite3-dev libzip-dev pkg-config git wget ca-certificates \
    && ln -sf /usr/bin/cython3 /usr/local/bin/cython \
    && rm -rf /var/lib/apt/lists/*

# Herwig carries LoopTools, whose D0func.F writes `parameter (nz2 = -2147483648)` — a constant that overflows
# for a modern gfortran, which then refuses everything that uses it ("Integer too big for its kind at (1)").
# The flag it suggests cannot go through the environment, configure overwrites FCFLAGS; the wrapper sits ahead
# of /usr/bin in the PATH and always carries it. It is a file of its own rather than a printf, so that no
# layer of quoting stands between what is written here and what ends up in the script.
COPY docker/gfortran-wrapper.sh /usr/local/bin/gfortran
RUN chmod +x /usr/local/bin/gfortran && gfortran --version | head -1

# Herwig's own bootstrap builds the whole stack it needs — ThePEG, FastJet, LHAPDF, HepMC3 — into one prefix.
# --lite leaves out the loop libraries (VBFNLO, MadGraph, LoopTools): TreeLevel provides the hard process, so
# nothing here computes loops. The log keeps every URL it fetched, which is what the GPL asks us to publish.
#
# Debian's Boost rather than the one the bootstrap builds for itself: ThePEG links the compiled
# unit_test_framework, and on arm64 the bootstrap's own build left configure unable to work out the link flags
# ("could not figure out which toolset name to use"). The distribution's is complete on both architectures,
# and skipping that build saves a quarter of an hour.
RUN wget -q https://herwig.hepforge.org/downloads/herwig-bootstrap \
    && chmod +x herwig-bootstrap \
    && python3 ./herwig-bootstrap --lite -j "$(nproc)" --with-boost=/usr "$PREFIX" 2>&1 | tee /tmp/bootstrap.log \
    && mkdir -p "$PREFIX/share/treelevel-mc" \
    && grep -oE 'https?://[^ "]+\.(tar\.(gz|bz2|xz)|tgz)' /tmp/bootstrap.log | sort -u \
       > "$PREFIX/share/treelevel-mc/SOURCES.txt" \
    && rm -f herwig-bootstrap

# Sherpa into the same prefix, against the HepMC3, LHAPDF and FastJet the bootstrap just installed.
RUN wget -q -O sherpa.tar.gz \
      "https://gitlab.com/sherpa-team/sherpa/-/archive/v${SHERPA_VERSION}/sherpa-v${SHERPA_VERSION}.tar.gz" \
    && tar xzf sherpa.tar.gz && rm sherpa.tar.gz \
    && cmake -S "sherpa-v${SHERPA_VERSION}" -B build-sherpa \
         -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
         -DSHERPA_ENABLE_LHAPDF=ON  -DLHAPDF_DIR="$PREFIX" \
         -DSHERPA_ENABLE_HEPMC3=ON  -DHepMC3_DIR="$PREFIX" \
         -DSHERPA_ENABLE_FASTJET=ON -DFASTJET_DIR="$PREFIX" \
    && cmake --build build-sherpa -j "$(nproc)" \
    && cmake --install build-sherpa \
    && echo "https://gitlab.com/sherpa-team/sherpa/-/archive/v${SHERPA_VERSION}/sherpa-v${SHERPA_VERSION}.tar.gz" \
       >> "$PREFIX/share/treelevel-mc/SOURCES.txt" \
    && rm -rf build-sherpa "sherpa-v${SHERPA_VERSION}"

# Pythia 8 and the driver that reads a Les Houches file and writes HepMC3 — the same driver Windows builds
# with MSVC. It is here so that the image is the whole engine rather than two thirds of it: someone who has
# Docker installs one thing and has all three generators.
#
# rsync is installed here rather than with the rest: Pythia's install target copies with it, and adding it to
# the first layer would throw away the hour that Herwig and Sherpa took above.
RUN apt-get update && apt-get install -y --no-install-recommends rsync \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q -O pythia.tar.gz \
      "https://gitlab.com/Pythia8/releases/-/archive/pythia${PYTHIA_VERSION}/releases-pythia${PYTHIA_VERSION}.tar.gz" \
    && tar xzf pythia.tar.gz && rm pythia.tar.gz \
    && cd "releases-pythia${PYTHIA_VERSION}" \
    && ./configure --prefix="$PREFIX" \
    && make -j "$(nproc)" && make install \
    && cd .. && rm -rf "releases-pythia${PYTHIA_VERSION}" \
    && echo "https://gitlab.com/Pythia8/releases/-/archive/pythia${PYTHIA_VERSION}/releases-pythia${PYTHIA_VERSION}.tar.gz" \
       >> "$PREFIX/share/treelevel-mc/SOURCES.txt"

COPY Backends/pythia/main.cpp /tmp/treelevel-pythia.cpp
RUN g++ -O2 -std=c++17 /tmp/treelevel-pythia.cpp -o "$PREFIX/bin/treelevel-pythia" \
      -I"$PREFIX/include" -L"$PREFIX/lib" -lpythia8 -Wl,-rpath,"$PREFIX/lib" \
    && rm -f /tmp/treelevel-pythia.cpp

# WHIZARD, which computes its own matrix elements with O'Mega — hence OCaml. Three flags earn their place:
#
#   --disable-hepmc2   --enable-hepmc (that is HepMC3) and --enable-hepmc2 are BOTH on by default and HepMC2
#                      wins, so without this one believes it has HepMC3 and has not. WHIZARD then integrates,
#                      generates, showers and hadronises, and dies on the very last line — "HepMC3: Error:
#                      library not linked" — because the engine asks for sample_format = hepmc.
#   libtirpc-dev       configure looks for libtirpc through pkg-config; without it, it falls back silently on
#                      SunRPC headers Debian no longer ships, and contrib/mcfio dies half an hour later on
#                      rpc/types.h. Named explicitly rather than arriving by chance behind python3-dev.
#   --disable-lhapdf   it demands the cteq6l1 and CT10 sets, which the --lite bootstrap does not install.
#                      Of no consequence for the e+e- TreeLevel aims at; a choice, not an omission.
#
# FastJet is enabled because the prefix already holds it, so it costs nothing — though nothing in the Sindarin
# the engine writes clusters anything today.
ARG WHIZARD_VERSION=3.1.6
RUN apt-get update && apt-get install -y --no-install-recommends ocaml libtirpc-dev \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q "https://whizard.hepforge.org/downloads/?f=whizard-${WHIZARD_VERSION}.tar.gz" \
         -O "whizard-${WHIZARD_VERSION}.tar.gz" \
    && tar xzf "whizard-${WHIZARD_VERSION}.tar.gz" && rm "whizard-${WHIZARD_VERSION}.tar.gz" \
    && cd "whizard-${WHIZARD_VERSION}" \
    && ./configure --prefix="$PREFIX" \
         --enable-hepmc --with-hepmc="$PREFIX" --disable-hepmc2 \
         --enable-fastjet --with-fastjet="$PREFIX" \
         --disable-lhapdf \
    && make -j "$(nproc)" && make install \
    && cd .. && rm -rf "whizard-${WHIZARD_VERSION}" \
    && echo "https://whizard.hepforge.org/downloads/?f=whizard-${WHIZARD_VERSION}.tar.gz" \
       >> "$PREFIX/share/treelevel-mc/SOURCES.txt"

# WHIZARD installs one matrix-element compiler per model it knows — MSSM, NMSSM, UED, little Higgs, extra
# dimensions — sixty-one of them, 704 MB, a quarter of the image. The engine writes `model = SM` and nothing
# in TreeLevel offers another, so that one is kept, along with the generic omega3.opt which is not touched by
# the pattern. Deleting here rather than in the final stage is what makes the image smaller: only the state
# of this stage is copied, never its layers. Rebuilding without this line brings the others back.
RUN find "$PREFIX/bin" -name 'omega_*.opt' ! -name 'omega_SM.opt' -delete \
    && du -sh "$PREFIX/bin"

# CalcHEP: no patch, no flag — where macOS needed workarounds, Debian compiles the box as it comes. It must be
# built where it will live, its scripts carrying absolute paths, and it links -lX11 even in batch mode.
ARG CALCHEP_VERSION=3.9.2
RUN apt-get update && apt-get install -y --no-install-recommends libx11-dev \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q "https://theory.sinp.msu.ru/~pukhov/CALCHEP/calchep_${CALCHEP_VERSION}.tgz" \
    && tar xzf "calchep_${CALCHEP_VERSION}.tgz" && rm "calchep_${CALCHEP_VERSION}.tgz" \
    && mv "calchep_${CALCHEP_VERSION}" "$PREFIX/calchep" \
    && cd "$PREFIX/calchep" && make \
    && echo "https://theory.sinp.msu.ru/~pukhov/CALCHEP/calchep_${CALCHEP_VERSION}.tgz" \
       >> "$PREFIX/share/treelevel-mc/SOURCES.txt"

# The bootstrap leaves its unpacked trees behind, objects and all — ThePEG alone is 1.1 GB — and the COPY
# below would carry every one of them into the finished image, which is half its weight for nothing.
#
# The GPL asks for the corresponding source to be *available*, not embedded in the binary: it is, three times
# over, and none of the three goes away here — this Dockerfile is versioned and is the recipe itself,
# SOURCES.txt inside the image names every archive the build fetched, and the repository holds the engine.
RUN rm -rf "$PREFIX/src"

# --- the engine --------------------------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS engine
ARG TARGETARCH
WORKDIR /src
COPY win/treelevel-mc/ ./
RUN RID=$([ "$TARGETARCH" = "arm64" ] && echo linux-arm64 || echo linux-x64) \
    && dotnet publish -c Release -r "$RID" --self-contained true \
         -p:PublishSingleFile=true -o /out

# --- what ships --------------------------------------------------------------------------------------------
FROM debian:bookworm-slim
ENV PREFIX=/opt/treelevel-mc
ENV DEBIAN_FRONTEND=noninteractive

# What the generators need while they run. Two of them are not content with libraries: WHIZARD writes Fortran
# for each process and compiles it on the spot, CalcHEP does the same with C — so a compiler, make and the C
# headers stay in the finished image, which is unusual but is simply how these two work. libzip4 is Sherpa's,
# and libx11-6 is CalcHEP's, which links -lX11 even in batch mode.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgfortran5 libstdc++6 libgomp1 libgsl27 zlib1g libzip4 libsqlite3-0 python3-minimal ca-certificates \
      gcc gfortran make libc6-dev libx11-dev perl-modules-5.36 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hep    /opt/treelevel-mc /opt/treelevel-mc
COPY --from=engine /out/treelevel-mc /usr/local/bin/treelevel-mc

ENV PATH=$PREFIX/bin:$PATH \
    LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/ThePEG \
    HERWIGPATH=$PREFIX/share/Herwig \
    SHERPA_INCLUDE_PATH=$PREFIX/include/SHERPA-MC \
    SHERPA_SHARE_PATH=$PREFIX/share/SHERPA-MC \
    HOME=/root

# The engine asks the generators for their version through a login shell — which is what WSL needs, where the
# user's PATH lives in ~/.bashrc. But /etc/profile rewrites PATH from scratch, and ENV does not survive that:
# $PREFIX/bin vanished, and `capabilities` saw nothing but passthrough while `Herwig --version` answered
# perfectly. The environment therefore also lives where a login shell will read it.
COPY docker/profile.sh /etc/profile.d/treelevel-mc.sh

# The job folder is bind-mounted here; the engine writes its answers back into it.
WORKDIR /job
ENTRYPOINT ["/usr/local/bin/treelevel-mc"]
CMD ["capabilities"]

LABEL org.opencontainers.image.title="TreeLevel MC Engine" \
      org.opencontainers.image.description="Herwig 7 and Sherpa 3, ready to shower the events of TreeLevel" \
      org.opencontainers.image.source="https://github.com/gpasa/treelevel-mc-engine" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
