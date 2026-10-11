FROM node:24.19.0-bookworm-slim@sha256:a9f5f7c91a432850b2a8a7797adf5eadb6c733ceed61167806cee7ea7fbc29df AS node

FROM mcr.microsoft.com/azure-cli:2.91.0@sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044
# Runs only this platform's orchestrator code; it never executes user job code.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY image/windows-orchestrator/github.mjs image/windows-orchestrator/azure.mjs image/windows-orchestrator/orchestrator.mjs /opt/orchestrator/
RUN chmod 0444 /opt/orchestrator/*.mjs
ENV AZURE_CORE_COLLECT_TELEMETRY=false \
    AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
WORKDIR /opt/orchestrator
ENTRYPOINT ["/usr/local/bin/node", "/opt/orchestrator/orchestrator.mjs"]
