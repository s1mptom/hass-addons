# Pin the Playwright base image directly. HA Supervisor's build_from regex
# rejects single-path-segment images like mcr.microsoft.com/playwright, which
# made it silently fall back to an Alpine base where apt-get is missing
# (build failed with "apt-get: not found" — see issue #28). Hardcoding FROM
# here is also what Supervisor recommends now that build.yaml is deprecated.
FROM mcr.microsoft.com/playwright:v1.61.1-noble

# Labels
LABEL maintainer="Robson Felix"
LABEL io.hass.version="0.1.13"
LABEL io.hass.type="addon"
LABEL io.hass.arch="amd64,aarch64"
LABEL org.opencontainers.image.title="Playwright Browser for Home Assistant"
LABEL org.opencontainers.image.description="Headless Chromium with CDP endpoint for browser automation"
LABEL org.opencontainers.image.source="https://github.com/s1mptom/hass-addons"
LABEL org.opencontainers.image.licenses="MIT"

# jq is already available in the Playwright image (Ubuntu-based)
# Just ensure it's installed
RUN apt-get update && \
    apt-get install -y --no-install-recommends jq curl nginx && \
    rm -rf /var/lib/apt/lists/*

# Create data directory
RUN mkdir -p /data

# Copy run script
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Expose CDP port
EXPOSE 9222

# Health check - verify CDP endpoint responds
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:9222/json/version || exit 1

CMD ["/run.sh"]
