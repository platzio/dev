#!/usr/bin/env bash
# Packages every chart under ../charts/ and pushes it to the local OCI
# registry running inside the kind cluster. Reaches the registry through the
# Tiltfile's port-forward at 5001.
#
# Run via Tilt (after `registry` is ready) or manually after `tilt up` is running.

set -eu

HERE="$(realpath "$(dirname "$0")")"
LOG_PREFIX="[$(basename "$0")]"

REGISTRY_HOST="${PLATZ_LOCAL_REGISTRY_HOST:-localhost:5001}"

if ! command -v helm >/dev/null
then
    echo "${LOG_PREFIX} 'helm' is required (>=3.8 for OCI support)" >&2
    exit 2
fi

# Make sure the registry is reachable; if not, the user probably hasn't run
# `tilt up` yet (which establishes the port-forward).
if ! curl -fsS "http://${REGISTRY_HOST}/v2/" >/dev/null
then
    echo "${LOG_PREFIX} Cannot reach OCI registry at http://${REGISTRY_HOST}" >&2
    echo "${LOG_PREFIX} Is 'tilt up' running and the 'registry' resource ready?" >&2
    exit 2
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

shopt -s nullglob
for chart_dir in "${HERE}/../charts"/*/
do
    chart_name="$(basename "${chart_dir}")"
    echo "${LOG_PREFIX} Packaging ${chart_name}" >&2
    helm package "${chart_dir}" --destination "${WORK_DIR}" >&2

    pkg="$(ls "${WORK_DIR}/${chart_name}"-*.tgz | head -1)"
    echo "${LOG_PREFIX} Pushing ${pkg} to oci://${REGISTRY_HOST}/charts" >&2
    helm push "${pkg}" "oci://${REGISTRY_HOST}/charts" >&2
done
