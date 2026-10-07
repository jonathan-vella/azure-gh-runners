# Generic runner image

Issue [#19](https://github.com/jonathan-vella/azure-gh-runners/issues/19) supplies the **linux/amd64 toolset only**.
The image is not yet a deployable platform runner. JIT initialization, the pre-job policy hook, and the main
entrypoint belong to issues #21, #20, and #22; identity isolation, labels, and the production build path still require
their spike decisions. Nothing here publishes an image, onboards a consumer, or deploys Azure resources.

## Pins and provenance

[`versions.json`](versions.json) is the installation and verification manifest, not a list of intended versions.
The official runner `2.338.0` multi-platform digest was read from GHCR with `docker buildx imagetools inspect`.
Its amd64 filesystem was inspected to establish the existing `runner` UID/GID (1001/1001), tool package versions,
and `/home/runner` layout. Git, jq, curl, and Python are inherited **by that immutable digest** and their exact
dpkg versions are checked during every build. No apt update or floating dependency resolution occurs.
The jq package is `1.7.1-3ubuntu0.24.04.2`, although its executable reports `jq-1.7`.

The additional tools use official, version-qualified binaries/packages with committed SHA-256 checksums. Every download
must pass the checksum check **before** extraction or execution; redirects must remain HTTPS. Azure CLI's Debian
package includes its own Python and dependencies, separate from the pinned system `python3`. `dpkg --install` checks
that its system-library dependencies are satisfied by the immutable base; it cannot fetch additional packages.
These first-party sources were checked on 2026-10-07:

| Tool | Version | Release and checksum source |
| --- | --- | --- |
| Azure CLI | 2.91.0 | [Official release](https://github.com/Azure/azure-cli/releases/tag/azure-cli-2.91.0), `2.91.0-1~noble` SHA256 in [Microsoft's package index](https://packages.microsoft.com/repos/azure-cli/dists/noble/main/binary-amd64/Packages.gz) |
| Bicep | 0.48.1 | [Latest stable release](https://github.com/Azure/bicep/releases/tag/v0.48.1), `bicep-linux-x64` asset digest in GitHub release metadata |
| Terraform | 1.16.5 | [Latest stable release](https://github.com/hashicorp/terraform/releases/tag/v1.16.5), [official SHA256SUMS](https://releases.hashicorp.com/terraform/1.16.5/terraform_1.16.5_SHA256SUMS) |
| Node LTS | 24.21.0 | [Official index](https://nodejs.org/dist/index.json), highest released LTS entry (Krypton), [SHASUMS256.txt](https://nodejs.org/dist/v24.21.0/SHASUMS256.txt) |
| PowerShell | 7.6.6 | [Official release](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6), `linux-x64` asset digest in GitHub release metadata |

Update pins through a reviewed PR: resolve the official release and checksum sources again, change the manifest,
and rebuild. Never use `latest`, an unverified installer, or override build arguments. A runner-base update also
requires re-inspecting UID/GID, package versions, library compatibility, and security defaults. The installation
script rejects non-amd64 bases; other architectures need separately verified archives and testing.

## Privilege and Docker

The final user is the upstream `runner`, not a newly created account. Its sudo and docker supplementary groups are
removed because the base grants passwordless sudo. The inherited `/usr/bin/dockerd` binary is removed; no daemon is
installed, started, or used. The upstream Docker client and other upstream utilities are preserved. Do not mount a
Docker socket or run this image privileged. Container builds/Docker-in-Docker are not supported.
The runner directory remains writable by `runner`; installed tools and the manifest are root-owned and not
runner-writable. Upstream `WORKDIR`, `CMD`, runner files, and embedded action Node runtimes remain unchanged.
The upstream image has no entrypoint and defaults to `/bin/bash`: this change deliberately does not add one.

## Local verification

From the repository root, with Linux Docker available:

```powershell
docker build --platform linux/amd64 --progress plain -f image\Dockerfile -t ghrunners-issue19:local .
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges --entrypoint bash ghrunners-issue19:local /opt/runner-image/verify-tools.sh
Get-Content -Raw image\Dockerfile | docker run --rm -i hadolint/hadolint@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e
npm run validate
```

Bound local build execution to 20 minutes; individual downloads have a 180-second timeout and three retries.
The build itself runs the version/permission probe without networking, including `az bicep version` using the
installed Bicep rather than auto-downloading another binary. The separate container probe additionally drops
capabilities and disallows privilege escalation. Neither probe registers a runner or requires cloud credentials.
`npm run validate` includes offline image contract tests alongside all existing repository validators.
Those tests check committed pins and structure only: **they are not substitutes for Docker build, hadolint,
or executable version/permission probes**. If Docker is unavailable, report those checks as blocked and keep the PR
draft with **do not merge** until actual build evidence is available.
