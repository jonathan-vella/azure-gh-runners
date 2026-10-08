FROM ghcr.io/actions/actions-runner@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807 AS base

FROM base AS jit-init
USER root
COPY image/jit-init.mjs /opt/runner-image/jit-init.mjs
RUN chmod 0444 /opt/runner-image/jit-init.mjs
ENTRYPOINT ["/home/runner/externals/node20/bin/node", "/opt/runner-image/jit-init.mjs"]
CMD []

FROM base AS runner
USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

COPY image/versions.json image/install-tools.sh /opt/runner-image/
RUN bash /opt/runner-image/install-tools.sh \
    && rm /opt/runner-image/install-tools.sh
COPY image/verify-tools.sh /opt/runner-image/
COPY image/pre-job-policy.sh image/pre-job-policy.py image/runner-entrypoint.sh /opt/runner-image/
RUN chmod 0555 /opt/runner-image/pre-job-policy.sh /opt/runner-image/pre-job-policy.py \
    /opt/runner-image/runner-entrypoint.sh

ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/runner-image/pre-job-policy.sh \
    AZURE_CORE_COLLECT_TELEMETRY=false \
    AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no \
    AZURE_BICEP_USE_BINARY_FROM_PATH=true \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1

USER runner
RUN --network=none bash /opt/runner-image/verify-tools.sh
ENTRYPOINT ["/opt/runner-image/runner-entrypoint.sh"]
CMD []
