---
name: upgrade-dependencies
description: |
  Upgrade all dependencies across the Platzio repos. Use when the user
  says any of: "upgrade dependencies", "upgrade all deps", "bump
  dependencies", "update dependencies", "upgrade the GitHub Actions",
  "upgrade base images", "dependency refresh", "are we on the latest
  versions". Walks every source repo's third-party dependencies (Rust
  crates, npm packages, Python deps, Docker base images, GitHub Actions,
  Terraform providers), keeps cross-repo shared versions aligned (e.g.
  design→frontend bootstrap), and verifies each upgrade builds. Does
  *not* cut a release — that's the release-version skill.
---

# Upgrade Platzio dependencies

This skill is about **third-party** dependencies — the crates, npm
packages, Python wheels, base images, Actions, and Terraform providers
the Platzio repos pull from the outside world. It keeps them current and
proves each repo still builds.

It is deliberately **not** about the internal `platz-*` version pins
(`platz-chart-ext`, `@platzio/sdk`, the chart's image tags, the Terraform
`chart_version`). Those move only when we *release*, and the
[`release-version`](../release-version/SKILL.md) skill owns them. Keep the
two jobs separate: this skill never bumps an internal pin, and the release
skill never chases upstream versions.

The one place the two overlap is **shared third-party libraries** that
appear in more than one repo (bootstrap, axios, typescript, the common
Rust crates). Those must be upgraded *together* so a build output from one
repo doesn't clash with its consumer. That coupling is the heart of this
skill — see [[The upgrade dependency graph]].

## Two kinds of repo

Sort every repo into one of two buckets before touching anything. Only the
first bucket is in scope for a dependency upgrade.

### Source repos — own their third-party deps (in scope)

These carry real dependency manifests and a build/test you can run to
verify an upgrade:

| Repo         | Ecosystem        | Manifest(s)                          | Verify with                         |
| ------------ | ---------------- | ------------------------------------ | ----------------------------------- |
| `backend`    | Rust (workspace) | per-crate `Cargo.toml` + `[workspace.dependencies]` in root; `Cargo.lock` | `cargo clippy --release -- -D warnings && cargo test --release` |
| `chart-ext`  | Rust             | `Cargo.toml`, `Cargo.lock`           | `cargo hack clippy --feature-powerset` + `cargo hack test --feature-powerset` |
| `sdk-rs`     | Rust             | `Cargo.toml`, `Cargo.lock`           | `cargo clippy -- -D warnings && cargo build` |
| `frontend`   | Node (Vue/Vite)  | `package.json`, `package-lock.json`, `.nvmrc` | `npm ci && npm run build && npm run lint` |
| `design`     | Node (lib)       | `package.json`                       | no build of its own — verify by building `frontend` against it (see [[design → frontend]]) |
| `sdk-js`     | Node (tooling)   | `package.json`                       | `npm install && npm run build` (src is generated; only tooling deps upgrade here) |
| `site`       | Node (Docusaurus)| `package.json`, `package-lock.json`  | `npm ci && npm run build && npm run typecheck && npm run format:check` |
| `sdk-py`     | Python           | `pyproject.toml`                     | regenerate + build via `uv` (package is generated; only declared deps upgrade here) |
| `base-image` | Docker only      | `Dockerfile` (no lockfile)           | `docker build` + smoke-test the tools (`helm`, `kubectl`, `aws`, `bash`) |
| `dev`        | local-dev harness| `Tiltfile`, `manifests/*.yaml`, `kind-config.yaml` — pinned image tags | `tilt up` against a kind cluster, or at least `helm template` / `kubectl apply --dry-run` |

Every repo above **also** has GitHub Actions to upgrade (see [[GitHub
Actions]]) and most have a Dockerfile base image (see [[Docker base
images]]).

### Derivative repos — version pins we release (mostly out of scope)

These are downstream of the release process. Their *primary* version
numbers are **ours**, set by the release-version skill, and you must
**not** touch them here:

