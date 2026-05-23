# AGENTS.md

Notes for AI coding agents (Claude Code, Cursor, etc.) and humans working
in this repo.

## What this repo is

`platzio/dev` is the **base repo for developing Platzio**. It carries the
Tilt orchestration, in-cluster manifests, seed charts, and shared editor /
agent config — everything needed to bring up a complete local Platzio
environment and to work across the multi-repo Platzio codebase from one
checkout.

This repo is the *conductor*, not the *destination*. It contains very
little Platzio code itself. The actual code lives in the sibling repos.

## Expected sibling-repo layout

```text
<workspace>/
├── dev/                       # this repo
├── backend/                   # Rust workspace: api, k8s-agent, chart-discovery,
│                              # status-updates, resource-sync, db, otel, auth
├── frontend/                  # Vue 3 + TypeScript SPA
├── helm-charts/               # the platzio helm chart deployed by Tilt
├── sdk-rs/                    # Rust SDK
├── sdk-js/                    # JS/TS SDK
├── chart-ext/                 # Helm chart extensions: values.ui.json, actions.json
├── cli/                       # platz CLI
├── docs/                      # user docs
├── site/                      # marketing / docs site
├── base-image/                # alpine base image used by backend release builds
├── design/                    # design assets
└── terraform-aws-platzio/     # AWS infra (out of scope for local dev)
```

Clone what you need under one parent directory. The Tilt setup only requires
`backend/`, `frontend/`, and `helm-charts/`; the rest are referenced by
`.claude/settings.json` so agents can read/edit them when relevant.

## Commits land in sibling repos

When working on Platzio from this repo, **expect to create commits in the
sibling repos**. A change to a backend crate is committed in `../backend`,
a frontend tweak in `../frontend`, a helm chart change in `../helm-charts`,
etc. The `dev/` repo itself only gets commits for changes to the local-dev
harness (Tilt, manifests, seed charts, agent config).

This is the intended workflow — it's not an error if a Claude session
running in `dev/` ends up `git commit`-ing across three repos.

## Bring-up

```bash
cd dev
tilt up
```

See [README.md](README.md) for prerequisites, ports, and credentials.

## Key files

* [`Tiltfile`](Tiltfile) — main orchestration. Sibling-repo paths are
  hard-coded (`../backend`, `../frontend`, `../helm-charts`).
* [`values.local.yaml`](values.local.yaml) — helm overrides layered on top
  of `../helm-charts/charts/platzio/values.yaml`. Defines local provider
  modes (k8s-agent `local`, chart-discovery `oci`), the in-cluster Postgres
  secret, the Dex OIDC secret, etc.
* [`manifests/`](manifests/) — Postgres, Dex (with static `admin@example.com`
  user), the OCI registry, and the `platz` namespace.
* [`kind-config.yaml`](kind-config.yaml) — single-node kind cluster mapping
  NodePort 30080 → host 8080 (frontend) and NodePort 30443 → host 8443.
* [`scripts/seed-charts.sh`](scripts/seed-charts.sh) — packages every chart
  under [`charts/`](charts/) and pushes it to the local registry. Tilt runs
  it automatically once `registry` is ready.

## Backend dev image

The backend's dev image is built from a `dev` target stage in
[`../backend/Dockerfile`](../backend/Dockerfile), not a separate dev
Dockerfile. That stage keeps the Rust toolchain + workspace source inside
the runtime image so Tilt's `live_update` can run `cargo build` inside the
running container after syncing edits. The default Docker build target
(no `--target`) still produces the static musl release image used in CI.

## Claude config

[`.claude/settings.json`](.claude/settings.json) is shared (committed). It:

* Adds the sibling repos to `additionalDirectories` so agents can read and
  edit code across `../backend`, `../frontend`, etc., without per-session prompts.
* Allows common Bash commands the local dev loop uses
  (`cargo check/clippy/test`, `helm template`, `kubectl get/describe`,
  `tilt *`, `docker buildx *`, `kind get clusters`).

Per-user overrides go in `.claude/settings.local.json`, which is gitignored.

`.claude/skills/` is reserved for project-specific Claude skills. Empty
placeholder for now; populate as workflows stabilize.
