FROM ghcr.io/actions/actions-runner:2.338.0@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807 AS runner-base

FROM runner-base AS jit-init
USER root
COPY jit-config.mjs /opt/spike10/jit-config.mjs
ENTRYPOINT ["/home/runner/externals/node20/bin/node", "/opt/spike10/jit-config.mjs"]

FROM runner-base AS jit-runner
USER root
COPY --chown=runner:docker run-jit.sh /opt/spike10/run-jit.sh
RUN chmod 0555 /opt/spike10/run-jit.sh
USER runner
ENTRYPOINT ["/opt/spike10/run-jit.sh"]