- `helm-charts` — `values.yaml` image tags (`platzio/frontend`,
  `platzio/backend`, `platzio/base`) and `Chart.yaml` `version` /
  `appVersion` are release-managed. Leave them alone.
- `terraform-aws-platzio` — `chart_version` default and the `?ref=v...`
  README links are release-managed. Leave them alone.

**But** each of these two has a small number of *genuine third-party*
dependencies that this skill **does** cover:

- `helm-charts` → a non-Platzio sidecar image, e.g.
  `popen2/postgres-backup-s3` in `values.yaml`. Upgrade like any other
  pinned image (see [[Docker base images]]).
- `terraform-aws-platzio` → provider version constraints in
  `modules/*/provider*.tf` (`hashicorp/aws ~> 6.0`, `hashicorp/kubernetes
  ~> 2.0`, `hashicorp/helm ~> 3.0`) and any third-party Terraform module
  pins (e.g. a `database.tf` module `version = "..."`). See [[Terraform]].

So the rule is: in a derivative repo, upgrade **only** the external pins,
never the Platzio version pins.

## The upgrade dependency graph

A dependency upgrade isn't contained to one repo any more than a release
is. Three kinds of edge force you to upgrade repos together and in order.

### Build-output edges (upstream must be upgraded first)

#### design → frontend

`frontend` consumes `design` directly from git
(`"@platzio/design": "github:platzio/design"` — it tracks `design`'s
`main`, not a published version). Both repos independently pin
**`bootstrap`** (e.g. both at `^5.3.8`), and `design` owns the Font Awesome
stack (`@fortawesome/*`), `@popperjs/core`, and the web-fonts packages that
the frontend renders against.

If `design` and `frontend` disagree on the bootstrap major/minor, the
frontend renders against a different CSS than the components were authored
for. **Upgrade `design` first, then bump `frontend` to the same bootstrap
version in the same pass, then build the frontend** to prove the pair
agrees. Never bump bootstrap in only one of the two.

#### chart-ext → backend, sdk-rs

`chart-ext` publishes the `platz-chart-ext` crate, which both `backend`
(`[workspace.dependencies.platz-chart-ext]`) and `sdk-rs` depend on. The
*version pin* there is release-managed (don't touch it). What this skill
**does** own is the **third-party crates `chart-ext` shares** with its
consumers — `serde`, `reqwest`, `strum`, `thiserror`, `uuid`, `url`,
`rust_decimal`, `utoipa`, `tokio`, `anyhow`. If you bump one of those in
`backend` or `sdk-rs`, bump it in `chart-ext` to the same major so the
shared crate doesn't drag a conflicting transitive version into its
consumers' lockfiles. Upgrade `chart-ext`'s shared crates first, then the
consumers.

#### backend (OpenAPI) → sdk-js, sdk-py, sdk-rs

The SDKs' *source* is generated from the backend's OpenAPI schema, so their
runtime surface is release-driven, not upgrade-driven. For this skill the
SDKs only have **tooling/runtime** deps to bump: `sdk-js`'s `tsup` +
`typescript`, `sdk-py`'s `httpx` / `attrs` / `python-dateutil` and its
codegen (`openapi-python-client`), `sdk-rs`'s hand-maintained crate deps.
No build-output edge to honor here beyond keeping shared libs aligned
(below).

### Shared-library edges (upgrade in lockstep, any order)

Some third-party libraries live in multiple repos and should move together:

- **bootstrap** — `design` + `frontend` (see [[design → frontend]]).
- **axios** — `frontend` (dependency) + `sdk-js` (`peerDependencies`).
  Keep the same major; the frontend's installed axios must satisfy the
  SDK's peer range.
- **typescript** — `frontend`, `sdk-js`, `site` (and anything else on TS).
  Bump together to avoid one repo's `.d.ts` output being unparseable by
  another's compiler.
- **prettier / eslint** — `frontend` and `site` share the formatter; a
  prettier major can reflow files and trip `format:check`.
- **Common Rust crates** — `serde`, `reqwest`, `tokio`, `strum`,
  `thiserror`, `uuid`, `url`, `rust_decimal`, `utoipa`, `chrono`, `anyhow`
  across `backend`, `chart-ext`, `sdk-rs`. Align majors (see [[chart-ext →
  backend, sdk-rs]]).

### Toolchain edges (keep the runtime consistent)

- **Node** — `frontend/.nvmrc` (`24`), `frontend` `engines.node` (`^24`),
  the `node:24-alpine` stage in `frontend/Dockerfile`, and `site`
  `engines.node` must agree on a major. Bump them together when you move
  Node.
- **Rust** — `backend/Dockerfile`'s `RUST_IMAGE=rust:1-trixie` is the build
  toolchain; the crates' `edition` (`2021` for `chart-ext`, `2024` for
  `backend`/`sdk-rs`) gates the minimum compiler. Don't raise an `edition`
  past what the pinned Rust image supports.
