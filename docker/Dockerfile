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
      zlib1g-dev libgsl-dev libboost-dev \
      cmake libsqlite3-dev wget ca-certificates \
    && ln -sf /usr/bin/cython3 /usr/local/bin/cython \
    && rm -rf /var/lib/apt/lists/*

# Herwig's own bootstrap builds the whole stack it needs — ThePEG, FastJet, LHAPDF, HepMC3 — into one prefix.
# --lite leaves out the loop libraries (VBFNLO, MadGraph, LoopTools): TreeLevel provides the hard process, so
# nothing here computes loops. The log keeps every URL it fetched, which is what the GPL asks us to publish.
RUN wget -q https://herwig.hepforge.org/downloads/herwig-bootstrap \
    && chmod +x herwig-bootstrap \
    && python3 ./herwig-bootstrap --lite -j "$(nproc)" "$PREFIX" 2>&1 | tee /tmp/bootstrap.log \
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

# Only what the two generators load at run time; the compilers stay in the builder stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgfortran5 libstdc++6 libgomp1 libgsl27 zlib1g libsqlite3-0 python3-minimal ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hep    /opt/treelevel-mc /opt/treelevel-mc
COPY --from=engine /out/treelevel-mc /usr/local/bin/treelevel-mc

ENV PATH=$PREFIX/bin:$PATH \
    LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/ThePEG \
    HERWIGPATH=$PREFIX/share/Herwig \
    SHERPA_INCLUDE_PATH=$PREFIX/include/SHERPA-MC \
    SHERPA_SHARE_PATH=$PREFIX/share/SHERPA-MC

# The job folder is bind-mounted here; the engine writes its answers back into it.
WORKDIR /job
ENTRYPOINT ["/usr/local/bin/treelevel-mc"]
CMD ["capabilities"]

LABEL org.opencontainers.image.title="TreeLevel MC Engine" \
      org.opencontainers.image.description="Herwig 7 and Sherpa 3, ready to shower the events of TreeLevel" \
      org.opencontainers.image.source="https://github.com/gpasa/treelevel-mc-engine" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
