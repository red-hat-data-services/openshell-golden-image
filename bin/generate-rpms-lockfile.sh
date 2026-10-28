#!/bin/bash
#
# Generate rpms.lock.yaml for Containerfile.saw.
#
# Runs rpm-lockfile-prototype inside a UBI 9 podman container, resolving
# rpms.in.yaml against the bootc base image pinned in argfile-saw.conf.
# Entitlement certs are passed via DNF_VAR_SSL_CLIENT_CERT /
# DNF_VAR_SSL_CLIENT_KEY — the same mechanism MintMaker uses. The generated
# lockfile contains cdn.redhat.com URLs that Hermeto downloads in Konflux
# using the activation-key secret wired into the build.
#
# Only needed when adding or removing packages in rpms.in.yaml. Version
# drift and base image bumps are handled by MintMaker (default RPM lockfile
# maintenance plus the refresh-rpm-lockfiles preset in renovate.json).
#
# Usage:
#   bin/generate-rpms-lockfile.sh
#   bin/generate-rpms-lockfile.sh --org ID --activation-key KEY
#   RHSM_ORG=... RHSM_ACTIVATION_KEY=... bin/generate-rpms-lockfile.sh
#
# The bootc base image lives on registry.redhat.io. Pass registry
# credentials via REGISTRY_USER / REGISTRY_TOKEN (for example the registry
# service account), or run `skopeo login registry.redhat.io` on the host
# first — the host auth file is mounted into the container.
#
# Prerequisites:
#   - podman
#   - either a subscription-manager-registered host (/etc/pki/entitlement),
#     or --org + --activation-key with RHEL 9.6 EUS + RHEL AI 3.6 access
set -euo pipefail

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
err() { echo -e "\033[1;31mERROR: $*\033[0m" >&2; }

ORG="${RHSM_ORG:-}"
KEY="${RHSM_ACTIVATION_KEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)
            ORG="${2:?--org requires an argument}"
            shift 2
            ;;
        --activation-key | --activationkey)
            KEY="${2:?--activation-key requires an argument}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -n "${ORG}" && -z "${KEY}" ]] || [[ -z "${ORG}" && -n "${KEY}" ]]; then
    err "--org and --activation-key must be used together (or set both RHSM_ORG and RHSM_ACTIVATION_KEY)"
    exit 1
fi

REGISTER=0
if [[ -n "${ORG}" && -n "${KEY}" ]]; then
    REGISTER=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_IMAGE="$(sed -n 's/^BASE_IMAGE=//p' "${REPO_ROOT}/argfile-saw.conf")"
if [[ -z "${BASE_IMAGE}" ]]; then
    err "No BASE_IMAGE found in argfile-saw.conf"
    exit 1
fi

RUNTIME_IMAGE="registry.access.redhat.com/ubi9/ubi:9.8"
RPM_LOCKFILE_VERSION="v0.30.1"

if [[ "${REGISTER}" -eq 0 ]]; then
    HOST_CERT=$(find /etc/pki/entitlement -name '*.pem' ! -name '*-key.pem' 2> /dev/null | head -1)
    HOST_KEY=$(find /etc/pki/entitlement -name '*-key.pem' 2> /dev/null | head -1)
    if [[ -z "${HOST_CERT}" || -z "${HOST_KEY}" ]]; then
        err "No entitlement certs found in /etc/pki/entitlement/"
        err "Run this on a registered system, or pass --org and --activation-key"
        exit 1
    fi
fi

log "Generating rpms.lock.yaml"
log "Repo root : ${REPO_ROOT}"
log "Base image: ${BASE_IMAGE}"
if [[ "${REGISTER}" -eq 1 ]]; then
    log "Auth      : register inside container (org ${ORG})"
else
    log "Auth      : host cert ${HOST_CERT}"
fi

