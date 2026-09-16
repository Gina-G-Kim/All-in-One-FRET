#!/usr/bin/env bash
#
# This file plays three roles, depending on how and where it runs. They are kept in one file
# instead of three, since none of them share code but all of them are small, and splitting
# non-overlapping execution contexts into separate files added nothing but clutter:
#
# 1. Host-side CLI (default, no special argument or environment marker): what a user actually
#    runs, on their own machine, as `./fret.sh build|start|stop|...`. This is the only role that
#    runs outside a container; the other two only make sense once a container already exists, so
#    they run from a copy of this same file baked into the image (see the Dockerfile).
#
# 2. Container entrypoint (FRET_CONTAINER_ENTRYPOINT=1 in the environment, set only by the
#    Dockerfile, never on a host). Starts a virtual display, a lightweight window manager, and a
#    browser-facing VNC bridge, then launches FRET and waits on it. Every background process
#    started here is tracked and terminated on shutdown, so the container leaves nothing running
#    behind it whether it is stopped through `docker stop`, by quitting FRET from inside the GUI,
#    or by any other means. Runs exactly once, for the life of the container.
#
# 3. Analysis engine wrapper (invoked as `docker-entrypoint.sh --engine-wrap <real-binary> ...`
#    by the thin shims installed at /usr/local/bin/{jkind,jrealizability,kind2}). Solves two
#    problems for every JKind/Kind2 call FRET makes:
#      a. Concurrency. FRET's own diagnosis algorithm launches every pending analysis sub-query
#         at once with no concurrency limit of its own (DiagnosisEngine.js,
#         runEnginesAndGatherResults). On a large spec this can spawn far more concurrent
#         JVMs/processes than a commodity training laptop can handle. Serialized here through a
#         small counting semaphore (flock based), FRET_MAX_ENGINE_JOBS concurrent slots at a
#         time (default 2).
#      b. Reliability. JKind's realizability engine (specifically the jrealizability entry
#         point) occasionally hits a nondeterministic upstream Z3 crash inside its own
#         quantifier-elimination call ("Z3 terminated unexpectedly"); FRET's own realizability
#         manual documents this exact failure and recommends switching engines or retrying. The
#         identical query reliably succeeds when simply retried, so a nonzero exit is retried up
#         to FRET_JKIND_RETRY_ATTEMPTS times (default 3), but ONLY for jrealizability: Kind2's
#         exit code is itself a meaningful result (0 realizable, 30 unknown, 40 unrealizable, per
#         FRET's own realizabilityCheck.js), not an error signal, so retrying it on those
#         "nonzero but valid" codes would silently discard a correct result and waste a full
#         analysis re-run. Kind2 (and plain jkind, which FRET does not use for realizability at
#         all) always run exactly once. Runs once per engine invocation, potentially many times
#         over a container's lifetime, each a short-lived process distinct from the entrypoint's
#         own long-lived one.
#
# Usage (role 1):
#   ./fret.sh build [options]   Build the fret-lab Docker image
#   ./fret.sh start [options]   Start the container and open the FRET GUI in a browser
#   ./fret.sh stop                Stop the running container
#   ./fret.sh restart [options]  Stop, then start (options are passed through to start)
#   ./fret.sh status              Show whether the container is running
#   ./fret.sh logs                Follow the container's logs
#   ./fret.sh help                 Show usage
#
# Build options (optional analysis engines, all off by default, see FRET's installation guide).
# Builds are additive: a tool already in the current image stays there even if a later build
# does not name it again, so tools can be added one build at a time. "-all" always means
# "everything not installed yet". To drop a tool, remove the image first (docker rmi fret-lab).
#   --with-nusmv    Install NuSMV (used by the LTLSIM simulator)
#   --with-jkind    Install JKind (realizability checking engine)
#   --with-kind2    Install Kind2 (realizability checking engine)
#   --with-z3       Install Z3 (SMT solver used by realizability checking)
#   --with-aeval    Install AE-VAL (enables the "+ MBP" realizability engine variants; compiles
#                   its own Z3 from source, by far the slowest tool to add)
#   -all            Install every tool not already installed
#
# Start options:
#   --memory N      Cap the container's total memory at N whole GB via "docker run --memory"
#                    (default: 4). Also sizes JKind's JVM heap automatically: (N*1024 - 1536MB
#                    reserved for Electron/the GUI stack) divided across FRET_MAX_ENGINE_JOBS
#                    concurrent slots, floored at 512MB per slot. "--memory 0" removes the limit
#                    entirely. Set FRET_JKIND_HEAP_MB directly (see below) to bypass the
#                    auto-sizing and pick JKind's own heap by hand.
#
# Environment variables:
#   FRET_HOST            Host interface the GUI is published on (default: 127.0.0.1)
#   FRET_PORT            Host port the GUI is published on (default: 6080)
#   FRET_VERSION         FRET git tag to build (default: v3.1.0, only used by "build")
#   VNC_PASSWORD         Optional VNC password, recommended if FRET_HOST is not 127.0.0.1
#   FRET_MAX_ENGINE_JOBS Max concurrent JKind/Kind2 processes during realizability checking and
#                        diagnosis (default: 2). FRET's own diagnosis algorithm has no
#                        concurrency limit of its own and will otherwise try to launch one
#                        process per pending sub-query at once; the default is sized for
#                        commodity laptops, raise it only on machines with CPU and memory to
#                        spare.
#   FRET_JKIND_RETRY_ATTEMPTS  Retries for JKind's realizability engine (default: 3). It
#                        occasionally hits a nondeterministic upstream Z3 crash that a retry
#                        reliably resolves; this is unrelated to FRET_MAX_ENGINE_JOBS.
#   FRET_JKIND_HEAP_MB   JKind's JVM heap ceiling in MB (default: auto-derived from the
#                        "--memory" start option, see above). Rarely needs setting directly;
#                        prefer "--memory" unless you specifically need to tune JKind's own
#                        share independent of the container's overall limit.

