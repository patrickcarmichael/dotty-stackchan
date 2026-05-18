#!/usr/bin/env bash
# scripts/setup-wizard.sh — Dotty first-run / re-run setup wizard.
#
# Issue #11: the previous wizard sed-mutated tracked files (`.config.yaml`,
# `docker-compose.yml`, `zeroclaw-bridge.service`) in place, so re-running it
# after the first time was a no-op (placeholders already substituted) and it
# left a dirty working tree on every run. This script:
#
#   1. Persists wizard answers in `.wizard.env` (gitignored) — re-runs prompt
#      with previous answers as defaults; pressing enter keeps them.
#   2. Renders each `*.template` (tracked) → live file (gitignored) by
#      substituting placeholders. Existing live files are backed up first.
#   3. Derives `timezone_offset` from the IANA TZ name (no more hard-coded
#      +10) using `date +%:z`.
#   4. Detects the NVIDIA Container Toolkit (issue #10) and either enables
#      compose.gpu.yml via .env COMPOSE_FILE, or flips selected_module.ASR
#      from WhisperLocal to FunASR for CPU hosts.
#
# Usage:
#   ./scripts/setup-wizard.sh                # interactive; runs fetch-models + up
#   ./scripts/setup-wizard.sh --regen-only   # re-render from .wizard.env, no prompts, no docker

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

WIZARD_ENV=".wizard.env"

# ── colors ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; RESET='\033[0m'

# ── parse args ──────────────────────────────────────────────────────────
REGEN_ONLY=false
case "${1:-}" in
    --regen-only) REGEN_ONLY=true ;;
    "")           ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *)
        printf "Usage: %s [--regen-only]\n" "$0" >&2
        exit 2 ;;
esac

# ── defaults (sane fallbacks for first run) ─────────────────────────────
XIAOZHI_HOST=""
ZEROCLAW_HOST=""
ZEROCLAW_USER=""
ROBOT_NAME="Dotty"
YOUR_NAME=""
TZ_VALUE=""

# ── load saved answers, if any ──────────────────────────────────────────
if [ -f "$WIZARD_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "./$WIZARD_ENV"
    set +a
fi

# ── interactive prompt with default-from-saved ──────────────────────────
prompt() {
    local var="$1" question="$2"
    local default new
    default="${!var:-}"
    local hint=""
    [ -n "$default" ] && hint=" [$default]"
    read -rp "${question}${hint}: " new
    if [ -n "$new" ]; then
        printf -v "$var" '%s' "$new"
    fi
}

if ! $REGEN_ONLY; then
    printf "\n${BOLD}Dotty setup wizard${RESET}\n"
    if [ -f "$WIZARD_ENV" ]; then
        echo "Loaded saved answers from $WIZARD_ENV — press enter to keep each default."
    else
        echo "First run: answers will be saved to $WIZARD_ENV for next time."
    fi
    echo ""

    prompt XIAOZHI_HOST  "XIAOZHI_HOST  (LAN IP of Docker host,   e.g. 192.168.1.10)"
    prompt ZEROCLAW_HOST "ZEROCLAW_HOST (LAN IP of ZeroClaw host, e.g. 192.168.1.20)"
    prompt ZEROCLAW_USER "ZEROCLAW_USER (SSH user on ZeroClaw host, e.g. dietpi)"
    prompt ROBOT_NAME    "ROBOT_NAME    (name the robot calls itself)"
    prompt YOUR_NAME     "YOUR_NAME     (your name / org, e.g. Brett)"
    prompt TZ_VALUE      "TZ            (IANA timezone, e.g. Australia/Brisbane)"
    echo ""
else
    if [ ! -f "$WIZARD_ENV" ]; then
        printf "${RED}Error: --regen-only requires an existing %s. Run 'make setup' first.${RESET}\n" "$WIZARD_ENV" >&2
        exit 1
    fi
    printf "\n${BOLD}Regenerating config from %s (no prompts)...${RESET}\n" "$WIZARD_ENV"
fi

# ── validate ────────────────────────────────────────────────────────────
for v in XIAOZHI_HOST ZEROCLAW_HOST ZEROCLAW_USER ROBOT_NAME YOUR_NAME TZ_VALUE; do
    if [ -z "${!v:-}" ]; then
        printf "${RED}Error: %s is required.${RESET}\n" "$v" >&2
        exit 1
    fi
done

# ── derive timezone_offset from TZ ──────────────────────────────────────
# `date +%:z` → "+10:00" / "-05:00" / "+05:30". Strip trailing ":00" for
# whole-hour zones so we keep the same shape (`+10`) the existing config used.
if ! TIMEZONE_OFFSET="$(TZ="$TZ_VALUE" date +%:z 2>/dev/null)"; then
    printf "${RED}Error: invalid TZ '%s' (date failed).${RESET}\n" "$TZ_VALUE" >&2
    exit 1
fi
case "$TIMEZONE_OFFSET" in
    *:00) TIMEZONE_OFFSET="${TIMEZONE_OFFSET%:00}" ;;