PODMAN_ARGS=(
    --rm
    --network=host
    --platform linux/amd64
    --security-opt label=disable
    -e BASE_IMAGE="${BASE_IMAGE}"
    -e REGISTER="${REGISTER}"
    -e RPM_LOCKFILE_VERSION="${RPM_LOCKFILE_VERSION}"
    -v "${REPO_ROOT}:/source"
)

# Secrets (registry credentials, org, activation key) are passed via a
# 0600 env file instead of -e arguments so they never appear in process
# arguments on the host. Removed on exit.
ENV_FILE=""
cleanup() {
    [[ -n "${ENV_FILE}" ]] && rm -f "${ENV_FILE}"
}
trap cleanup EXIT

# Pull the base image with the host's registry credentials when present.
if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_TOKEN:-}" ]]; then
    ENV_FILE="$(mktemp)"
    chmod 600 "${ENV_FILE}"
    printf 'REGISTRY_USER=%s\nREGISTRY_TOKEN=%s\n' "${REGISTRY_USER}" "${REGISTRY_TOKEN}" > "${ENV_FILE}"
elif [[ -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" ]]; then
    PODMAN_ARGS+=(-v "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json:/root/auth.json:ro")
fi

if [[ "${REGISTER}" -eq 1 ]]; then
    if [[ -z "${ENV_FILE}" ]]; then
        ENV_FILE="$(mktemp)"
        chmod 600 "${ENV_FILE}"
    fi
    printf 'ORG=%s\nKEY=%s\n' "${ORG}" "${KEY}" >> "${ENV_FILE}"
else
    PODMAN_ARGS+=(
        -v /etc/pki/entitlement:/etc/pki/entitlement:ro
        -v /etc/rhsm:/etc/rhsm:ro
    )
fi

if [[ -n "${ENV_FILE}" ]]; then
    PODMAN_ARGS+=(--env-file "${ENV_FILE}")
fi

podman run "${PODMAN_ARGS[@]}" \
    "${RUNTIME_IMAGE}" \
    bash -euo pipefail -c '
        log() { echo -e "\n\033[1;34m==> $*\033[0m"; }

        if [[ "${REGISTER}" -eq 1 ]]; then
            log "Registering with subscription-manager"
            subscription-manager register --org "${ORG}" --activationkey "${KEY}"
            subscription-manager release --set=9.6 || true
        fi

        # Entitlement certs as DNF_VAR_* env vars — same as MintMaker.
        CERT=$(ls /etc/pki/entitlement/*.pem 2>/dev/null | grep -v "\-key\.pem" | head -1)
        KEY_FILE=$(ls /etc/pki/entitlement/*-key.pem 2>/dev/null | head -1)
        if [[ -z "${CERT}" ]]; then
            echo "ERROR: No entitlement certs in /etc/pki/entitlement/" >&2
            exit 1
        fi
        export DNF_VAR_SSL_CLIENT_CERT="${CERT}"
        export DNF_VAR_SSL_CLIENT_KEY="${KEY_FILE}"
        log "Using cert: ${CERT}"

        log "Installing rpm-lockfile-prototype ${RPM_LOCKFILE_VERSION}"
        dnf install -y python3 python3-pip python3-dnf skopeo rpm
        if [[ -n "${REGISTRY_USER:-}" ]]; then
            skopeo login registry.redhat.io -u "${REGISTRY_USER}" --password-stdin <<< "${REGISTRY_TOKEN}"
        elif [[ -f /root/auth.json ]]; then
            export REGISTRY_AUTH_FILE=/root/auth.json
        fi
        pip3 install --no-cache-dir "https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/tags/${RPM_LOCKFILE_VERSION}.tar.gz"

        cd /source
        if [[ "${REGISTER}" -eq 1 ]]; then
            trap "subscription-manager unregister || true" EXIT
        fi

        log "Resolving rpms.in.yaml against ${BASE_IMAGE}"
        rpm-lockfile-prototype --image "${BASE_IMAGE}" rpms.in.yaml
        log "OK: rpms.lock.yaml"
    '

log "Done — commit: git add rpms.lock.yaml"