set -euo pipefail

# ---------------------------------------------------------------------------
# Role 3: analysis engine wrapper. Checked first since it is identified by an explicit argument,
# regardless of environment.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--engine-wrap" ]; then
    shift
    # The logic below checks exit codes explicitly (a nonzero flock or real-binary exit is
    # routine, not fatal), which errexit would fight with, so it is switched off for this branch
    # only; the other two roles still run under -e.
    set +e

    REAL_BIN="$1"
    shift

    SLOTS="${FRET_MAX_ENGINE_JOBS:-2}"
    LOCK_DIR="/tmp/fret-engine-slots"
    mkdir -p "$LOCK_DIR"

    run_once_with_concurrency_limit() {
        while true; do
            for slot in $(seq 1 "$SLOTS"); do
                exec {fd}>"${LOCK_DIR}/${slot}.lock"
                if flock -n "$fd"; then
                    "$REAL_BIN" "$@"
                    local result=$?
                    # Release the slot before returning. This function is called again on retry
                    # within the same shell (no exec/process exit to reclaim the descriptor for
                    # us), so leaving it open here would permanently strand a slot after every
                    # attempt.
                    eval "exec ${fd}>&-"
                    return "$result"
                fi
                eval "exec ${fd}>&-"
            done
            sleep 0.5
        done
    }

    # Output is captured per attempt and only the final attempt's is emitted; letting every
    # failed attempt's stdout flow straight through would concatenate multiple result blocks and
    # break FRET's regex-based parsing of a single well-formed run.
    case "$(basename "$REAL_BIN")" in
        jrealizability-real) MAX_ATTEMPTS="${FRET_JKIND_RETRY_ATTEMPTS:-3}" ;;
        *) MAX_ATTEMPTS=1 ;;
    esac
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    attempt=1
    code=1
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        run_once_with_concurrency_limit "$@" > "$tmp"
        code=$?
        if [ "$code" -eq 0 ]; then
            break
        fi
        attempt=$((attempt + 1))
    done

    cat "$tmp"
    exit "$code"
