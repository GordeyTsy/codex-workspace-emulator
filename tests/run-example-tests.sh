#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="${ROOT_DIR}/tests/example-project"

log() {
    printf '[tests] %s\n' "$*"
}

ensure_example_repo() {
    log "Resetting example repository snapshot"
    rm -rf "${EXAMPLE_DIR}/.git"
    git -C "${EXAMPLE_DIR}" init >/dev/null
    git -C "${EXAMPLE_DIR}" config user.email "codex@example.com"
    git -C "${EXAMPLE_DIR}" config user.name "Codex Example"
    git -C "${EXAMPLE_DIR}" add README.md tracked.txt src codex-workspace-scripts .gitignore
    git -C "${EXAMPLE_DIR}" commit -m "Update example project snapshot" >/dev/null
}

prepare_untracked_file() {
    echo "This file should never appear inside the container" > "${EXAMPLE_DIR}/untracked.txt"
}

cleanup_cached_image() {
    if docker image inspect codex-workspace-emulator:cached >/dev/null 2>&1; then
        log "Removing existing cached image"
        docker image rm -f codex-workspace-emulator:cached >/dev/null
    fi
}

run_workspace() {
    log "Running codex workspace emulator against example project"
    CODEX_SKIP_SUBMODULES=1 "${ROOT_DIR}/scripts/run-workspace.sh" "${EXAMPLE_DIR}"
}

main() {
    ensure_example_repo
    prepare_untracked_file
    cleanup_cached_image
    run_workspace
    log "All tests completed successfully"
}

main "$@"
