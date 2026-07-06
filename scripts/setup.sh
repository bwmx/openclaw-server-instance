#!/usr/bin/env bash
# One-shot setup on the Ubuntu server. Run from the repo root:
#   ./scripts/setup.sh
#
# Steps:
#   1. generate .env (tokens) if missing
#   2. build the image (openclaw + AC2 plugin + native rebuilds)
#   3. run OpenClaw onboarding (interactive: provider/API key)
#   4. set gateway config + verify plugin wiring
#   5. start the stack
set -euo pipefail
cd "$(dirname "$0")/.."

command -v docker >/dev/null || { echo "docker is required"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose v2 is required"; exit 1; }

sed_in_place() {
  local expression="$1"
  local file="$2"

  sed -i.bak "$expression" "$file"
  rm -f "${file}.bak"
}

# --- 1. .env ---------------------------------------------------------------
if [[ ! -f .env ]]; then
  echo "==> Generating .env"
  cp .env.example .env
  sed_in_place "s/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)/" .env
  sed_in_place "s/^PAIR_TOKEN=.*/PAIR_TOKEN=$(openssl rand -hex 24)/" .env
else
  echo "==> .env exists, keeping it"
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

# --- 2. build ---------------------------------------------------------------
echo "==> Building image (this compiles node-datachannel from source; needs ~2GB RAM)"
docker compose build openclaw-gateway

# --- 3. onboarding / provider config (first run only) ----------------------
# The named volume is seeded from the image on first use; onboarding writes
# provider auth + gateway token into it. Run before the gateway starts.
#
# If GOOGLE_API_KEY is set in .env the setup is fully non-interactive:
# the gateway config and provider key are written via `config set` and the
# onboarding walkthrough is skipped entirely.
# If GOOGLE_API_KEY is not set, the traditional interactive walkthrough runs.
ONBOARDED=$(docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  -e "try{require('fs').accessSync('/home/node/.openclaw/.onboarded');console.log('yes')}catch{console.log('no')}" 2>/dev/null | tail -n1 || echo no)
if [[ "$ONBOARDED" != "yes" ]]; then
  # Baking the AC2 plugin install into the image (Dockerfile) auto-adds it to
  # plugins.allow, turning that array into a restrictive allowlist. Left in
  # place, it blocks onboarding from enabling any other plugin — including
  # the built-in model-provider plugins (e.g. Gemini) — with "<provider>
  # plugin is disabled (blocked by allowlist)". Clear it before onboarding
  # runs so provider selection isn't blocked; AC2 stays enabled via its own
  # plugins.entries record.
  docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
    dist/index.js config unset plugins.allow || true

  if [[ -n "${GOOGLE_API_KEY:-}" ]]; then
    echo "==> Auto-configuring OpenClaw with Google API key (non-interactive)"
    # Set static gateway config.
    docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
      dist/index.js config set --batch-json '[
        {"path":"gateway.mode","value":"local"},
        {"path":"gateway.bind","value":"lan"}
      ]'
    # Set the Google API key: pass via env so it is JSON-encoded safely and
    # never interpolated raw into shell.
    docker compose run --rm --no-deps \
      -e GOOGLE_API_KEY="${GOOGLE_API_KEY}" \
      --entrypoint node openclaw-gateway \
      -e "const cp=require('child_process');
          cp.execFileSync('node',['/app/dist/index.js','config','set','--batch-json',
            JSON.stringify([{path:'providers.google.apiKey',value:process.env.GOOGLE_API_KEY}])
          ],{stdio:'inherit'})"
  else
    echo "==> Running OpenClaw onboarding (interactive)"
    docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
      dist/index.js onboard --mode local --no-install-daemon || {
        echo "Onboarding failed or was cancelled. Re-run: ./scripts/setup.sh"; exit 1; }
  fi

  docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
    -e "require('fs').writeFileSync('/home/node/.openclaw/.onboarded','1')"
else
  echo "==> Onboarding already completed, skipping"
fi

echo "==> Applying gateway config"
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js config set --batch-json '[
    {"path":"gateway.mode","value":"local"},
    {"path":"gateway.bind","value":"lan"}
  ]'

echo "==> Verifying AC2 plugin wiring"
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js plugins enable ac2-open-claw-reference || true
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js ac2 setup || true

# --- 4. start ---------------------------------------------------------------
echo "==> Starting stack"
docker compose up -d

echo
echo "============================================================"
echo " Pairing page:"
echo "   https://${DOMAIN:?set in .env}/?token=${PAIR_TOKEN}"
echo
echo " Open it, press 'Start pairing session', scan the QR."
echo " Sessions auto-expire after $(( ${PAIR_SESSION_TTL_MS:-900000} / 60000 )) minutes."
echo
echo " Firewall reminder (ufw):"
echo "   sudo ufw allow 80/tcp"
echo "   sudo ufw allow 443/tcp"
echo
echo " Cloudflare reminder: DNS record proxied (orange cloud), SSL/TLS mode = Full."
echo "============================================================"