- **Python** — `sdk-py` `requires-python` and its classifiers list the
  supported interpreters; keep them in step with what the release workflow
  (`astral-sh/setup-uv`) actually runs.

## How to find new versions

There is **no Dependabot or Renovate** in any repo — upgrades are manual.
Here's how to discover what's behind, per ecosystem.

### Rust (`backend`, `chart-ext`, `sdk-rs`)

```bash
cd ../<repo>
# Patch/minor within existing semver ranges — refreshes Cargo.lock only:
cargo update --dry-run
# Crates that have a newer release than the manifest's caret allows
# (needs cargo-edit / cargo-outdated; install if missing):
cargo outdated -R           # or: cargo upgrade --dry-run --incompatible
```

`cargo update` moves the lockfile within the `Cargo.toml` ranges; bumping a
crate to a new **major** means editing the version in `Cargo.toml` (the
per-crate `[dependencies]` for backend members, the root
`[workspace.dependencies]` for the shared ones) and then `cargo build`.

### Node (`frontend`, `design`, `sdk-js`, `site`)

```bash
cd ../<repo>
npm outdated                # shows current / wanted / latest per package
# To stage the bumps into package.json (needs npm-check-updates):
npx npm-check-updates       # preview
npx npm-check-updates -u    # write new ranges into package.json, then npm install
```

`npm outdated`'s **wanted** column is what `npm update` would take within
the existing caret; **latest** is the true newest (often a major bump that
needs a manifest edit). `design` has no lockfile — just edit
`package.json`.

### Python (`sdk-py`)

`sdk-py` declares ranges in `pyproject.toml` (`httpx>=0.23,<0.29`,
`attrs>=22.2.0`, `python-dateutil>=2.8.0`) and builds with `uv`/hatchling.
Check PyPI for newer releases and widen/raise the ranges by hand:

```bash
cd ../sdk-py
uv pip list --outdated        # against a synced venv, if present
```

Also track the codegen tool (`openapi-python-client`) used by
`generate-sdk.sh`.

### Docker base images (`base-image`, `backend`, `frontend`, `dev`)

Pinned base images and their newest tags as of this writing:

| File                      | Image                 | Notes                                    |
| ------------------------- | --------------------- | ---------------------------------------- |
| `base-image/Dockerfile`   | `alpine:3.23`         | plus unpinned apk pkgs: aws-cli, helm, kubectl, bash |
| `backend/Dockerfile`      | `rust:1-trixie`, `${BASE_IMAGE}` | `rust:1-trixie` is a rolling 1.x tag |
| `frontend/Dockerfile`     | `node:24-alpine`, `nginx:1-alpine-slim` | node major tracks `.nvmrc` |
| `dev/manifests/*.yaml`    | `postgres:17-alpine`, `dexidp/dex:v2.41.1`, `registry:2` | local-dev only |

