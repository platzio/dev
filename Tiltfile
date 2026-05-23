# Tiltfile — orchestrates a local-only Platz environment.
#
# Runs from the platzio/dev repo, but reaches sibling Platz repos via relative
# paths. Expected layout:
#
#   <parent>/
#     dev/          <-- this repo (run `tilt up` from here)
#     backend/      <-- platzio/backend
#     frontend/     <-- platzio/frontend
#     helm-charts/  <-- platzio/helm-charts
#
# Brings up: a kind cluster, an in-cluster Postgres + Dex + OCI registry,
# the five backend workers (built from ../backend via its Dockerfile's `dev`
# target stage), and the frontend (built from ../frontend), wired together
# via the platzio helm chart from ../helm-charts/charts/platzio with
# values.local.yaml overrides.
#
# Pre-requisites: docker, kind, kubectl, helm, tilt, npm.
#
# Run with `tilt up`. Stop with `tilt down`.

KIND_CLUSTER_NAME = 'platz-local'
KIND_CONTEXT      = 'kind-' + KIND_CLUSTER_NAME

allow_k8s_contexts(KIND_CONTEXT)

# Sanity-check sibling repos exist before we start fanning out errors.
if not os.path.exists('../backend/Cargo.toml'):
    fail('Expected ../backend/Cargo.toml. Clone platzio/backend next to this repo.')
if not os.path.exists('../frontend/package.json'):
    fail('Expected ../frontend/package.json. Clone platzio/frontend next to this repo.')
if not os.path.exists('../helm-charts/charts/platzio/Chart.yaml'):
    fail('Expected ../helm-charts/charts/platzio/Chart.yaml. Clone platzio/helm-charts next to this repo.')

# ---------------------------------------------------------------------------
# Bootstrap: kind cluster (idempotent). Done as a `local_resource` so Tilt
# only re-runs when the kind config changes.
# ---------------------------------------------------------------------------
local_resource(
    'kind-cluster',
    cmd = '''
set -e
if ! kind get clusters | grep -qx ''' + KIND_CLUSTER_NAME + ''' ; then
    echo "Creating kind cluster ''' + KIND_CLUSTER_NAME + '''"
    kind create cluster --name ''' + KIND_CLUSTER_NAME + ''' --config kind-config.yaml
fi
kubectl config use-context ''' + KIND_CONTEXT + '''
''',
    deps = ['kind-config.yaml'],
    labels = ['infra'],
)

# ---------------------------------------------------------------------------
# In-cluster infra: namespace, Postgres, Dex, registry. Order: namespace first.
# ---------------------------------------------------------------------------
k8s_yaml('manifests/namespace.yaml')
k8s_yaml('manifests/postgres.yaml')
k8s_yaml('manifests/dex.yaml')
k8s_yaml('manifests/registry.yaml')

k8s_resource('postgres', labels = ['infra'], port_forwards = '15432:5432')
k8s_resource('dex',      labels = ['infra'])
k8s_resource('registry', labels = ['infra'], port_forwards = '5001:5000')

