SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Model URLs ───────────────────────────────────────────────────────
SENSEVOICE_REPO  := https://huggingface.co/FunAudioLLM/SenseVoiceSmall
PIPER_BASE       := https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/cori/medium
PIPER_ONNX       := en_GB-cori-medium.onnx
PIPER_JSON       := en_GB-cori-medium.onnx.json
WHISPER_REPO     := https://huggingface.co/Systran/faster-whisper-small.en
WHISPER_DIR      := models/whisper-small.en-ct2
WHISPER_FILES    := config.json model.bin tokenizer.json vocabulary.txt

# ── Colours ──────────────────────────────────────────────────────────
GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[0;33m
BOLD   := \033[1m
RESET  := \033[0m

# ── Targets ──────────────────────────────────────────────────────────
.PHONY: help setup regen-config fetch-models doctor audit up down logs status voice-list voice-install sbom verify-firmware test lint check _preflight-compose

# ─────────────────────────────────────────────────────────────────────
# _preflight-compose — fail fast if Docker Compose v2 plugin is missing
#
# Issue #6: on Ubuntu 24.04 with the distro `docker.io` package, only
# the legacy v1 `docker-compose` (Python, separate binary) is shipped.
# `docker compose <subcmd>` either errors with "is not a docker
# command" or routes args into a parser that rejects flags like `-d`
# with "unknown shorthand flag". Either way the user sees a cryptic
# failure inside whatever target they invoked. Catch it up front with
# install guidance instead.
# ─────────────────────────────────────────────────────────────────────
_preflight-compose:
	@if ! docker compose version >/dev/null 2>&1; then \
	  echo ""; \
	  echo -e "$(RED)Error: Docker Compose v2 plugin is not available.$(RESET)"; \
	  echo ""; \
	  echo "This Makefile requires the v2 plugin (the 'docker compose'"; \
	  echo "subcommand, no hyphen). The legacy 'docker-compose' binary"; \
	  echo "is not supported."; \
	  echo ""; \
	  echo "Install on Debian/Ubuntu:"; \
	  echo "    sudo apt install docker-compose-plugin"; \
	  echo ""; \
	  echo "Other distros / manual install:"; \
	  echo "    https://docs.docker.com/compose/install/linux/"; \
	  echo ""; \
	  exit 1; \
	fi

help: ## Show this help
	@echo ""
	@echo -e "$(BOLD)Dotty$(RESET) — your self-hosted StackChan robot assistant"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BOLD)%-15s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─────────────────────────────────────────────────────────────────────
# Dev-loop targets — same commands CI runs, single source of truth.
# Assumes a venv with `pytest pytest-cov ruff` available on PATH. If
# you use a project venv, run e.g.  `source .venv/bin/activate && make check`.
# ─────────────────────────────────────────────────────────────────────
test: ## Run Python unit tests with coverage gate
	pytest tests/ custom-providers/pi_voice/tests/ \
		--cov --cov-report=term --cov-fail-under=56

lint: ## Run ruff lint over the repo
	ruff check .

check: lint test ## Run lint + tests (the CI gate)

# ─────────────────────────────────────────────────────────────────────
# setup — interactive first-run wizard (idempotent; see scripts/setup-wizard.sh)
#
# Issue #11: the wizard now renders gitignored live config files from
# tracked *.template counterparts using answers persisted in .wizard.env,
# so re-running it doesn't dirty the working tree.
# ─────────────────────────────────────────────────────────────────────
setup: _preflight-compose ## Interactive first-run/re-run wizard (prompts use saved answers as defaults)
	@./scripts/setup-wizard.sh

regen-config: ## Re-render live configs from templates + .wizard.env (no prompts)
	@./scripts/setup-wizard.sh --regen-only

# ─────────────────────────────────────────────────────────────────────
# fetch-models — download ASR + TTS model files
# ─────────────────────────────────────────────────────────────────────
SENSEVOICE_FILES := model.pt config.yaml tokens.json configuration.json am.mvn chn_jpn_yue_eng_ko_spectral.fbank.conf.yaml
SENSEVOICE_DIR   := models/SenseVoiceSmall
PIPER_DIR        := models/piper

fetch-models: ## Download SenseVoiceSmall + Piper voice models
	@echo ""
	@echo -e "$(BOLD)Fetching models...$(RESET)"
	@echo ""
	@# ── SenseVoiceSmall ──
	@mkdir -p $(SENSEVOICE_DIR)
	@echo -e "$(BOLD)[SenseVoiceSmall]$(RESET)"
	@for f in $(SENSEVOICE_FILES); do \
	  if [ -f "$(SENSEVOICE_DIR)/$$f" ]; then \
	    echo -e "  $(GREEN)$$f — already exists, skipping$(RESET)"; \
	  else \
	    echo "  Downloading $$f ..."; \
	    curl -# -L -o "$(SENSEVOICE_DIR)/$$f" \
	      "$(SENSEVOICE_REPO)/resolve/main/$$f" || \
	      { echo -e "  $(RED)Failed to download $$f$(RESET)"; exit 1; }; \
	  fi; \
	done
	@echo ""
	@# ── Piper voice ──
	@mkdir -p $(PIPER_DIR)
	@echo -e "$(BOLD)[Piper TTS — $(PIPER_ONNX)]$(RESET)"
	@if [ -f "$(PIPER_DIR)/$(PIPER_ONNX)" ]; then \
	  echo -e "  $(GREEN)$(PIPER_ONNX) — already exists, skipping$(RESET)"; \
	else \
	  echo "  Downloading $(PIPER_ONNX) (this is ~75 MB)..."; \
	  curl -# -L -o "$(PIPER_DIR)/$(PIPER_ONNX)" \
	    "$(PIPER_BASE)/$(PIPER_ONNX)" || \
	    { echo -e "  $(RED)Failed to download $(PIPER_ONNX)$(RESET)"; exit 1; }; \
	fi
	@if [ -f "$(PIPER_DIR)/$(PIPER_JSON)" ]; then \
	  echo -e "  $(GREEN)$(PIPER_JSON) — already exists, skipping$(RESET)"; \
	else \
	  echo "  Downloading $(PIPER_JSON)..."; \
	  curl -# -L -o "$(PIPER_DIR)/$(PIPER_JSON)" \
	    "$(PIPER_BASE)/$(PIPER_JSON)" || \
	    { echo -e "  $(RED)Failed to download $(PIPER_JSON)$(RESET)"; exit 1; }; \
	fi
	@echo ""
	@# ── faster-whisper small.en (CTranslate2) ──
	@mkdir -p $(WHISPER_DIR)
	@echo -e "$(BOLD)[faster-whisper small.en]$(RESET)"
	@for f in $(WHISPER_FILES); do \
	  if [ -f "$(WHISPER_DIR)/$$f" ]; then \
	    echo -e "  $(GREEN)$$f — already exists, skipping$(RESET)"; \
	  else \
	    echo "  Downloading $$f ..."; \
	    curl -# -L -o "$(WHISPER_DIR)/$$f" \
	      "$(WHISPER_REPO)/resolve/main/$$f" || \
	      { echo -e "  $(RED)Failed to download $$f$(RESET)"; exit 1; }; \
	  fi; \
	done
	@echo ""
	@echo -e "$(GREEN)All models ready.$(RESET)"

# ─────────────────────────────────────────────────────────────────────
# sbom — generate a component+license inventory (sbom.json at repo root)
# ─────────────────────────────────────────────────────────────────────
sbom: ## Generate Software Bill of Materials (sbom.json)
	@./scripts/generate-sbom.sh

# ─────────────────────────────────────────────────────────────────────
# doctor — health checks
# ─────────────────────────────────────────────────────────────────────
doctor: ## Run health checks on config, models, and services
	@echo ""
	@echo -e "$(BOLD)Running health checks...$(RESET)"
	@echo ""
	@PASS=0; FAIL=0; \
	 check() { \
	   if eval "$$2" >/dev/null 2>&1; then \
	     echo -e "  $(GREEN)PASS$(RESET)  $$1"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo -e "  $(RED)FAIL$(RESET)  $$1"; \
	     FAIL=$$((FAIL+1)); \
	   fi; \
	 }; \
	 check ".config.yaml exists" "test -f .config.yaml"; \
	 if grep -qE '<[A-Z_]+>' .config.yaml 2>/dev/null; then \
	   echo -e "  $(RED)FAIL$(RESET)  .config.yaml has no unsubstituted placeholders"; \
	   FAIL=$$((FAIL+1)); \
	 else \
	   echo -e "  $(GREEN)PASS$(RESET)  .config.yaml has no unsubstituted placeholders"; \
	   PASS=$$((PASS+1)); \
	 fi; \
	 check "models/SenseVoiceSmall/ has files" "ls $(SENSEVOICE_DIR)/*.pt >/dev/null 2>&1 || ls $(SENSEVOICE_DIR)/*.yaml >/dev/null 2>&1"; \
	 check "models/piper/*.onnx exists" "ls $(PIPER_DIR)/*.onnx >/dev/null 2>&1"; \
	 check "docker compose config validates" "docker compose config --quiet"; \
	 if grep -qE '^\s*ASR:\s*WhisperLocal' .config.yaml 2>/dev/null && \
	    grep -qE '^\s*device:\s*cuda' .config.yaml 2>/dev/null; then \
	   if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then \
	     echo -e "  $(GREEN)PASS$(RESET)  WhisperLocal+cuda has nvidia runtime available"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo -e "  $(RED)FAIL$(RESET)  WhisperLocal selected with device: cuda but no NVIDIA Container Toolkit (see compose.gpu.yml, or flip ASR to FunASR)"; \
	     FAIL=$$((FAIL+1)); \
	   fi; \
	 fi; \
	 XIAOZHI_HOST=$$(grep -oP 'ws://\K[0-9.]+' .config.yaml 2>/dev/null | head -1); \
	 ZEROCLAW_HOST=$$(grep -oP 'url: http://\K[0-9.]+' .config.yaml 2>/dev/null | head -1); \
	 if [ -n "$$XIAOZHI_HOST" ]; then \
	   if curl -sf --max-time 3 "http://$$XIAOZHI_HOST:8003/xiaozhi/ota/" >/dev/null 2>&1; then \
	     echo -e "  $(GREEN)PASS$(RESET)  OTA endpoint reachable ($$XIAOZHI_HOST:8003)"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo -e "  $(RED)FAIL$(RESET)  OTA endpoint reachable ($$XIAOZHI_HOST:8003)"; \
	     FAIL=$$((FAIL+1)); \
	   fi; \
	 else \
	   echo -e "  $(YELLOW)SKIP$(RESET)  OTA endpoint (could not extract XIAOZHI_HOST from config)"; \
	 fi; \
	 if [ -n "$$ZEROCLAW_HOST" ]; then \
	   if curl -sf --max-time 3 "http://$$ZEROCLAW_HOST:8080/health" >/dev/null 2>&1; then \
	     echo -e "  $(GREEN)PASS$(RESET)  Bridge /health reachable ($$ZEROCLAW_HOST:8080)"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo -e "  $(RED)FAIL$(RESET)  Bridge /health reachable ($$ZEROCLAW_HOST:8080)"; \
	     FAIL=$$((FAIL+1)); \
	   fi; \
	 else \
	   echo -e "  $(YELLOW)SKIP$(RESET)  Bridge /health (could not extract ZEROCLAW_HOST from config)"; \
	 fi; \
	 echo ""; \
	 echo -e "$(BOLD)Results: $$PASS passed, $$FAIL failed.$(RESET)"; \
	 echo ""; \
	 if [ $$FAIL -gt 0 ]; then exit 1; fi

# ─────────────────────────────────────────────────────────────────────
# audit — verify "local except LLM" network claim
# ─────────────────────────────────────────────────────────────────────
audit: ## Audit outbound network connections (verify local-except-LLM claim)
	@echo ""
	@echo -e "$(BOLD)Network audit — verifying 'local except LLM' claim$(RESET)"
	@echo ""
	@XIAOZHI_HOST=$$(grep -oP 'ws://\K[0-9.]+' .config.yaml 2>/dev/null | head -1); \
	 ZEROCLAW_HOST=$$(grep -oP 'url: http://\K[0-9.]+' .config.yaml 2>/dev/null | head -1); \
	 PASS=0; FAIL=0; WARN=0; \
	 echo -e "$(BOLD)Server host (Docker):$(RESET)"; \
	 if [ -n "$$XIAOZHI_HOST" ]; then \
	   echo "  Checking outbound connections on $$XIAOZHI_HOST..."; \
	   CONNS=$$(ssh -o ConnectTimeout=5 root@$$XIAOZHI_HOST \
	     'ss -tnp | grep -v "127.0.0.1\|::1" | grep "ESTAB"' 2>/dev/null); \
	   if [ -z "$$CONNS" ]; then \
	     echo -e "  $(GREEN)PASS$(RESET)  No outbound connections (fully local)"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo "$$CONNS" | while read line; do echo "  $$line"; done; \
	     LLM=$$(echo "$$CONNS" | grep -cE "openrouter|cloudflare|anthropic" || true); \
	     OTHER=$$(echo "$$CONNS" | grep -cvE "openrouter|cloudflare|anthropic|tailscale|100\." || true); \
	     if [ "$$OTHER" -gt 0 ]; then \
	       echo -e "  $(RED)FAIL$(RESET)  Unexpected external connections detected"; \
	       FAIL=$$((FAIL+1)); \
	     else \
	       echo -e "  $(GREEN)PASS$(RESET)  Only LLM/Tailscale connections (expected)"; \
	       PASS=$$((PASS+1)); \
	     fi; \
	   fi; \
	 else \
	   echo -e "  $(YELLOW)SKIP$(RESET)  Could not extract server IP from config"; \
	   WARN=$$((WARN+1)); \
	 fi; \
	 echo ""; \
	 echo -e "$(BOLD)Bridge host (ZeroClaw host):$(RESET)"; \
	 if [ -n "$$ZEROCLAW_HOST" ]; then \
	   echo "  Checking outbound connections on $$ZEROCLAW_HOST..."; \
	   CONNS=$$(ssh -o ConnectTimeout=5 dietpi@$$ZEROCLAW_HOST \
	     'ss -tnp | grep -v "127.0.0.1\|::1" | grep "ESTAB"' 2>/dev/null); \
	   if [ -z "$$CONNS" ]; then \
	     echo -e "  $(GREEN)PASS$(RESET)  No outbound connections"; \
	     PASS=$$((PASS+1)); \
	   else \
	     echo "$$CONNS" | while read line; do echo "  $$line"; done; \
	     OTHER=$$(echo "$$CONNS" | grep -cvE "openrouter|cloudflare|anthropic|tailscale|100\." || true); \
	     if [ "$$OTHER" -gt 0 ]; then \
	       echo -e "  $(RED)FAIL$(RESET)  Unexpected external connections detected"; \
	       FAIL=$$((FAIL+1)); \
	     else \
	       echo -e "  $(GREEN)PASS$(RESET)  Only LLM/Tailscale connections (expected)"; \
	       PASS=$$((PASS+1)); \
	     fi; \
	   fi; \
	 else \
	   echo -e "  $(YELLOW)SKIP$(RESET)  Could not extract bridge IP from config"; \
	   WARN=$$((WARN+1)); \
	 fi; \
	 echo ""; \
	 echo -e "$(BOLD)Docker container (no external mounts):$(RESET)"; \
	 MOUNTS=$$(docker compose exec -T xiaozhi-esp32-server mount 2>/dev/null | \
	   grep -v "overlay\|proc\|sys\|dev\|tmpfs\|cgroup\|mqueue\|shm" || true); \
	 if [ -z "$$MOUNTS" ]; then \
	   echo -e "  $(GREEN)PASS$(RESET)  No unexpected filesystem mounts"; \
	   PASS=$$((PASS+1)); \
	 else \
	   echo "$$MOUNTS" | while read line; do echo "  $$line"; done; \
	   echo -e "  $(YELLOW)WARN$(RESET)  Review mounts above"; \
	   WARN=$$((WARN+1)); \
	 fi; \
	 echo ""; \
	 echo -e "$(BOLD)Results: $$PASS passed, $$FAIL failed, $$WARN warnings.$(RESET)"; \
	 echo ""; \
	 if [ $$FAIL -gt 0 ]; then exit 1; fi

# ─────────────────────────────────────────────────────────────────────
# Docker shortcuts
# ─────────────────────────────────────────────────────────────────────
up: _preflight-compose ## Start containers (docker compose up -d)
	docker compose up -d

down: _preflight-compose ## Stop containers (docker compose down)
	docker compose down

logs: _preflight-compose ## Tail container logs (docker compose logs -f)
	docker compose logs -f

voice-list: ## List curated Piper voices (see docs/voice-catalog.md)
	@./scripts/voice-install.sh --list

voice-install: ## Install a curated Piper voice (VOICE=<key> [APPLY=1])
	@if [ -z "$(VOICE)" ]; then \
	  echo -e "$(RED)Error: VOICE is required.$(RESET)  Example: make voice-install VOICE=en_US-kristin-medium"; \
	  echo "Run 'make voice-list' to see the catalog."; \
	  exit 2; \
	fi
	@if [ -n "$(APPLY)" ]; then \
	  ./scripts/voice-install.sh "$(VOICE)" --apply; \
	else \
	  ./scripts/voice-install.sh "$(VOICE)"; \
	fi

# ─────────────────────────────────────────────────────────────────────
# verify-firmware — build + checksum, optionally diff against published
# ─────────────────────────────────────────────────────────────────────
verify-firmware: ## Build firmware in IDF container and compute SHA256 checksums
	@echo ""
	@echo -e "$(BOLD)Firmware reproducibility check$(RESET)"
	@echo ""
	@if ! command -v docker >/dev/null 2>&1; then \
	  echo -e "$(RED)Error: docker is required.$(RESET)"; exit 1; \
	fi
	@if [ ! -f firmware/firmware/CMakeLists.txt ]; then \
	  echo -e "$(RED)Error: firmware submodule not initialised.$(RESET)"; \
	  echo "Run: git submodule update --init --recursive"; \
	  exit 1; \
	fi
	@echo -e "$(BOLD)Fetching firmware deps...$(RESET)"
	docker run --rm -v "$(PWD)/firmware/firmware:/project" -w /project \
	  espressif/idf:v5.5.4 \
	  bash -lc 'git config --global --add safe.directory "*" && python fetch_repos.py'
	@echo -e "$(BOLD)Building firmware...$(RESET)"
	docker run --rm -v "$(PWD)/firmware/firmware:/project" -w /project \
	  espressif/idf:v5.5.4 \
	  bash -lc 'git config --global --add safe.directory "*" && idf.py build'
	@echo -e "$(BOLD)Computing checksums...$(RESET)"
	@sha256sum \
	  firmware/firmware/build/stack-chan.bin \
	  firmware/firmware/build/ota_data_initial.bin \
	  firmware/firmware/build/generated_assets.bin \
	  | tee firmware/firmware/build/SHA256SUMS.txt
	@echo ""
	@if [ -f firmware/firmware/build/SHA256SUMS.published ]; then \
	  echo -e "$(BOLD)Comparing against published checksums...$(RESET)"; \
	  if diff -q firmware/firmware/build/SHA256SUMS.published \
	             firmware/firmware/build/SHA256SUMS.txt >/dev/null 2>&1; then \
	    echo -e "$(GREEN)PASS$(RESET)  Build is reproducible."; \
	  else \
	    echo -e "$(RED)FAIL$(RESET)  Checksums differ:"; \
	    diff firmware/firmware/build/SHA256SUMS.published \
	         firmware/firmware/build/SHA256SUMS.txt; \
	    exit 1; \
	  fi; \
	else \
	  echo -e "$(YELLOW)NOTE$(RESET)  No published SHA256SUMS.published to compare against."; \
	  echo "  To verify a release, download SHA256SUMS.txt from GitHub Releases,"; \
	  echo "  save it as firmware/firmware/build/SHA256SUMS.published, and re-run."; \
	fi
	@echo ""

status: _preflight-compose ## Show container status + bridge health
	@docker compose ps
	@echo ""
	@ZEROCLAW_HOST=$$(grep -oP 'url: http://\K[0-9.]+' .config.yaml 2>/dev/null | head -1); \
	 if [ -n "$$ZEROCLAW_HOST" ]; then \
	   echo -n "Bridge health ($$ZEROCLAW_HOST:8080): "; \
	   curl -sf --max-time 3 "http://$$ZEROCLAW_HOST:8080/health" && echo "" || \
	     echo -e "$(YELLOW)unreachable$(RESET)"; \
	 else \
	   echo -e "Bridge health: $(YELLOW)could not extract ZEROCLAW_HOST from config$(RESET)"; \
	 fi
