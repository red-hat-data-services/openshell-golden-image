# SAW golden image

Source of truth for the SAW (Secure Agent Workspace) golden VM image: the
bootable RHEL 9 disk that per-user Agent and Integration VMs boot on
OpenShift Virtualization.

## Artifact chain

```
Containerfile.saw ──(Konflux build)──> bootc container
                └─(bib-saw.yaml, build-vm-image task)──> qcow2
                        └─(Containerfile.saw-disk-image)──> disk-image container (released artifact)
```

The bootc container is the source of truth. One `build-vm-image` run
produces the qcow2; a disk-image container wrapping it is the released
artifact, imported into the `openshell-gateway` DataSource via CDI. SAW
ships one qcow2 per architecture (x86_64, arm64) — no ISO or cloud formats.

## What is in the image — and what is not

In: RHEL 9 base, podman (the openshell-gateway sandbox driver; Docker CE
is dropped), python3 (the in-guest installer is Python), cloud-init,
qemu-guest-agent, ssh, the disconnected-registry template under
`context/saw/etc/containers/registries.conf.d/`, the installer trust-root
directory `/etc/saw/trust`, and the `saw-install`/`saw-apply` systemd
units.

OpenShell is baked in by design: the four RPMs are installed at build time
from the RHEL AI layered el9 repo, pinned to exact versions in
`argfile-saw.conf` — a version bump is a one-line diff, and each bump
produces a new golden image; the consumer side shuts off dynamic OpenShell
installation in production. Base decision (2026-10-22): RHEL 9, because
el10 OpenShell RPMs will not be available any time soon. When hermetic
builds are enabled, the RPMs move to Hermeto prefetch inputs.

The installer's role is reduced accordingly: it creates sandboxes and
applies per-user config (via the saw-* units), it no longer installs
OpenShell in production. The units ship disabled; the installer package
(apply_bom.py, verify-bundle, trust roots) comes from the OpenShell team.

## Build inputs

- `argfile-saw.conf` — base image, vendor, version, pull secret for
  `Containerfile.saw`.
- `bib-saw.yaml`, `config/config-saw-qcow2.toml` — bootc-image-builder
  inputs for the qcow2 (source-image digest updated by Konflux nudge MRs).
- `argfile-saw-disk-image.conf` — inputs for the multi-arch disk-image
  container: per-arch qcow2 digests (updated by Konflux nudge MRs), the
  image-pull secret, and the version.

Entitled RHEL 9 repos come from the activation key wired into the Konflux
build: `rhel-ai-activation-key`, the same key the RHEL AI bootc builds
use (see PMC `rhelai` config-containers.yaml). Pinned to release 9.6,
matching this base.

## Release

Every disk-image-container build publishes automatically: the Konflux
ReleasePlan (`saw-disk-image-containers-stage`) auto-releases each arch's
wrapper to `quay.io/aipcc/saw-golden-image/`, tagged from the image
version label plus timestamp. The trigger is a merge to `main` touching
the component's files — no release branches, no tags. The bootc source
container is published alongside (`saw-bootc-stage`), tagged in lockstep
and referenced from the disk image's labels: it is what makes the disk
reproducible and keeps bootc upgrade open as an update path for running
VMs. Nothing in SAW consumes it today — only the disk-image containers
are imported by the `openshell-gateway` DataSource.

## Open items

- Konflux secrets: the activation key (`ai-aipcc-cicd/rhel-ai-activation-key`)
  and the registry pull secret are synced into `ai-incubator-tenant` from
  corp Vault by External Secrets Operator — no manual secret copies. The
  `vault-approle` secret-id and `trusted-ca` ConfigMap the SecretStore
  needs are applied out-of-band, as in every other tenant using this
  pattern.
- Per-arch artifact-pull secrets (`saw-qcow2-disk-image-image-pull`,
  `-aarch64`): required by the wrapper builds to pull their qcow2
  artifacts from the tenant workloads registry; credentials pending.
- `.tekton/` pipelineruns: land with Konflux onboarding (branch
  RHAI-10799/tekton-pipelines).
- nodejs/nmap-ncat: pending confirmation against the installer package.
- Falcon/Vector: not included; decision pending.

## References

- Tracking: [RHAI-10799](https://redhat.atlassian.net/browse/RHAI-10799)
- Repo scaffold: [RHAI-5877](https://redhat.atlassian.net/browse/RHAI-5877)
- Assignment: [RHAIRFE-3509](https://redhat.atlassian.net/browse/RHAIRFE-3509)
- Build pattern: `redhat/rhel-ai/containers/bootc`
- Architecture: "SAW Golden Image & Installer Architecture"