fi

# ---------------------------------------------------------------------------
# Role 2: container entrypoint. Identified by an environment marker the Dockerfile sets, which
# is never present on a host.
# ---------------------------------------------------------------------------
if [ "${FRET_CONTAINER_ENTRYPOINT:-}" = "1" ]; then
    DISPLAY_NUM="${DISPLAY_NUM:-99}"
    export DISPLAY=":${DISPLAY_NUM}"
    RESOLUTION="${VNC_RESOLUTION:-1600x900x24}"
    VNC_PORT="${VNC_PORT:-5900}"
    NOVNC_PORT="${NOVNC_PORT:-6080}"
    FRET_HOME="/opt/fret"
    DOCS_DIR="${HOME}/Documents"

    CHILD_PIDS=""

    entrypoint_log() {
        echo "[fret-entrypoint] $*"
    }

    track() {
        CHILD_PIDS="${CHILD_PIDS} $1"
    }

    # Terminate every process started by this script, then exit. Registered for both termination
    # signals and normal script exit, so it runs the same way regardless of why the script is
    # ending.
    cleanup() {
        trap - TERM INT EXIT
        entrypoint_log "Shutting down."
        for pid in $CHILD_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        wait 2>/dev/null || true
    }
    trap cleanup TERM INT EXIT

    # Virtual framebuffer display. Everything else in this script renders into this display
    # instead of a physical one.
    Xvfb "$DISPLAY" -screen 0 "$RESOLUTION" -nolisten tcp -nolisten unix &
    track $!

    entrypoint_log "Waiting for the virtual display to become available."
    for _ in $(seq 1 50); do
        if [ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
            break
        fi
        sleep 0.2
    done

    # A blank fluxbox config: no root command, so fluxbox never shells out to fbsetbg to paint a
    # wallpaper image. Without this, fluxbox's default style triggers a background-image command
    # that fails (this image intentionally does not carry an image viewer for a cosmetic
    # wallpaper) and pops up an xmessage dialog on top of FRET's window.
    mkdir -p "${HOME}/.fluxbox"
    printf 'session.screen0.rootCommand:\n' > "${HOME}/.fluxbox/init"

    # Minimal window manager, so dialogs, resizing, and maximizing behave normally inside the
    # VNC session.
    fluxbox >/tmp/fluxbox.log 2>&1 &
    track $!

    # VNC server attached to the virtual display. A password is only enforced if VNC_PASSWORD is
    # provided, which matters mainly when the noVNC port is published beyond localhost.
    if [ -n "${VNC_PASSWORD:-}" ]; then
        mkdir -p /root/.vnc
        x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd
        x11vnc -display "$DISPLAY" -forever -shared -rfbport "$VNC_PORT" -rfbauth /root/.vnc/passwd -quiet &
    else
        x11vnc -display "$DISPLAY" -forever -shared -rfbport "$VNC_PORT" -nopw -quiet &
    fi
    track $!

    # Browser-facing noVNC bridge. This is what makes the GUI reachable the same way from
    # macOS, Linux, and Windows: a plain web browser pointed at this port, no X server or VNC
    # client needed on the host.
    websockify --web=/usr/share/novnc "$NOVNC_PORT" "localhost:${VNC_PORT}" >/tmp/websockify.log 2>&1 &
    track $!

    # FRET stores its requirements database at a fixed path under the home directory's
    # Documents folder (~/Documents/fret-db and ~/Documents/model-db). That folder does not
    # exist by default in this image, and FRET does not create missing parent directories
    # itself, so it must be prepared here before the application starts.
    mkdir -p "${DOCS_DIR}/fret-db" "${DOCS_DIR}/model-db"

    # FRET is launched by invoking the Electron binary directly (rather than "npm start") since
    # the runtime image does not carry Node.js or npm at all; only the already-built app and
    # the Electron runtime itself are present (see the Dockerfile's runtime stage for why). The
    # working directory and the relative app path deliberately match "npm start"'s own
    # invocation shape. --enable-logging routes the renderer's console (not just the main
    # process's) into this container's logs, which is what actually surfaces a blank-window
    # failure as a real error instead of a silent white screen.
    cd "${FRET_HOME}/fret-electron"
    export NODE_ENV=production
    ./node_modules/electron/dist/electron ./app/ --no-sandbox --disable-gpu --disable-dev-shm-usage --enable-logging=stderr &
    FRET_PID=$!
    track "$FRET_PID"

    # Projects (example case studies fetched into ./import on the host, or a trainee's own
    # files) are not imported automatically; FRET's own Import Project dialog (the down-arrow
    # icon in the left rail) is used to load one manually. /root/import shows up under Home.
    entrypoint_log "Place project JSON files in ./import on the host; they appear under /root/import (Home) for FRET's Import Project dialog."

    entrypoint_log "Optional analysis engines detected:"
    for tool in NuSMV z3 kind2 jkind jrealizability jlustre2kind aeval ltlsim; do
        if command -v "$tool" >/dev/null 2>&1; then
            entrypoint_log "  ${tool}: available"
        else
            entrypoint_log "  ${tool}: not installed (rebuild with the matching --with-* flag to add it)"
        fi
    done

    # JKind and Kind2 are launched through this same script in --engine-wrap mode (role 3
    # above), which caps how many of these run at the same time and retries jrealizability's
    # occasional nondeterministic Z3 crash automatically.
    entrypoint_log "Analysis engine concurrency limit: ${FRET_MAX_ENGINE_JOBS:-2} (override with -e FRET_MAX_ENGINE_JOBS=N)"
    entrypoint_log "JKind realizability retry attempts: ${FRET_JKIND_RETRY_ATTEMPTS:-3} (override with -e FRET_JKIND_RETRY_ATTEMPTS=N)"
    entrypoint_log "JKind JVM heap: ${FRET_JKIND_HEAP_MB:-1536}MB (set via FRET_MEMORY_GB or FRET_JKIND_HEAP_MB at './fret.sh start')"
    if [ -n "${FRET_MEMORY_GB:-}" ]; then
        entrypoint_log "Container memory limit: ${FRET_MEMORY_GB}GB"
    fi

    entrypoint_log "FRET is starting. View it at http://localhost:${NOVNC_PORT}/vnc.html"

    # Block until FRET exits, whether by normal quit, crash, or an external stop request, then
    # let the trap above tear down the rest of the session so the container does not linger.
    wait "$FRET_PID"
    exit 0
fi

# ---------------------------------------------------------------------------
# Role 1: host-side CLI. Falls through to here when neither role above matched.
# ---------------------------------------------------------------------------

IMAGE_NAME="fret-lab"
IMAGE_TAG="latest"
CONTAINER_NAME="fret-lab"
FRET_VERSION="${FRET_VERSION:-v3.1.0}"
FRET_HOST="${FRET_HOST:-127.0.0.1}"
FRET_PORT="${FRET_PORT:-6080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
IMPORT_DIR="${SCRIPT_DIR}/import"

log() {
    printf '[fret.sh] %s\n' "$*"
}

die() {
    printf '[fret.sh] error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: ./fret.sh <command>

Commands:
  build [options]   Build the fret-lab Docker image
  start [options]   Start the container and open the FRET GUI in a browser
  stop              Stop the running container
  restart [options] Stop, then start (options are passed through to start)
  status            Show whether the container is running
  logs              Follow the container's logs (Ctrl+C stops watching, container keeps running)
  help              Show this message

Build options (optional analysis engines, all off by default). Builds are additive: a tool
already in the current image stays there even if a later build does not name it again, so
tools can be added one build at a time. To drop a tool, remove the image first with:
docker rmi fret-lab
  --with-nusmv      Install NuSMV (used by the LTLSIM simulator)
  --with-jkind      Install JKind (realizability checking engine)
  --with-kind2      Install Kind2 (realizability checking engine)
  --with-z3         Install Z3 (SMT solver used by realizability checking)
  --with-aeval      Install AE-VAL (enables the "+ MBP" realizability engine variants; compiles
                    its own Z3 from source, by far the slowest tool to add)
  -all              Install every tool not already installed
Example: ./fret.sh build -all

Start options:
  --memory N        Cap the container's total memory at N whole GB (default: 4). JKind's JVM
                    heap is sized automatically from this. "--memory 0" removes the limit.
Example: ./fret.sh start --memory 8

The GUI is served over noVNC at http://${FRET_HOST}:${FRET_PORT}, viewable in any modern
browser on macOS, Linux, or Windows, with no additional software required. To import a project
(the official caseStudies examples, or one of your own), place its JSON file in ./import on the
host before starting the container; it shows up at /root/import inside the container, under
Home in FRET's Import dialog. Nothing is imported automatically. See README for how to fetch
the official example projects into ./import.

On native Windows, run this script from Git Bash or WSL. Both already come with Docker
Desktop's usual setup on Windows.

Environment variables: FRET_HOST, FRET_PORT, FRET_VERSION, VNC_PASSWORD, FRET_MAX_ENGINE_JOBS,
FRET_JKIND_RETRY_ATTEMPTS, FRET_JKIND_HEAP_MB (see top of script).
EOF
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "Docker is not installed or not on PATH. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux) first."
    fi
    if ! docker info >/dev/null 2>&1; then
        die "Docker is installed but not running. Start Docker Desktop (or the Docker daemon) and try again."
    fi
}

is_running() {
    [ -n "$(docker ps -q -f "name=^/${CONTAINER_NAME}$" 2>/dev/null)" ]
}

container_exists() {
    [ -n "$(docker ps -aq -f "name=^/${CONTAINER_NAME}$" 2>/dev/null)" ]
}

image_exists() {
    docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null 2>&1
}

open_browser() {
    local url="$1"
    case "$(uname -s)" in
        Darwin)
            open "$url" >/dev/null 2>&1 && return 0
            ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                # Running under WSL: hand off to the Windows host instead of xdg-open.
                cmd.exe /c start "$url" >/dev/null 2>&1 && return 0
                explorer.exe "$url" >/dev/null 2>&1 && return 0
            fi
            command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1 && return 0
            ;;
        MINGW*|MSYS*|CYGWIN*)
            start "$url" >/dev/null 2>&1 && return 0
            ;;
    esac
    return 1
}