Find newer tags on Docker Hub (or `docker pull <image>:<tag>` and compare
digests). For pinned majors like `node:24`, decide whether to move the
major (and if so, ripple it through the [[toolchain edges]]); for
floating tags like `rust:1-trixie` the upgrade is just rebuilding.

### GitHub Actions

Used across the repos and currently **inconsistent** — part of this skill
is normalizing them to one version each:

```bash
# from the workspace root, see every action and the versions in play:
grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9._/-]+@[A-Za-z0-9._-]+' \
  */.github/workflows/ | sed 's/uses:[[:space:]]*//' | sort | uniq -c
```

As of this writing the mixed ones are `actions/checkout@v4|v5|v6`,
`docker/setup-buildx-action@v3|v4`, `docker/login-action@v3|v4`,
`docker/build-push-action@v6|v7`. Pick the newest each repo's CI tolerates
and align every workflow to it. Look up each action's latest release on its
GitHub releases page. Flag any `@master`/`@main` float (e.g.
`ShubhamTatvamasi/free-disk-space-action@master`) — unpinned third-party
actions are a supply-chain risk; propose pinning to a tag or SHA.

### Terraform (`terraform-aws-platzio`)

```bash
cd ../terraform-aws-platzio
terraform init -upgrade        # pulls newest providers within constraints
```

Provider **constraints** live in `modules/*/provider*.tf` (`hashicorp/aws
~> 6.0`, `hashicorp/kubernetes ~> 2.0`, `hashicorp/helm ~> 3.0`). Raising a
constraint major is a manual edit; check the Terraform Registry for the
newest provider majors and any third-party module versions (e.g. the RDS
module pinned in `database.tf`). Remember: the chart_version is
release-managed — don't touch it.

## How to verify an upgrade went fine

Run each repo's own gate (the `Verify with` column in [[Source repos]]),
which mirrors what its CI runs. The minimum bar per repo:

- **Rust** — `cargo clippy --release -- -D warnings` (warnings are errors
  in CI) **and** `cargo test --release`. For `chart-ext` use the
  feature-powerset form (`cargo hack ... --feature-powerset`) since its CI
  tests every feature combination. Stage the refreshed `Cargo.lock`
  alongside any `Cargo.toml` edit — they must never drift.
- **frontend** — `npm ci && npm run build` (build includes `vue-tsc`
  type-check) **and** `npm run lint`. A green build here is also the proof
  for a `design` upgrade (see [[design → frontend]]).
- **sdk-js** — `npm install && npm run build` (tsup must still emit
  `dist/`).
- **site** — `npm ci && npm run build && npm run typecheck && npm run
  format:check`. A prettier bump that reflows files will fail
  `format:check` — run `npm run format` and commit the reflow if so.
- **sdk-py** — re-run `generate-sdk.sh` against a backend `openapi.yaml`
  and `uv build`; confirm the two known benign codegen warnings are the
  only ones.
- **base-image** — `docker build` the image, then run it and confirm
  `helm version`, `kubectl version --client`, `aws --version`, and `bash`
  all work (the apk packages are unpinned, so a rebuild can move them).
- **dev** — bring the harness up (`tilt up` on a kind cluster) far enough
  that the pods using any bumped manifest image (`postgres`, `dex`,
  `registry`) go ready; at minimum `kubectl apply --dry-run=server` the
  manifests and `helm template` the chart.
- **terraform** — `terraform init -upgrade && terraform validate`, and a
  `terraform plan` against the upgraded providers to catch removed/renamed
  arguments.
- **helm-charts** — `helm lint charts/platzio` and `helm template
  charts/platzio` after an external-image bump.

For **cross-repo** edges, the verification is the *downstream* build:
after a `design` bump, the real test is `frontend`'s `npm run build`; after
a shared-crate bump in `chart-ext`, it's `backend` and `sdk-rs` compiling
against it.