# ---------------------------------------------------------------------------
# Backend dev image: built from ../backend via the `dev` target stage in its
# Dockerfile. That stage keeps the rust toolchain + workspace source inside
# the runtime image so live_update can re-run `cargo build` in the running
# container. The debug build with cargo's incremental cache is fast
# (~10-30s for a typical edit).
# ---------------------------------------------------------------------------
docker_build(
    'platzio/backend-dev',
    context    = '../backend',
    dockerfile = '../backend/Dockerfile',
    target     = 'dev',
    only = [
        './Cargo.toml',
        './Cargo.lock',
        './api',
        './auth',
        './chart-discovery',
        './db',
        './k8s-agent',
        './otel',
        './resource-sync',
        './status-updates',
    ],
    ignore = [
        '**/target',
        '**/*.swp',
    ],
    live_update = [
        sync('../backend/api',             '/build/api'),
        sync('../backend/auth',            '/build/auth'),
        sync('../backend/chart-discovery', '/build/chart-discovery'),
        sync('../backend/db',              '/build/db'),
        sync('../backend/k8s-agent',       '/build/k8s-agent'),
        sync('../backend/otel',            '/build/otel'),
        sync('../backend/resource-sync',   '/build/resource-sync'),
        sync('../backend/status-updates',  '/build/status-updates'),
        run(
            'cd /build && cargo build --workspace --bins '
            '&& cp target/debug/platz-api /root/platz-api '
            '&& cp target/debug/platz-k8s-agent /root/platz-k8s-agent '
            '&& cp target/debug/platz-chart-discovery /root/platz-chart-discovery '
            '&& cp target/debug/platz-status-updates /root/platz-status-updates '
            '&& cp target/debug/platz-resource-sync /root/platz-resource-sync',
            trigger = [
                './api',
                './auth',
                './chart-discovery',
                './db',
                './k8s-agent',
                './otel',
                './resource-sync',
                './status-updates',
            ],
        ),
        restart_container(),
    ],
)

# ---------------------------------------------------------------------------
# Frontend dev image: same nginx-based prod Dockerfile. We rebuild the dist
# locally on every source change and let Tilt sync the built dist into the
# running nginx pod (no image rebuild). Reload time ≈ vite build time.
# ---------------------------------------------------------------------------
local_resource(
    'frontend-build',
    cmd = 'cd ../frontend && npm run build',
    deps = [
        '../frontend/src',
        '../frontend/index.html',
        '../frontend/package.json',
        '../frontend/package-lock.json',
        '../frontend/vite.config.ts',
        '../frontend/tsconfig.json',
        '../frontend/tsconfig.app.json',
        '../frontend/tsconfig.node.json',
    ],
    labels = ['frontend'],
)

docker_build(
    'platzio/frontend-dev',
    context    = '../frontend',
    dockerfile = '../frontend/Dockerfile',
    only = ['./dist', './nginx.conf'],
    live_update = [
        sync('../frontend/dist', '/usr/share/nginx/html'),
    ],
)

# ---------------------------------------------------------------------------
# Apply the platzio helm chart with our local-mode overrides.
# image_deps tells Tilt to redeploy when the dev images change.
# ---------------------------------------------------------------------------
k8s_yaml(helm(
    '../helm-charts/charts/platzio',
    name = 'platz',
    namespace = 'platz',
    values = ['./values.local.yaml'],
))

# Group everything platz-* under a single Tilt resource label.
k8s_resource(
    'platz-platzio-api',
    labels = ['backend'],
    port_forwards = '3000:3000',
    resource_deps = ['kind-cluster', 'postgres', 'dex'],
)
k8s_resource('platz-platzio-k8s-agent-default',       labels = ['backend'], resource_deps = ['kind-cluster', 'postgres'])
k8s_resource('platz-platzio-chart-discovery-default', labels = ['backend'], resource_deps = ['kind-cluster', 'postgres', 'registry'])
k8s_resource('platz-platzio-status-updates',          labels = ['backend'], resource_deps = ['kind-cluster', 'postgres'])
k8s_resource('platz-platzio-resource-sync',           labels = ['backend'], resource_deps = ['kind-cluster', 'postgres'])
k8s_resource(
    'platz-platzio-frontend',
    labels = ['frontend'],
    port_forwards = '8080:80',
    resource_deps = ['frontend-build'],
)

# ---------------------------------------------------------------------------
# Seed a couple of test charts into the local registry, after the registry
# pod is ready. chart-discovery's OCI poller will pick them up on its next tick.
# ---------------------------------------------------------------------------
local_resource(
    'seed-charts',
    cmd = './scripts/seed-charts.sh',
    deps = ['charts'],
    resource_deps = ['registry'],
    labels = ['infra'],
)
