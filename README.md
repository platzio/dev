# Platzio Local Development

This repo is the development harness for [Platzio](https://github.com/platzio).
It carries the Tilt orchestration, in-cluster manifests (Postgres, Dex,
container registry), seed charts, and Claude config for working across the
full set of Platzio repos from one place.

Cloning the sibling repos under the same parent directory and running
`tilt up` from here is enough to bring up a complete, self-contained local
Platzio environment. No AWS account required.

## Prerequisites

* `docker`
* [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
* `kubectl`
* `helm` (3.8+ for OCI support)
* `tilt`
* `node` + `npm` (for the frontend)
* Rust toolchain (for editor support; the backend itself builds inside the dev image)

## Sibling repos

The Tiltfile reaches `../backend`, `../frontend`, and `../helm-charts`, so
clone them next to this repo:

```text
<workspace>/
├── dev/             # this repo
├── backend/         # github.com/platzio/backend
├── frontend/        # github.com/platzio/frontend
└── helm-charts/     # github.com/platzio/helm-charts
```

Other Platzio repos (`sdk-rs`, `sdk-js`, `chart-ext`, `cli`, `docs`, `site`,
etc.) aren't required for the local stack but are expected as siblings if
you'll be working on them — `.claude/settings.json` references them.

## One-shot start

```bash
cd dev
tilt up
```

That brings up:

* a kind cluster `platz-local`
* an in-cluster Postgres, Dex (OIDC), and an OCI chart registry — see [manifests/](manifests/)
* the five backend workers, built from `../backend` via the `dev` target stage in [`../backend/Dockerfile`](../backend/Dockerfile)
* the frontend, built from `../frontend`

Tilt's UI (<http://localhost:10350>) shows logs and reload status per service.
Stop with `Ctrl-C` or `tilt down`.

## Forwarded ports

* `8080` — frontend (browser → kind NodePort)
* `3000` — API server (port-forward)
* `5001` — local OCI registry (port-forward)
* `15432` — Postgres (port-forward)

## Default credentials

Dex is provisioned with one user — `admin@example.com` / `password` (configured
in [manifests/dex.yaml](manifests/dex.yaml)).

## Live reload

* **Backend.** Tilt syncs source into the dev image and re-runs `cargo build`
  inside the container, then restarts the binary. The first build is slow;
  subsequent rebuilds use the warm `/build/target` cargo cache baked into
  the dev image.
* **Frontend.** Tilt re-runs `npm run build` on every source change and syncs
  the `dist/` directory into the running nginx pod. No HMR; reload time is
  bounded by vite's build. For HMR-style frontend dev against the local
  backend, run `npm run serve` directly in `../frontend` — it proxies
  `/api` calls to the API server on `localhost:3000`.

## Switching between EKS and Local mode

The Tilt setup wires the workers in local-only mode through
[values.local.yaml](values.local.yaml). The underlying config knobs the
workers honor are:

* `platz-k8s-agent` reads `PLATZ_CLUSTER_PROVIDER` (default `eks`):
  * `eks` — discovers EKS clusters across all AWS regions in the running account.
  * `local` — registers a single cluster from a kubeconfig context.
* `platz-chart-discovery` reads `PLATZ_REGISTRY_PROVIDER` (default `ecr`):
  * `ecr` — watches an SQS queue fed by ECR push/delete events.
  * `oci` — periodically polls a generic OCI registry for new chart artifacts.

The local stack uses `local` and `oci`.

## Connecting to the development database

```bash
PGHOST=127.0.0.1 PGPORT=15432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE=platz psql
```

## Adding test charts

Test charts live under [charts/](charts/) and are pushed to the in-cluster
OCI registry by [scripts/seed-charts.sh](scripts/seed-charts.sh) (invoked
automatically by Tilt). Drop a new chart in that directory and re-trigger
the `seed-charts` resource in Tilt's UI to publish it.

## Layout

```
.
├── Tiltfile                # orchestrates the whole local stack
├── kind-config.yaml        # single-node kind cluster with NodePort mappings
├── values.local.yaml       # helm overrides layered on platzio/helm-charts
├── manifests/              # in-cluster Postgres, Dex, registry, namespace
├── charts/                 # test charts seeded into the local OCI registry
├── scripts/seed-charts.sh  # invoked by Tilt to package + push charts/*
└── .claude/                # shared Claude config (sibling-repo allow list)
```