# Reads back one of the fret.tool.* labels this same script stamps onto the image at the end of
# cmd_build, so a later build can tell which optional tools the current image already has.
# Prints nothing (not even an error) if the image or the label does not exist.
image_label() {
    local key="$1"
    docker image inspect --format "{{ index .Config.Labels \"${key}\" }}" "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null
}

cmd_build() {
    local install_nusmv=false
    local install_jkind=false
    local install_kind2=false
    local install_z3=false
    local install_aeval=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --with-nusmv) install_nusmv=true ;;
            --with-jkind) install_jkind=true ;;
            --with-kind2) install_kind2=true ;;
            --with-z3) install_z3=true ;;
            --with-aeval) install_aeval=true ;;
            -all|--all)
                install_nusmv=true
                install_jkind=true
                install_kind2=true
                install_z3=true
                install_aeval=true
                ;;
            *) die "Unknown build option: $1 (see: ./fret.sh help)" ;;
        esac
        shift
    done

    require_docker

    # Builds are additive: whatever optional tools the current image already carries stay in
    # the next one even if this call does not name them again, so tools can be added one build
    # at a time. "-all" always ends up meaning "everything not installed yet, install it now",
    # since a tool that is already on simply stays on.
    if image_exists; then
        [ "$(image_label fret.tool.nusmv)" = "true" ] && install_nusmv=true
        [ "$(image_label fret.tool.jkind)" = "true" ] && install_jkind=true
        [ "$(image_label fret.tool.kind2)" = "true" ] && install_kind2=true
        [ "$(image_label fret.tool.z3)" = "true" ] && install_z3=true
        [ "$(image_label fret.tool.aeval)" = "true" ] && install_aeval=true
    fi

    local extras=""
    [ "$install_nusmv" = "true" ] && extras="${extras} nusmv"
    [ "$install_jkind" = "true" ] && extras="${extras} jkind"
    [ "$install_kind2" = "true" ] && extras="${extras} kind2"
    [ "$install_z3" = "true" ] && extras="${extras} z3"
    [ "$install_aeval" = "true" ] && extras="${extras} aeval"
    if [ -n "$extras" ]; then
        log "Building ${IMAGE_NAME}:${IMAGE_TAG} from FRET ${FRET_VERSION}, with:${extras}. This compiles FRET from source and can take several minutes"
        [ "$install_aeval" = "true" ] && [ "$(image_label fret.tool.aeval)" != "true" ] && \
            log "aeval also compiles its own copy of Z3 from source; expect this build to take considerably longer than the others."
    else
        log "Building ${IMAGE_NAME}:${IMAGE_TAG} from FRET ${FRET_VERSION}. This compiles FRET from source and can take several minutes."
    fi

    docker build \
        --build-arg "FRET_VERSION=${FRET_VERSION}" \
        --build-arg "INSTALL_NUSMV=${install_nusmv}" \
        --build-arg "INSTALL_JKIND=${install_jkind}" \
        --build-arg "INSTALL_KIND2=${install_kind2}" \
        --build-arg "INSTALL_Z3=${install_z3}" \
        --build-arg "INSTALL_AEVAL=${install_aeval}" \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        "${SCRIPT_DIR}"
    log "Build complete: ${IMAGE_NAME}:${IMAGE_TAG}"
}

