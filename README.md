# codex-workspace-emulator

`codex-workspace-emulator` is a local replica of the base image used by OpenAI Codex workspaces. It keeps the language toolchain layout that ships with the public `ghcr.io/openai/codex-universal` image, but lets you build and run everything locally via Docker Compose. The project now mirrors the key Codex workspace constraints:

- Every container is built from a local image (`codex-workspace-emulator:latest`).
- Only files tracked by git (HEAD) are copied into the container at runtime.
- Setup scripts can optionally pre-warm and reuse a cached image layer.
- All outbound traffic must use the bundled MITM proxy and HTTPS; WebSockets and direct connections are blocked.

## Prerequisites

- Docker 24.0+ with the Compose plugin.
- Access to the repository whose `.git` directory you want to emulate.
- GNU coreutils (for `realpath`) or Python 3 (the launcher falls back to `python3`).

## Quick start

```bash
./scripts/run-workspace.sh /path/to/your/repo
```

What happens:

1. The script builds `codex-workspace-emulator:latest` if needed (`docker compose build workspace`).
2. It launches the embedded `mitmproxy` service and the `workspace` container.
3. Only tracked files from `HEAD` are materialised inside `/workspace/project`.
4. If `codex-workspace-scripts/setup-script.sh` exists, the script runs inside an isolated container. If it finishes successfully and `setup-from-cache-script.sh` is present, a snapshot is committed to `codex-workspace-emulator:cached` and replayed in a second container to exercise the cached path.
5. When neither setup script is present, you drop into an interactive Bash shell with the Codex runtime configuration pre-applied.

The script accepts an optional path; by default it uses the current working directory.

## Repository projection

- Only the `.git` directory from the host is mounted (read-only).
- The entrypoint clones HEAD into `/workspace/project` by copying `.git` and running `git reset --hard HEAD`.
- Submodules are synced and updated recursively (unless `CODEX_SKIP_SUBMODULES=1`).
- Changes inside the container do not affect your host checkout or `.git` data.

This mirrors the Codex workspace behaviour where the workspace always starts from a clean commit snapshot.

## Setup scripts contract

If the project root contains `codex-workspace-scripts/`:

- `setup-script.sh` is **required** and is executed in a fresh container. Use it to build caches, download dependencies, and mutate the image.
- `setup-from-cache-script.sh` is **optional**. When present, the launcher saves the container state after `setup-script.sh` (`docker commit codex-workspace-emulator:cached`) and then runs this second script from the cached image to mimic the "cache hit" path.
- When setup scripts exist, the containers run to completion and exit; you do not get an interactive shell by default.

All output from both scripts is streamed to your terminal. Any non-zero exit from either script stops the workflow and preserves the relevant logs.

## Networking & proxy restrictions

The Docker Compose stack defines two services:

- `proxy`: Runs `mitmdump` with a codified policy that only allows HTTPS traffic and rejects WebSocket upgrades. It owns a shared volume containing the generated CA certificate.
- `workspace` / `workspace-cache`: Run the Codex image. They are attached only to an internal Docker network and can reach the Internet exclusively through the `proxy` container.

The workspace containers export the same proxy-related environment variables used in Codex (e.g. `HTTP_PROXY=http://proxy:8080`, `NO_PROXY=localhost,127.0.0.1,::1`, `NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/envoy-mitmproxy-ca-cert.crt`). On startup, the entrypoint waits for the proxy CA certificate, installs it into the system trust store, and sets `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `PIP_CERT`, and related variables.

Because the containers live on an internal-only network, any attempt to bypass the proxy is blocked. The proxy script also rejects WebSocket (`wss`) traffic so that only HTTPS requests succeed.

## Running services manually

You can interact with docker-compose directly if you prefer:

```bash
export HOST_REPO=$(pwd)
export HOST_REPO_NAME=$(basename "$HOST_REPO")

# Build the base image
docker compose build workspace

# Interactive shell without setup scripts
docker compose run --rm workspace

# Run setup scripts explicitly
docker compose run --name codex-setup workspace run-setup
docker commit codex-setup codex-workspace-emulator:cached
docker rm codex-setup
docker compose run --rm workspace-cache run-setup-from-cache

# Stop auxiliary services
docker compose down --remove-orphans
```

The `scripts/run-workspace.sh` helper wraps the lifecycle above, including container cleanup and cache management.

### Self-test project

To verify the emulator end-to-end, run the bundled smoke test:

```bash
./tests/run-example-tests.sh
```

It bootstraps a throwaway git repository under `tests/example-project`, executes both setup phases, and asserts that:
- only tracked files appear inside the workspace
- HTTPS succeeds via the proxy while HTTP, websocket upgrades, and direct connections fail
- cache snapshots persist state between `setup-script.sh` and `setup-from-cache-script.sh`

## Environment configuration

The entrypoint exports the following defaults on container start (all overridable through Compose or the launcher):

| Variable | Default |
| -------- | ------- |
| `CODEX_ENV_PYTHON_VERSION` | `3.12` |
| `CODEX_ENV_NODE_VERSION` | `20` |
| `CODEX_ENV_RUST_VERSION` | `1.89.0` |
| `CODEX_ENV_GO_VERSION` | `1.24.3` |
| `CODEX_ENV_SWIFT_VERSION` | `6.1` |
| `CODEX_ENV_RUBY_VERSION` | `3.4.4` |
| `CODEX_ENV_PHP_VERSION` | `8.4` |
| `CODEX_ENV_BUN_VERSION` | `1.2.14` |
| `CODEX_ENV_JAVA_VERSION` | `21` |

Adjust these via `docker compose run -e CODEX_ENV_NODE_VERSION=22 workspace …` or by editing `docker-compose.yml`.

## Troubleshooting

- **"HOST_REPO is not set"** – Export `HOST_REPO` (and optionally `HOST_REPO_NAME`) before using `docker compose run`, or always use `./scripts/run-workspace.sh`.
- **Missing mitmproxy certificate** – Ensure the `proxy` service stays healthy; the workspace waits up to 30 seconds for the certificate volume to be populated.
- **Setup script failures** – The helper exits on the first non-zero status. Fix the script locally and rerun; the cached image is only updated after a successful run.
- **Need to skip submodules** – Run with `CODEX_SKIP_SUBMODULES=1 ./scripts/run-workspace.sh` to avoid initializing them.

## License

This project inherits the original licensing information in [LICENSES](LICENSES).