esac

# ── persist answers atomically ──────────────────────────────────────────
if ! $REGEN_ONLY; then
    tmp_env="$(mktemp "${WIZARD_ENV}.XXXXXX")"
    cat >"$tmp_env" <<EOF
# Dotty setup wizard — saved answers (issue #11).
# Edit and re-run \`make setup\` (or \`make regen-config\` for no-prompt regen)
# to apply changes. Safe to delete to force a fresh first-run flow.
XIAOZHI_HOST=$XIAOZHI_HOST
ZEROCLAW_HOST=$ZEROCLAW_HOST
ZEROCLAW_USER=$ZEROCLAW_USER
ROBOT_NAME=$ROBOT_NAME
YOUR_NAME=$YOUR_NAME
TZ_VALUE=$TZ_VALUE
EOF
    mv "$tmp_env" "$WIZARD_ENV"
    chmod 600 "$WIZARD_ENV"
fi

# ── GPU detect → decide ASR + compose.gpu.yml override ─────────────────
# Done BEFORE template rendering so ASR_PROVIDER feeds into the render and
# the live file stays bit-stable across re-runs (no spurious backups).
printf "\n${BOLD}Detecting GPU runtime...${RESET}\n"
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    printf "  ${GREEN}NVIDIA Container Toolkit detected — selecting WhisperLocal ASR + enabling compose.gpu.yml${RESET}\n"
    ASR_PROVIDER="WhisperLocal"
    touch .env
    if grep -q '^COMPOSE_FILE=' .env; then
        sed -i 's|^COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:compose.gpu.yml|' .env
    else
        echo 'COMPOSE_FILE=docker-compose.yml:compose.gpu.yml' >> .env
    fi
else
    printf "  ${YELLOW}No NVIDIA Container Toolkit — selecting FunASR (CPU-friendly).${RESET}\n"
    ASR_PROVIDER="FunASR"
    if [ -f .env ] && grep -q '^COMPOSE_FILE=.*compose\.gpu\.yml' .env; then
        sed -i '/^COMPOSE_FILE=.*compose\.gpu\.yml/d' .env
        printf "  Removed stale COMPOSE_FILE override from .env\n"
    fi
fi

# ── render each *.template → live file ──────────────────────────────────
TEMPLATES=(
    ".config.yaml.template"
    "docker-compose.yml.template"
    "zeroclaw-bridge.service.template"
)

# Single sed program reused for both diff-vs-existing and rewrite. Keep this
# in sync with the placeholders documented in `.config.yaml.template` etc.
render() {
    sed \
        -e "s|<XIAOZHI_HOST>|$XIAOZHI_HOST|g" \
        -e "s|<ZEROCLAW_HOST>|$ZEROCLAW_HOST|g" \
        -e "s|<ZEROCLAW_USER>|$ZEROCLAW_USER|g" \
        -e "s|<ROBOT_NAME>|$ROBOT_NAME|g" \
        -e "s|<YOUR_NAME>|$YOUR_NAME|g" \
        -e "s|<TZ>|$TZ_VALUE|g" \
        -e "s|<TIMEZONE_OFFSET>|$TIMEZONE_OFFSET|g" \
        -e "s|<ASR_PROVIDER>|$ASR_PROVIDER|g" \
        "$1"
}

printf "\n${BOLD}Rendering templates...${RESET}\n"
for src in "${TEMPLATES[@]}"; do
    if [ ! -f "$src" ]; then
        printf "  ${YELLOW}skip${RESET}    %s — not found\n" "$src"
        continue
    fi
    dst="${src%.template}"
    if [ -f "$dst" ] && ! diff -q <(render "$src") "$dst" >/dev/null 2>&1; then
        ts="$(date +%Y%m%d-%H%M%S)"
        cp "$dst" "${dst}.bak.${ts}"
        printf "  ${YELLOW}backup${RESET}  %s → %s.bak.%s\n" "$dst" "$dst" "$ts"
    fi
    render "$src" > "$dst"
    printf "  ${GREEN}render${RESET}  %s → %s\n" "$src" "$dst"
done

if $REGEN_ONLY; then
    printf "\n${GREEN}${BOLD}Config regenerated.${RESET}\n\n"
    exit 0
fi

echo ""
make fetch-models

echo ""
printf "${BOLD}Starting containers...${RESET}\n"
docker compose up -d

printf "\n${GREEN}${BOLD}Setup complete.${RESET}\n\n"
echo "Next steps:"
echo "  1. Flash the StackChan firmware (see SETUP.md or m5stack/StackChan repo)."
echo "  2. In the device's Advanced Options, set the OTA URL to:"
echo "       http://${XIAOZHI_HOST}:8003/xiaozhi/ota/"
echo "  3. Deploy zeroclaw-bridge.service to the ZeroClaw host and start it."
echo "  4. Run 'make doctor' to verify everything is healthy."
echo ""