cmd_start() {
    local memory_gb="${FRET_MEMORY_GB:-4}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --memory)
                shift
                [ $# -gt 0 ] || die "--memory requires a value in GB (see: ./fret.sh help)"
                memory_gb="$1"
                ;;
            --memory=*)
                memory_gb="${1#--memory=}"
                ;;
            *) die "Unknown start option: $1 (see: ./fret.sh help)" ;;
        esac
        shift
    done

    require_docker

    if ! image_exists; then
        log "Image not found locally, building it first."
        cmd_build
    fi

    if is_running; then
        log "Already running."
    else
        if container_exists; then
            docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        fi

        mkdir -p "$DATA_DIR" "$IMPORT_DIR"

        log "Starting container ${CONTAINER_NAME}."
        local run_args=(
            -d --rm
            --name "${CONTAINER_NAME}"
            --shm-size=1g
            -p "${FRET_HOST}:${FRET_PORT}:6080"
            -v "${DATA_DIR}:/root/Documents"
            -v "${IMPORT_DIR}:/root/import"
        )
        if [ -n "${VNC_PASSWORD:-}" ]; then
            run_args+=(-e "VNC_PASSWORD=${VNC_PASSWORD}")
        fi
        if [ -n "${FRET_MAX_ENGINE_JOBS:-}" ]; then
            run_args+=(-e "FRET_MAX_ENGINE_JOBS=${FRET_MAX_ENGINE_JOBS}")
        fi
        if [ -n "${FRET_JKIND_RETRY_ATTEMPTS:-}" ]; then
            run_args+=(-e "FRET_JKIND_RETRY_ATTEMPTS=${FRET_JKIND_RETRY_ATTEMPTS}")
        fi
        # "--memory 0" (or FRET_MEMORY_GB=0) is the escape hatch for no limit at all; any other
        # value, including the default of 4, caps the container and is also handed to the
        # container's own environment so the entrypoint can log the effective setting.
        if [ "$memory_gb" != "0" ]; then
            run_args+=(--memory="${memory_gb}g" -e "FRET_MEMORY_GB=${memory_gb}")
        fi

        # Auto-derive JKind's heap from the container memory cap when the user has not picked
        # one directly: reserve headroom for Electron/the GUI stack, then split what is left
        # evenly across the concurrency limit, so a full set of concurrent JKind processes stays
        # within the container's own ceiling instead of overcommitting it.
        local jkind_heap_mb="${FRET_JKIND_HEAP_MB:-}"
        if [ -z "$jkind_heap_mb" ] && [ "$memory_gb" != "0" ]; then
            local jobs="${FRET_MAX_ENGINE_JOBS:-2}"
            local total_mb=$((memory_gb * 1024))
            local reserved_mb=1536
            local available_mb=$((total_mb - reserved_mb))
            if [ "$available_mb" -lt "$jobs" ]; then
                available_mb=$jobs
            fi
            jkind_heap_mb=$((available_mb / jobs))
            if [ "$jkind_heap_mb" -lt 512 ]; then
                jkind_heap_mb=512
            fi
        fi
        if [ -n "$jkind_heap_mb" ]; then
            run_args+=(-e "FRET_JKIND_HEAP_MB=${jkind_heap_mb}")
        fi

        docker run "${run_args[@]}" "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null

        log "Waiting for the GUI to become ready."
        local ready=0
        local i
        for i in $(seq 1 60); do
            if ! is_running; then
                die "Container stopped unexpectedly. Check logs with: ./fret.sh logs"
            fi
            if command -v curl >/dev/null 2>&1; then
                if curl -sf "http://${FRET_HOST}:${FRET_PORT}/" >/dev/null 2>&1; then
                    ready=1
                    break
                fi
            elif [ "$i" -ge 5 ]; then
                # No curl available on the host: give the container a few seconds and move on.
                ready=1
                break
            fi
            sleep 1
        done
        if [ "$ready" -ne 1 ]; then
            log "Warning: the GUI did not respond within 60 seconds. It may still be starting; check: ./fret.sh logs"
        fi
    fi

    local url="http://${FRET_HOST}:${FRET_PORT}/vnc.html?autoconnect=true&resize=scale"
    log "FRET GUI: ${url}"
    if ! open_browser "$url"; then
        log "Could not open a browser automatically. Open the URL above manually."
    fi
}

