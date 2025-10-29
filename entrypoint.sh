#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=${WORKSPACE_ROOT:-/workspace/project}
HOST_GIT_SOURCE=${HOST_GIT_SOURCE:-/host/.git}
HOST_REPO_NAME=${HOST_REPO_NAME:-project}
MITM_SHARED_DIR=${MITM_SHARED_DIR:-/mitmproxy}
CERT_DESTINATION=${PROXY_CERT_PATH:-/usr/local/share/ca-certificates/envoy-mitmproxy-ca-cert.crt}
MITM_CERT_TIMEOUT=${MITM_CERT_TIMEOUT:-30}

log() {
    printf '[codex-workspace] %s\n' "$*" >&2
}

abort() {
    log "ERROR: $*"
    exit 1
}

find_mitm_certificate() {
    local candidate
    for candidate in \
        "${MITM_SHARED_DIR}/mitmproxy-ca-cert.pem" \
        "${MITM_SHARED_DIR}/mitmproxy-ca.pem" \
        "${MITM_SHARED_DIR}/mitmproxy-ca-cert.cer" \
        "${MITM_SHARED_DIR}/mitmproxy-ca-cert.crt"
    do
        if [ -f "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

prepare_certificate() {
    if [ ! -d "${MITM_SHARED_DIR}" ]; then
        abort "Shared mitmproxy volume (${MITM_SHARED_DIR}) is not mounted."
    fi

    local waited=0
    local cert_source=""

    while [ "${waited}" -lt "${MITM_CERT_TIMEOUT}" ]; do
        if cert_source=$(find_mitm_certificate); then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ -z "${cert_source}" ]; then
        abort "Timed out waiting (${MITM_CERT_TIMEOUT}s) for mitmproxy CA certificate in ${MITM_SHARED_DIR}."
    fi

    install -d "$(dirname "${CERT_DESTINATION}")"
    cp "${cert_source}" "${CERT_DESTINATION}"
    chmod 0644 "${CERT_DESTINATION}"

    if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null
    else
        log "Skipping update-ca-certificates (utility not found); continuing."
    fi

    export CODEX_PROXY_CERT="${CERT_DESTINATION}"
    export SSL_CERT_FILE="${CERT_DESTINATION}"
    export REQUESTS_CA_BUNDLE="${CERT_DESTINATION}"
    export PIP_CERT="${CERT_DESTINATION}"
    export NODE_EXTRA_CA_CERTS="${CERT_DESTINATION}"
    export npm_config_https_proxy="${HTTPS_PROXY:-http://proxy:8080}"
    export npm_config_http_proxy="${HTTP_PROXY:-http://proxy:8080}"
    export YARN_HTTPS_PROXY="${HTTPS_PROXY:-http://proxy:8080}"
    export YARN_HTTP_PROXY="${HTTP_PROXY:-http://proxy:8080}"
}

sync_repository() {
    if [ ! -d "${HOST_GIT_SOURCE}" ]; then
        abort "Expected .git directory at ${HOST_GIT_SOURCE}; ensure HOST_REPO is configured correctly."
    fi

    log "Syncing tracked files from ${HOST_REPO_NAME} (HEAD)."

    local project_parent project_name
    project_parent=$(dirname "${PROJECT_ROOT}")
    project_name=$(basename "${PROJECT_ROOT}")
    mkdir -p "${project_parent}"
    cd "${project_parent}"
    rm -rf "${project_name}"
    mkdir -p "${project_name}/.git"

    rsync -a --delete "${HOST_GIT_SOURCE}/" "${PROJECT_ROOT}/.git/"

    git --git-dir="${PROJECT_ROOT}/.git" config --local core.worktree "${PROJECT_ROOT}"
    git config --global --add safe.directory "${PROJECT_ROOT}" >/dev/null 2>&1 || true

    git --git-dir="${PROJECT_ROOT}/.git" --work-tree="${PROJECT_ROOT}" reset --hard HEAD >/dev/null
    git --git-dir="${PROJECT_ROOT}/.git" --work-tree="${PROJECT_ROOT}" clean -ffd >/dev/null

    if [ "${CODEX_SKIP_SUBMODULES:-0}" != "1" ] && [ -f "${PROJECT_ROOT}/.gitmodules" ]; then
        git --git-dir="${PROJECT_ROOT}/.git" --work-tree="${PROJECT_ROOT}" submodule sync --recursive >/dev/null
        git --git-dir="${PROJECT_ROOT}/.git" --work-tree="${PROJECT_ROOT}" submodule update --init --recursive >/dev/null
    fi
    cd "${PROJECT_ROOT}"
}

prepare_workspace() {
    log "Preparing codex workspace at ${PROJECT_ROOT}."
    prepare_certificate
    sync_repository
    /opt/codex/setup_universal.sh
}

run_script() {
    local script_path=$1
    local label=$2

    if [ ! -f "${script_path}" ]; then
        abort "Required ${label} (${script_path}) not found."
    fi

    log "Running ${label}."
    if [ -x "${script_path}" ]; then
        "${script_path}"
    else
        bash "${script_path}"
    fi
}

run_setup_phase() {
    local scripts_dir="${PROJECT_ROOT}/codex-workspace-scripts"
    local setup_script="${scripts_dir}/setup-script.sh"
    local cache_script="${scripts_dir}/setup-from-cache-script.sh"
    local phase=$1

    if [ ! -d "${scripts_dir}" ]; then
        abort "codex-workspace-scripts directory not found in repository (required for phase ${phase})."
    fi

    case "${phase}" in
        setup)
            run_script "${setup_script}" "setup-script.sh"
            ;;
        setup-from-cache)
            if [ ! -f "${cache_script}" ]; then
                abort "setup-from-cache-script.sh not found, but phase setup-from-cache requested."
            fi
            run_script "${cache_script}" "setup-from-cache-script.sh"
            ;;
        *)
            abort "Unknown setup phase '${phase}'."
            ;;
    esac

    log "Completed ${phase} phase."
}

main() {
    local command="${1:-}"
    if [ -n "${command}" ]; then
        shift || true
    fi

    log "Starting codex-workspace-emulator."
    prepare_workspace

    case "${command}" in
        run-setup)
            run_setup_phase "setup"
            exit 0
            ;;
        run-setup-from-cache)
            run_setup_phase "setup-from-cache"
            exit 0
            ;;
        "" )
            log "Environment ready. Dropping into interactive shell."
            exec bash --login
            ;;
        *)
            log "Environment ready. Executing custom command: ${command} $*"
            exec "${command}" "$@"
            ;;
    esac
}

main "$@"
