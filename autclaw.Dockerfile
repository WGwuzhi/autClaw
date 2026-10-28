# autClaw runtime base image (slim, default).
#
# This is the default image: it keeps everything autClaw needs to boot and to
# install runtimes. Media extras (ffmpeg) are layered on top in
# autclaw-full.Dockerfile via AUTCLAW_BASE_IMAGE.
#
# Runtime deps kept here:
# curl/ca-certificates (release bundle + mise downloads), tar/gzip/sha256sum
# (already in debian:trixie-slim), xz-utils (mise's own archive), tini (PID 1),
# and gcc/libc6-dev/make (cgo build of Go plugins, see below).
FROM debian:trixie-slim

ARG MISE_VERSION=2026.10.19

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

WORKDIR /opt/autclaw

# Package selection notes:
#
# - bash/tar/tzdata/gzip/sha256sum/awk/sed/findutils are already present in
#   debian:trixie-slim. Listing them again costs nothing but hides which
#   packages are actually added, so they are omitted.
#
# - gcc + libc6-dev + make replace build-essential. Nothing here builds C++
#   sources, so g++/cpp/libstdc++-14-dev (~83MB compressed) are dead weight.
#   The C toolchain is NOT optional: Go plugins compile in-container with
#   CGO_ENABLED unset (internal/plugins/runtime_launcher.go buildRuntimeEnv
#   sets no CGO override), and any plugin importing net or os/user then needs
#   a working C compiler.
#
# - The eleven -dev headers previously listed (libssl-dev, libbz2-dev,
#   libreadline-dev, libsqlite3-dev, libffi-dev, liblzma-dev, libgdbm-dev,
#   libncurses5-dev, libnss3-dev, tk-dev, zlib1g-dev) came from pyenv's
#   source-build list. mise installs node/python/go from precompiled artifacts
#   (python-build-standalone / official Node and Go tarballs) and ruby/erlang
#   default to precompiled too, so nothing compiles against them.
#   libncurses5-dev does not even exist in trixie (provided by libncurses-dev).
#
# - git/wget/rsync/unzip/gnupg2 are unused. The entrypoint and mise both use
#   curl; mise clones asdf plugins with its built-in gix (settings.gix defaults
#   to true), extracts zip/xz/zstd in-process and verifies OpenPGP signatures
#   with its embedded implementation, so no gpg binary is needed.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        tini \
        gcc \
        libc6-dev \
        make; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# mise is installed from the pinned release archive rather than https://mise.run:
# the installer embeds tar.gz checksums for the "current" release only, so
# MISE_INSTALL_EXT=tar.xz fails verification, and the unpinned path resolves a
# different version on every build. Pinning keeps rebuilds reproducible.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) mise_arch="x64" ;; \
        arm64) mise_arch="arm64" ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    asset="mise-v${MISE_VERSION}-linux-${mise_arch}.tar.xz"; \
    base_url="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}"; \
    curl -fsSL -o "/tmp/${asset}" "${base_url}/${asset}"; \
    curl -fsSL -o /tmp/SHASUMS256.txt "${base_url}/SHASUMS256.txt"; \
    (cd /tmp \
        && awk -v a="${asset}" 'NF == 2 && $2 == "./" a { print }' SHASUMS256.txt \
        | sha256sum -c --status); \
    tar -xJf "/tmp/${asset}" -C /tmp mise/bin/mise; \
    install -m 0755 /tmp/mise/bin/mise /usr/local/bin/mise; \
    strip --strip-unneeded /usr/local/bin/mise; \
    mise --version; \
    rm -rf /tmp/mise "/tmp/${asset}" /tmp/SHASUMS256.txt /root/.cache

RUN mkdir -p \
    /opt/autclaw/dist \
    /opt/autclaw/plugin \
    /opt/autclaw/envs/mise \
    /opt/autclaw/envs/packages \
    /run

COPY --chmod=755 deploy/entrypoint.sh /entrypoint.sh

ENV HTTP_ADDR=:8200 \
    MISE_HIDE_UPDATE_WARNING=1 \
    PATH="/usr/local/bin:/usr/bin:/bin"

EXPOSE 8200

ENTRYPOINT ["tini", "--"]
CMD ["/entrypoint.sh"]