cmd_stop() {
    require_docker
    if ! container_exists; then
        log "Not running."
        return 0
    fi
    log "Stopping container ${CONTAINER_NAME}."
    docker stop -t 15 "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    # Container teardown (unmounting layers, releasing the network namespace) can briefly lag
    # behind the CLI call returning, so confirm removal actually finished instead of assuming it
    # did.
    local i
    for i in $(seq 1 10); do
        if ! container_exists; then
            log "Stopped."
            return 0
        fi
        sleep 1
    done
    die "Container did not fully stop. Check its state with: docker ps -a --filter name=${CONTAINER_NAME}"
}

cmd_restart() {
    cmd_stop
    cmd_start "$@"
}

cmd_status() {
    require_docker
    if is_running; then
        docker ps -f "name=^/${CONTAINER_NAME}$"
    else
        log "Not running."
    fi
}

cmd_logs() {
    require_docker
    container_exists || die "No container found. Start it first with: ./fret.sh start"
    docker logs -f "${CONTAINER_NAME}"
}

on_interrupt() {
    log "Interrupted."
    exit 130
}
trap on_interrupt INT TERM

main() {
    local command="${1:-help}"
    [ $# -gt 0 ] && shift

    case "$command" in
        build) cmd_build "$@" ;;
        start) cmd_start "$@" ;;
        stop) cmd_stop ;;
        restart) cmd_restart "$@" ;;
        status) cmd_status ;;
        logs) cmd_logs ;;
        help|-h|--help) usage ;;
        *)
            usage
            die "Unknown command: ${command}"
            ;;
    esac
}

main "$@"
