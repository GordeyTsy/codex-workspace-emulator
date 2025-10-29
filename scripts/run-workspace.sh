#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

if [ ! -f "${COMPOSE_FILE}" ]; then
    echo "docker-compose.yml not found at ${COMPOSE_FILE}" >&2
    exit 1
fi

resolve_path() {
    if command -v realpath >/dev/null 2>&1; then
        realpath "$1"
    else
        python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
    fi
}

REPO_PATH="${1:-$(pwd)}"
REPO_PATH="$(resolve_path "${REPO_PATH}")"

if [ ! -d "${REPO_PATH}/.git" ]; then
    echo "The provided path (${REPO_PATH}) does not contain a .git directory." >&2
    exit 1
fi

export HOST_REPO="${REPO_PATH}"
export HOST_REPO_NAME="${HOST_REPO_NAME:-$(basename "${REPO_PATH}")}"

compose() {
    docker compose --project-name codex-workspace --file "${COMPOSE_FILE}" "$@"
}

cleanup() {
    compose down --remove-orphans >/dev/null 2>&1 || true
}

COMPLETED_CACHE_STEP=false

run_with_cache() {
    local container_name="codex-workspace-setup-$(date +%s)"
    if ! compose run --name "${container_name}" workspace run-setup; then
        local status=$?
        docker rm -f "${container_name}" >/dev/null 2>&1 || true
        return "${status}"
    fi

    docker commit "${container_name}" codex-workspace-emulator:cached >/dev/null
    docker rm "${container_name}" >/dev/null
    COMPLETED_CACHE_STEP=true
}

run_from_cache() {
    compose run --rm workspace-cache run-setup-from-cache
}

main() {
    trap cleanup EXIT

    compose build workspace

    local scripts_dir="${REPO_PATH}/codex-workspace-scripts"
    local setup_script="${scripts_dir}/setup-script.sh"
    local cache_script="${scripts_dir}/setup-from-cache-script.sh"

    if [ ! -d "${scripts_dir}" ]; then
        compose run --rm workspace
        return
    fi

    if [ ! -f "${setup_script}" ]; then
        echo "codex-workspace-scripts detected but setup-script.sh is missing." >&2
        exit 1
    fi

    run_with_cache

    if [ "${COMPLETED_CACHE_STEP}" != "true" ]; then
        exit 1
    fi

    if [ -f "${cache_script}" ]; then
        run_from_cache
    fi
}

main "$@"
