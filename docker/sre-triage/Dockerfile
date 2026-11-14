# Read-only SRE triage agent: Claude Code headless, started from a ntfy button.
# Design and safety model: homelab-docs/sre-triage-agent.md
FROM node:22-bookworm-slim

ARG TARGETARCH
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.325
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.2
# renovate: datasource=github-releases depName=fluxcd/flux2
ARG FLUX_VERSION=v2.10.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates coreutils curl git jq \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod 0755 /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/flux_${FLUX_VERSION#v}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin flux \
 && kubectl version --client \
 && flux --version

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

RUN useradd --uid 10001 --create-home --home-dir /home/triage --shell /bin/bash triage \
 && mkdir -p /work && chown triage:triage /work

COPY --chmod=0755 listener.sh /opt/sre-triage/listener.sh
COPY --chmod=0644 agents.json settings.json /opt/sre-triage/

# Claude Code writes config and state on every run: HOME and CLAUDE_CONFIG_DIR are emptyDirs in the pod.
# No auto-update, no telemetry or other non-essential traffic (keeps the FQDN egress list short).
ENV HOME=/home/triage \
    CLAUDE_CONFIG_DIR=/home/triage/.claude \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

USER 10001
WORKDIR /work
ENTRYPOINT ["/opt/sre-triage/listener.sh"]
