# OpenClaw gateway + AC2 reference plugin, baked at build time.
#
# Based on the official image. Adds:
#   - build toolchain + libnice (TURN over TCP / TURNs support for node-datachannel)
#   - dbus + gnome-keyring (Secret Service backend for @napi-rs/keyring)
#   - the @algorandfoundation/ac2-open-claw-reference plugin with native
#     addons rebuilt per the plugin's install guide
#   - the pair-manager HTTP service (QR page in front of `openclaw ac2 pair`)

ARG OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_IMAGE}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    python3 \
    libnice-dev \
    libssl-dev \
    dbus \
    dbus-x11 \
    gnome-keyring \
    libsecret-1-0 \
    && rm -rf /var/lib/apt/lists/*

USER node
ENV HOME=/home/node

ARG AC2_PLUGIN_SPEC=npm:@algorandfoundation/ac2-open-claw-reference@1.0.0-canary.3

# 1) Install the plugin (npm install --ignore-scripts under the hood).
RUN node /app/dist/index.js plugins install "${AC2_PLUGIN_SPEC}"

# 2) Rebuild native addons (see plugin README).
#    - @napi-rs/keyring: standard prebuild-install path
#    - node-datachannel: from source against libnice (USE_NICE=1) so TURN over
#      TCP and TURNs work (prebuilt binary uses libjuice, UDP-only for TURN)
RUN set -eux; \
    PLUGIN_DIR="$(find "${HOME}/.openclaw/npm/projects" -maxdepth 1 -mindepth 1 -type d \( -name 'algorandfoundation-ac2-open-claw-reference-*' -o -name '@algorandfoundation+ac2-open-claw-reference*' -o -name 'ac2-open-claw-reference*' \) | head -n1)"; \
    test -n "$PLUGIN_DIR"; \
    npm rebuild --prefix "$PLUGIN_DIR" @napi-rs/keyring; \
    NDC="$PLUGIN_DIR/node_modules/node-datachannel"; \
    test -d "$NDC"; \
    cd "$NDC"; \
    npm install --ignore-scripts --production=false; \
    npx cmake-js clean; \
    npx cmake-js configure --CDUSE_NICE=1; \
    npx cmake-js build; \
    # trim build intermediates to keep the image smaller
    rm -rf "$NDC/build/CMakeFiles" || true

# 3) Enable the plugin and wire channel + tools into openclaw.json.
#    This config (plus the installed plugin tree) lives in the image's
#    /home/node/.openclaw and seeds the named Docker volume on first run.
RUN node /app/dist/index.js plugins enable ac2-open-claw-reference \
    && node /app/dist/index.js ac2 setup

# 4) Pair-manager HTTP service.
COPY --chown=node:node pair-manager /app/pair-manager

EXPOSE 18789 8377
