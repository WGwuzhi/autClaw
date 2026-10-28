# autClaw full runtime image.
#
# Layers the media extras on top of the default (slim) image, so the base
# stays single-sourced in autclaw.Dockerfile.
#
# Build the slim base first, then this file:
#   docker build -f autclaw.Dockerfile -t autclaw:latest .
#   docker build -f autclaw-full.Dockerfile -t autclaw:full .
#
# Or use the published base image directly:
#   docker build -f autclaw-full.Dockerfile \
#       --build-arg AUTCLAW_BASE_IMAGE=nolan1121953/autclaw:latest \
#       -t autclaw:full .
#
# Extras:
# - ffmpeg/libavcodec-extra: libx264/aac/amrnb/opencore/vo_amrwb transcoding
#   for media replies.
#
# No browser is bundled: the chromium package plus its dependency tree costs
# several hundred MB. Screenshot plugins (chromedp / puppeteer / playwright)
# need a browser supplied by the plugin or by the user.
ARG AUTCLAW_BASE_IMAGE=autclaw:latest
FROM ${AUTCLAW_BASE_IMAGE}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libavcodec-extra; \
    ffmpeg -hide_banner -encoders | grep -E 'libx264| aac|amr|opencore|vo_amrwb'; \
    ffmpeg -version >/dev/null; \
    ffprobe -version >/dev/null; \
    rm -rf /var/lib/apt/lists/*