If a gate fails, fix forward in the same pass — adjust call sites for a
renamed API, regenerate a lockfile, reflow formatting — rather than pinning
back to the old version, unless the upstream change is genuinely breaking
and not worth absorbing now (note those and surface them to the user).

## Recommended order

Walk the graph upstream-first so each consumer is verified against
already-upgraded outputs:

1. **`chart-ext`** — bump its third-party crates (and Actions, base image
   if any), verify with the feature-powerset gate.
2. **`backend`** and **`sdk-rs`** — `cargo update` + manual major bumps;
   align the [[shared-library edges|shared Rust crates]] with what
   `chart-ext` now uses; verify each.
3. **`design`** — bump bootstrap / fontawesome / fonts; no build of its
   own.
4. **`frontend`** — match `design`'s bootstrap, bump the rest of
   `package.json` (keep axios/typescript aligned with `sdk-js`), `npm ci &&
   npm run build && npm run lint`.
5. **`sdk-js`** — bump tsup/typescript (align typescript with `frontend`),
   build.
6. **`sdk-py`** — widen dep ranges, bump codegen, regenerate + `uv build`.
7. **`site`** — bump Docusaurus + prettier/typescript, build + typecheck +
   format:check.
8. **`base-image`** — bump `alpine`, rebuild, smoke-test the tools.
9. **`dev`** — bump manifest image tags (`postgres`, `dex`, `registry`,
   `kindest/node` if set), bring the harness up.
10. **`terraform-aws-platzio`** — raise provider/module constraints (never
    the chart_version), `init -upgrade` + `validate` + `plan`.
11. **`helm-charts`** — bump only external sidecar images, `helm lint` +
    `template`.
12. **GitHub Actions across all repos** — normalize to one version each;
    this can be done per-repo as you touch it, or as a final sweep.

## Committing and pushing

Commit per repo with a clear message (e.g. `Upgrade dependencies`,
`Bump bootstrap to 5.x across design + frontend`,
`Normalize GitHub Actions versions`). Push each repo's work to its
designated feature branch (see the session's branch instructions) — do
**not** push to `main`, and remember `../site` is **PR-only** (branch +
PR, run `npm run format` first; see AGENTS.md). Open PRs only if the user
asks.

Keep coupled changes in one logical commit where it aids review — e.g. the
bootstrap bump in `design` and `frontend` can each be its own commit but
should reference each other in the message so the pair is obvious.

## Checklist (copy into the conversation when starting)

```
- [ ] Sort repos: source (in scope) vs derivative (external pins only)
- [ ] chart-ext: cargo outdated → bump crates + Actions + base image; cargo hack feature-powerset clippy+test
- [ ] backend: cargo update + major bumps; align shared crates w/ chart-ext; clippy --release -D warnings + test --release
- [ ] sdk-rs: cargo update + bumps; align shared crates; clippy -D warnings + build
- [ ] design: bump bootstrap/fontawesome/fonts (no build of its own)
- [ ] frontend: match design's bootstrap; bump pkgs (axios/typescript aligned w/ sdk-js); npm ci && build && lint
- [ ] sdk-js: bump tsup/typescript (align w/ frontend); npm install && build
- [ ] sdk-py: widen dep ranges + codegen; regenerate + uv build
- [ ] site: bump docusaurus/prettier/typescript; build + typecheck + format:check (PR-only repo!)
- [ ] base-image: bump alpine; docker build; smoke-test helm/kubectl/aws/bash
- [ ] dev: bump manifest image tags (postgres/dex/registry/kindest); tilt up / dry-run
- [ ] terraform: raise provider+module constraints (NOT chart_version); init -upgrade + validate + plan
- [ ] helm-charts: bump external sidecar images only (NOT platzio image tags); helm lint + template
- [ ] GitHub Actions: normalize checkout/buildx/login/build-push to one version each; flag @master pins
- [ ] Verify every repo's CI gate passes; fix forward
- [ ] Commit per repo to the feature branch; site via PR; don't touch release-managed pins
```
