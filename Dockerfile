# FRET (Formal Requirements Elicitation Tool) training image.
#
# Builds NASA's FRET desktop application from source, then packages only the built application
# (not the build toolchain) into a minimal runtime image. The GUI is exposed over noVNC (Xvfb +
# x11vnc + websockify), reachable from any browser on macOS, Linux, or Windows with nothing else
# installed on the host.
#
# Official install reference:
# https://github.com/NASA-SW-VnV/fret/blob/master/fret-electron/docs/_media/installingFRET/installationInstructions.md

# ---------------------------------------------------------------------------
# Stage 1: build FRET from source.
#
# Everything in this stage (compilers, Node.js, the full devDependency tree used only to bundle
# the app) is discarded after the build; none of it reaches the final image.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ARG FRET_VERSION=v3.1.0
ARG NODE_VERSION=20.19.0
ARG NVM_VERSION=v0.40.2

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/root \
    NVM_DIR=/root/.nvm \
    NODE_VERSION=${NODE_VERSION}

SHELL ["/bin/bash", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        python3 \
        python-is-python3 \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Node.js, installed with nvm at the exact version the FRET installation guide demonstrates.
# Pinning to this version keeps the build inside FRET's documented supported range
# (v16.16.x - v20.19.x) instead of trusting whatever "latest 20.x" resolves to later.
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash \
    && . "${NVM_DIR}/nvm.sh" \
    && nvm install "${NODE_VERSION}" \
    && nvm alias default "${NODE_VERSION}"
ENV PATH="${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:${PATH}"

# FRET source, pinned to a tagged release for a reproducible training image. fret-electron is a
# subfolder of the full repository, so the whole thing is cloned even though only that subfolder
# is actually built. caseStudies/ (also part of this clone) is deliberately not carried into the
# runtime image below; trainees fetch it themselves into the host-side ./import folder instead
# (see README), which keeps the image itself independent of any particular set of example
# projects and lets trainees re-sync examples without rebuilding.
RUN git clone --branch "${FRET_VERSION}" --depth 1 https://github.com/NASA-SW-VnV/fret.git /opt/fret

WORKDIR /opt/fret/fret-electron

RUN npm run fret-install

ARG INSTALL_AEVAL=false

# AE-VAL: SMT solver for forall-exists formulas, needed by the "JKind + MBP" and "Kind 2 + MBP"
# realizability checking engines. No prebuilt binaries are published, so it is compiled from
# source, and its own build compiles a full copy of Z3 (pinned to 4.8.10) internally first,
# which makes this by far the slowest optional tool to add. Built here, in the stage that
# already has a full compiler toolchain, rather than in the runtime stage, so the runtime image
# never needs one just for this. A placeholder file is written when this is off so the runtime
# stage's COPY below always has something to copy.
RUN mkdir -p /opt/aeval-bin \
    && if [ "$INSTALL_AEVAL" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends \
            cmake libboost-dev libboost-system-dev libgmp-dev bison python3-setuptools \
        && rm -rf /var/lib/apt/lists/* \
        && git clone --depth 1 https://github.com/grigoryfedyukovich/aeval.git /tmp/aeval-src \
        && mkdir /tmp/aeval-src/build \
        && cd /tmp/aeval-src/build \
        && cmake .. \
        && make \
        && make \
        && cp tools/aeval/aeval /opt/aeval-bin/aeval \
        && cd / \
        && rm -rf /tmp/aeval-src; \
    else \
        touch /opt/aeval-bin/aeval; \
    fi

# ---------------------------------------------------------------------------
# Stage 2: runtime image.
#
# Only the files actually needed to run the already-built app are copied in below: the packaged
# renderer/main bundle plus its own runtime node_modules (app/), the Electron binary itself
# (node_modules/electron, ~250MB, the only thing still needed from the outer devDependency
# tree), ltlsim-core and fret-electron/support (the targets of symlinks reached from inside
# app/node_modules, verified with a full recursive symlink audit so nothing else is missing),
# and the example projects. The outer node_modules (~1.4GB of webpack/babel/eslint/jest and
# friends, needed only to build the app, never to run it) is left behind in the builder stage.
# FRET is launched by invoking the Electron binary directly instead of through "npm start", so
# neither Node.js nor npm needs to be installed here at all.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS runtime

ARG INSTALL_NUSMV=false
ARG INSTALL_JKIND=false
ARG INSTALL_KIND2=false
ARG INSTALL_Z3=false
ARG INSTALL_AEVAL=false
ARG NUSMV_VERSION=2.7.1
ARG KIND2_VERSION=3.0.0
ARG JKIND_VERSION=2.2

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/root

SHELL ["/bin/bash", "-c"]

# Electron/Chromium runtime libraries: this is the set the FRET installation guide documents for
# Ubuntu 24.04+ (libgtk-3-0t64 through libasound2t64), plus the handful of additional X11/GL
# libraries Chromium needs when rendering into a virtual framebuffer (Xvfb) instead of a real
# desktop session. fonts-liberation and fonts-dejavu-core (Latin-only) are what FRET's own guide
# expects; fonts-nanum is added on top since this image is distributed to Korean-speaking
# trainees who type Hangul into requirement descriptions and variable mappings, and neither of
# the other two font packages has Hangul glyphs at all (missing glyphs render as blank/broken
# text, not just wrong-looking text). fluxbox is the window manager for the session; tini is
# PID 1 for correct signal handling and zombie reaping.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        libgtk-3-0t64 \
        libdrm2 \
        libgbm1 \
        libnss3 \
        libx11-xcb1 \
        libasound2t64 \
        libxss1 \
        libxtst6 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libcups2 \
        libxrandr2 \
        libxdamage1 \
        libxcomposite1 \
        libxfixes3 \
        fonts-liberation \
        fonts-dejavu-core \
        fonts-nanum \
        xvfb \
        fluxbox \
        x11vnc \
        novnc \
        websockify \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Optional analysis engines for FRET's realizability checking, LTL simulation, and test
# generation features. FRET's own installation guide marks all four as optional, so none of
# them are installed by default; each is enabled individually, or all at once with "-all",
# through a fret.sh build flag (see fret.sh for the exact flags).

# fret.sh itself becomes the container's entrypoint here: it plays three roles depending on how
# it is invoked (host CLI / container entrypoint / analysis-engine wrapper), selected by an
# argument or environment marker rather than by being three separate files — see its own
# top-of-file comment for the full rationale. FRET_CONTAINER_ENTRYPOINT=1 (set once, below)
# selects the entrypoint role for a plain invocation with no arguments, which is how the
# ENTRYPOINT instruction at the bottom of this file calls it; the thin wrapper scripts generated
# in the optional-engine blocks below call the same file with "--engine-wrap" instead, which
# takes priority regardless of this environment marker. Installed early (ahead of those blocks)
# since they need this file to already exist on disk to generate wrappers that reference it.
COPY fret.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENV FRET_CONTAINER_ENTRYPOINT=1

# Z3: SMT solver used by realizability checking. Ubuntu's packaged build is used directly
# rather than pinning a release asset, since FRET's guide does not require a specific version.
RUN if [ "$INSTALL_Z3" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends z3 \
        && rm -rf /var/lib/apt/lists/* \
        && (z3 --version || true); \
    fi

# NuSMV: model checker used by the LTLSIM simulator. The official binary is linked against an
# older libedit soname than Ubuntu 24.04 ships. The two are ABI-compatible for the functions
# NuSMV actually calls, confirmed by running a real model-checking pass, not just checking that
# the binary loads, so a symlink is sufficient and a from-source build is not needed.
RUN if [ "$INSTALL_NUSMV" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends libxml2 libedit2 xz-utils \
        && rm -rf /var/lib/apt/lists/* \
        && ln -s /usr/lib/x86_64-linux-gnu/libedit.so.2 /usr/lib/x86_64-linux-gnu/libedit.so.0 \
        && curl -fsSL -o /tmp/nusmv.tar.xz "https://nusmv.fbk.eu/distrib/${NUSMV_VERSION}/NuSMV-${NUSMV_VERSION}-linux64.tar.xz" \
        && tar -xJf /tmp/nusmv.tar.xz -C /opt \
        && cp /opt/NuSMV-${NUSMV_VERSION}-linux64/bin/* /usr/local/bin/ \
        && rm -rf /tmp/nusmv.tar.xz "/opt/NuSMV-${NUSMV_VERSION}-linux64" \
        && (NuSMV -help >/dev/null || true); \
    fi

# Kind2: model checker used by realizability checking (statically linked, no extra runtime
# libraries needed). FRET's docs list v2.2.0 as the latest known-supported version and v2.3.0 as
# explicitly unsupported; the pinned default here is a later release that this image's own
# realizability and diagnosis testing confirmed working end to end (FRET's Kind2 integration
# code already tracks Kind2's exit-code and CLI changes through at least v2.2.0, and no
# regressions were observed against v3.0.0). The real binary is kept out of PATH under /opt/kind2
# and /usr/local/bin/kind2 is a thin wrapper that runs it through docker-entrypoint.sh's
# --engine-wrap mode, so FRET can never launch more concurrent Kind2 processes than the
# configured limit.
RUN if [ "$INSTALL_KIND2" = "true" ]; then \
        mkdir -p /opt/kind2 \
        && curl -fsSL -o /tmp/kind2.tar.gz "https://github.com/kind2-mc/kind2/releases/download/v${KIND2_VERSION}/kind2-v${KIND2_VERSION}-linux-x86_64.tar.gz" \
        && tar -xzf /tmp/kind2.tar.gz -C /opt/kind2 \
        && chmod +x /opt/kind2/kind2 \
        && rm -f /tmp/kind2.tar.gz \
        && printf '#!/bin/bash\nexec /usr/local/bin/docker-entrypoint.sh --engine-wrap /opt/kind2/kind2 "$@"\n' > /usr/local/bin/kind2 \
        && chmod +x /usr/local/bin/kind2 \
        && (/opt/kind2/kind2 --version || true); \
    fi

# JKind: model checker used by realizability checking, an alternative engine to Kind2. FRET's
# realizability pipeline calls the separate "jrealizability" entry point (not "jkind" itself)
# for this feature, so both wrappers are installed alongside the shared jkind.jar; jlustre2kind
# is also installed for parity with FRET's own install instructions, which list it alongside the
# other three, even though FRET's own GUI does not call it directly. Needs a JRE, which is only
# pulled in when JKind is actually requested. As with Kind2 above, the downloaded scripts are
# kept out of PATH under /opt/jkind/*-real; both /usr/local/bin/jkind and jrealizability are thin
# wrappers through docker-entrypoint.sh's --engine-wrap mode, which also retries jrealizability
# automatically since it is the one confirmed to occasionally hit a nondeterministic upstream Z3
# crash (documented in FRET's own realizability manual). The realizability path's heap ceiling,
# upstream default 3g, is rewritten to a shell parameter expansion reading FRET_JKIND_HEAP_MB at
# container runtime (not a value baked in at build time), so the training laptop's actual
# available memory (via FRET_MEMORY_GB, see fret.sh) decides the ceiling instead of a one-size
# guess; 1536 is only the fallback when neither is set.
RUN if [ "$INSTALL_JKIND" = "true" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends default-jre-headless \
        && rm -rf /var/lib/apt/lists/* \
        && mkdir -p /opt/jkind \
        && curl -fsSL -o /opt/jkind/jkind.jar "https://github.com/andreaskatis/jkind-1/releases/download/v${JKIND_VERSION}/jkind.jar" \
        && curl -fsSL -o /opt/jkind/jkind-real "https://github.com/andreaskatis/jkind-1/releases/download/v${JKIND_VERSION}/jkind" \
        && curl -fsSL -o /opt/jkind/jrealizability-real "https://github.com/andreaskatis/jkind-1/releases/download/v${JKIND_VERSION}/jrealizability" \
        && curl -fsSL -o /usr/local/bin/jlustre2kind "https://github.com/andreaskatis/jkind-1/releases/download/v${JKIND_VERSION}/jlustre2kind" \
        && chmod +x /opt/jkind/jkind-real /opt/jkind/jrealizability-real /usr/local/bin/jlustre2kind \
        && sed -i 's/-Xmx3g/-Xmx${FRET_JKIND_HEAP_MB:-1536}m/' /opt/jkind/jrealizability-real \
        && printf '#!/bin/bash\nexec /usr/local/bin/docker-entrypoint.sh --engine-wrap /opt/jkind/jkind-real "$@"\n' > /usr/local/bin/jkind \
        && printf '#!/bin/bash\nexec /usr/local/bin/docker-entrypoint.sh --engine-wrap /opt/jkind/jrealizability-real "$@"\n' > /usr/local/bin/jrealizability \
        && chmod +x /usr/local/bin/jkind /usr/local/bin/jrealizability \
        && (java -jar /opt/jkind/jkind.jar >/dev/null || true); \
    fi

# The built application, copied in piece by piece (see the stage comment above for why). The
# three small node_modules packages below (antlr4, encoding with its own nested iconv-lite, and
# safer-buffer, a little over 1MB combined) are dependencies that fret-electron/support reaches
# via Node's normal upward node_modules search rather than through app/node_modules; the full
# list was captured by strace-ing a real run end to end rather than guessed, since main.prod.js
# gives no static hint of them (they are not webpack-bundled).
#
# fret-electron/docs is not just static documentation: the renderer bundle references it directly
# at runtime via relative paths ("../docs/_media/..."), for the per-requirement "SEMANTIC DIAGRAM"
# image shown in the requirement editor/display dialog (one of ~460 static template SVGs under
# docs/_media/user-interface/examples/svgDiagrams, selected per FRETish pattern), the FRETish
# grammar reference opened from the UI, and screenshots embedded in in-app help (the Realizability/
# Test Case Generation HELP buttons render FRET's own manual docs). Missing this folder does not
# produce any error a user would notice as a crash; the requirement dialog just silently shows a
# broken image icon where the diagram should be, and other help/reference views fail similarly
# quietly. Confirmed by grepping the actual runtime renderer bundle for "../docs/" rather than
# guessing from the source tree.
COPY --from=builder /opt/fret/fret-electron/app /opt/fret/fret-electron/app
COPY --from=builder /opt/fret/fret-electron/node_modules/electron /opt/fret/fret-electron/node_modules/electron
COPY --from=builder /opt/fret/fret-electron/node_modules/antlr4 /opt/fret/fret-electron/node_modules/antlr4
COPY --from=builder /opt/fret/fret-electron/node_modules/encoding /opt/fret/fret-electron/node_modules/encoding
COPY --from=builder /opt/fret/fret-electron/node_modules/safer-buffer /opt/fret/fret-electron/node_modules/safer-buffer
COPY --from=builder /opt/fret/fret-electron/support /opt/fret/fret-electron/support
COPY --from=builder /opt/fret/fret-electron/docs /opt/fret/fret-electron/docs
COPY --from=builder /opt/fret/tools/LTLSIM/ltlsim-core /opt/fret/tools/LTLSIM/ltlsim-core

# FRET's own install docs require adding ltlsim-core/simulator to PATH: it is what the LTLSIM
# window (standalone, "Simulate" on a diagnosed conflict, "Simulate Realizable Requirements",
# and "Simulate Generated Tests" in test case generation) actually launches. The ltlsim binary
# itself is already built by "npm run fret-install" in the builder stage above; only the missing
# PATH entry needs fixing here. Unconditional, since ltlsim-core is always copied in regardless
# of which optional engines are installed (LTLSIM still needs NuSMV to fully function, per
# FRET's docs, but the binary should be reachable either way).
RUN ln -s /opt/fret/tools/LTLSIM/ltlsim-core/simulator/ltlsim /usr/local/bin/ltlsim

# AE-VAL was built (or, if not requested, stood in for by an empty placeholder) in the builder
# stage; here it is either activated or discarded, matching every other optional tool's on/off
# switch.
COPY --from=builder /opt/aeval-bin/aeval /usr/local/bin/aeval
RUN if [ "$INSTALL_AEVAL" = "true" ]; then \
        chmod +x /usr/local/bin/aeval \
        && (/usr/local/bin/aeval --help >/dev/null 2>&1 || true); \
    else \
        rm -f /usr/local/bin/aeval; \
    fi

# Records which optional tools this image was built with, so fret.sh can read them back and
# carry them forward into the next build without the caller having to repeat every flag.
LABEL fret.tool.nusmv="${INSTALL_NUSMV}" \
      fret.tool.jkind="${INSTALL_JKIND}" \
      fret.tool.kind2="${INSTALL_KIND2}" \
      fret.tool.z3="${INSTALL_Z3}" \
      fret.tool.aeval="${INSTALL_AEVAL}"

EXPOSE 6080

HEALTHCHECK --interval=10s --timeout=5s --start-period=45s --retries=6 \
    CMD curl -sf http://127.0.0.1:6080/ >/dev/null || exit 1

# tini runs as PID 1 so Electron and Chromium's child processes are reaped correctly and
# termination signals from `docker stop` reach the entrypoint script instead of being lost.
ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
