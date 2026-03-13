FROM debian:bookworm-slim

# ── Tool versions ──────────────────────────────────────────────────────────────
ARG SUPERCRONIC_VERSION=0.2.33
ARG SUPERCRONIC_SHA256=feefa310da569c81b99e1027b86b27b51e6ee9ab647747b49099645120cfc671
ARG YQ_VERSION=4.50.1
ARG AGE_VERSION=1.1.1

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        rsync \
        openssh-client \
        jq \
        zstd \
        awscli \
        curl \
        ca-certificates \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ── supercronic ───────────────────────────────────────────────────────────────
RUN curl -fsSL \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
      -o /usr/local/bin/supercronic \
    && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod +x /usr/local/bin/supercronic

# ── yq (Mike Farah go-based) ──────────────────────────────────────────────────
# Checksums: https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/checksums
RUN curl -fsSL \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
      -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ── age ───────────────────────────────────────────────────────────────────────
# Checksums: https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/
RUN curl -fsSL \
      "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin --strip-components=1 age/age

# ── fsbackup user + directories ───────────────────────────────────────────────
RUN groupadd -r fsbackup \
    && useradd -r -g fsbackup -d /var/lib/fsbackup -s /bin/bash fsbackup \
    && mkdir -p \
        /var/lib/fsbackup/log \
        /var/lib/fsbackup/.ssh \
        /var/lib/fsbackup/.aws \
        /var/lib/node_exporter/textfile_collector \
        /etc/fsbackup \
        /backup/snapshots \
        /backup2/snapshots \
    && chown -R fsbackup:fsbackup \
        /var/lib/fsbackup \
        /etc/fsbackup \
        /var/lib/node_exporter/textfile_collector

# ── Python venv ───────────────────────────────────────────────────────────────
COPY web/requirements.txt /opt/fsbackup/web/requirements.txt
RUN python3 -m venv /opt/fsbackup/web/.venv \
    && /opt/fsbackup/web/.venv/bin/pip install -q --upgrade pip \
    && /opt/fsbackup/web/.venv/bin/pip install -q -r /opt/fsbackup/web/requirements.txt

# ── Repo ──────────────────────────────────────────────────────────────────────
COPY --chown=fsbackup:fsbackup . /opt/fsbackup/

# ── Entrypoint ────────────────────────────────────────────────────────────────
RUN chmod +x /opt/fsbackup/docker/entrypoint.sh

USER fsbackup
WORKDIR /opt/fsbackup/web

EXPOSE 8080
ENTRYPOINT ["/opt/fsbackup/docker/entrypoint.sh"]
