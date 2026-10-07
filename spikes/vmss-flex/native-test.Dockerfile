FROM ghcr.io/actions/actions-runner@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807 AS unpack
USER root
ADD --checksum=sha256:820311e238ea34d76a8ca2643d6c01065212e9417109e7397d70472a236df261 https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-amd64-root.tar.xz /root.tar.xz
RUN mkdir /rootfs && python3 -c "import tarfile; tarfile.open('/root.tar.xz').extractall('/rootfs', filter='tar')"

FROM scratch
COPY --from=unpack /rootfs /
COPY image /bundle/image
COPY spikes/vmss-flex/native-bootstrap.sh spikes/vmss-flex/native-image.json spikes/vmss-flex/run-one-job.sh /bundle/spikes/vmss-flex/
RUN chmod 1777 /tmp /var/tmp && /bin/bash /bundle/spikes/vmss-flex/native-bootstrap.sh
USER runner
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh \
    AZURE_CORE_COLLECT_TELEMETRY=false \
    AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no \
    AZURE_BICEP_USE_BINARY_FROM_PATH=true \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
RUN --network=none /bin/bash /opt/runner-image/verify-tools.sh
