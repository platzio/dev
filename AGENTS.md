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
├── sdk-py/                    # Python SDK
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

## Per-repo workflow conventions

Most sibling repos accept the standard flow: commit, push a feature
branch, open a PR. A few have stricter rules.

### `../site` — PR-only, publish-on-merge

`platzio/site` is the public Docusaurus site published at
<https://platz.io>. **Always open a PR; never push to `main`.** `main` is
protected, and merging a PR triggers the publish workflow. Direct pushes
to `main` are rejected and would skip the review step.

When updating `../site`:

- Branch off `origin/main`, commit changes there.
- `git push -u origin <branch>` and `gh pr create --base main`.
- Wait for review before merging.
- **Run `npm run format` before committing.** The site repo has prettier
  set up; markdown tables and other formatting must be prettier-clean.
  CI runs `npm run format:check` and rejects non-conforming PRs. See
  [[feedback-markdown-formatting]] for the full rule.

### Cross-repo safety

- Never commit absolute filesystem paths from the user's machine
  (`/Users/...`, `/home/...`) — see [[feedback-no-absolute-paths]].
  Use workspace-relative paths only (`../backend`, `../frontend`, …).
- Never run `gh auth ...` subcommands — see [[feedback-no-gh-auth]].

## Versioning across repos

The Platzio release is identified by a single version line (e.g. `0.7.0`).
The umbrella artifacts — the `helm-charts` chart and the backend / frontend
release images — carry the full pre-release version during a beta
(`0.7.0-beta.1`).

Sub-packages track the **same minor version** as the release they ship
with. They split into two groups on the pre-release (`-beta.N`) marker:

* `chart-ext` and `design` drop it — prefer the plain version. So while
  the release is `0.7.0-beta.1`, these should be `0.7.0`, not `0.6.x` and
  not `0.7.0-beta.1`.
* The SDKs (`sdk-rs`, `sdk-js`, `sdk-py`) carry the **full** release
  version, pre-release marker included, so a consumer can pin the SDK to
  the exact backend version (e.g. sdk-js ships `0.7.0-beta.2`). `sdk-py`
  publishes the PEP 440 spelling of that — `0.7.0-beta.3` → `0.7.0b3`.

When bumping the release minor, bump every sub-package's `version`
(`Cargo.toml` / `package.json` / `pyproject.toml`, plus the lockfile
entry) to match. Don't
let them drift behind (e.g. `design` stuck at `0.6.0` while the rest moved
to `0.7.x`). The `release-version` skill handles this during a release;
keep it in mind for any standalone version edits too.

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

[`.claude/skills/`](.claude/skills/) carries project-specific Claude
skills. Currently:

* [`release-version`](.claude/skills/release-version/SKILL.md) — cuts a
  Platzio release across all sibling repos (backend → frontend →
  base-image → helm-charts → terraform → site). Triggered when the user
  asks to release a version.
