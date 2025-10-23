#!/usr/bin/env bash
set -euo pipefail

# Actuated Agent installer.
# Copyright OpenFaaS Ltd 2025

# ---------- User-provided env (override when running) ----------
LICENSE="${LICENSE:-}"                     # License purchased from subscribe.openfaas.com
TOKEN="${TOKEN:-}"                         # Long lived API token for joining agents
ENDPOINT="${ENDPOINT:-}"                   # optional
VM_DEV="${VM_DEV:-}"                       # optional override; if empty we'll try finder
BASE_SIZE="${BASE_SIZE:-}"                 # must be empty so downstream uses its own defaults
SKIP_REGISTRY="${SKIP_REGISTRY:-}"         # optional; if set to "true" we skip registry mirror install
LABELS="${LABELS:-}"                       # optional labels for the agent (as CSV)

# Set HOME only if not already set
if [ -z "${HOME:-}" ]; then
  export HOME="/root"
fi

# Basic checks (keep it simple)
[ -n "$LICENSE" ] || { echo "LICENSE is required (export LICENSE=...)"; exit 1; }
[ -n "$TOKEN" ]   || { echo "TOKEN is required (export TOKEN=...)"; exit 1; }

# ---------- Write license ----------
mkdir -p "${HOME}/.actuated"
# Preserve exact content/newlines
echo -n $LICENSE > "${HOME}/.actuated/LICENSE"

# ---------- Always install arkade ----------
echo "[+] Installing arkade"
curl -sLS https://get.arkade.dev | sudo sh

# ---------- Fetch agent (OCI) and install binaries ----------
echo "[+] Pulling actuated agent"
mkdir -p ./agent
arkade oci install ghcr.io/openfaasltd/actuated-agent:latest --path ./agent

echo "[+] Installing agent binaries to /usr/local/bin"
chmod +x ./agent/agent* || true
sudo mv ./agent/agent* /usr/local/bin/

# ---------- Select VM_DEV (respect override; else try finder; else empty) ----------
if [ -z "$VM_DEV" ]; then
  echo "[+] Finding VM device via agent disk find"
  set +e
  FOUND="$(sudo -E agent disk find 2>/dev/null)"
  rc=$?
  set -e
  if [ $rc -eq 0 ] && [ -n "$FOUND" ]; then
    VM_DEV="$FOUND"
    echo "[=] VM_DEV selected: $VM_DEV"
  else
    VM_DEV=""
    echo "[!] No device found by finder; proceeding with VM_DEV empty (downstream handles fallback)"
  fi
else
  echo "[=] Using VM_DEV from environment: $VM_DEV"
fi

# ---------- Run installer script ----------
if [ -x "./agent/install.sh" ]; then
  echo "[+] Running agent install.sh"
  # Pass VM_DEV and empty BASE_SIZE (downstream will default)
  cd agent
  sudo -E env VM_DEV="$VM_DEV" BASE_SIZE="$BASE_SIZE" HOME="$HOME" ./install.sh
else
  echo "[!] ./agent/install.sh not found or not executable; skipping"
fi

# ---------- Install registry mirror ------------

if [ ! "$SKIP_REGISTRY" == "true" ]; then
  if [ -n "$DOCKER_USERNAME" ] && [ -n "$DOCKER_PASSWORD" ]; then
    echo "[+] Installing registry mirror credentials"

    sudo -E arkade system install registry \
      --bind-addr "192.168.128.1:5000" \
      --type mirror \
      --tls=actuated \
      --docker-username "$DOCKER_USERNAME" \
      --docker-password "$DOCKER_PASSWORD" || echo "[!] Failed to install registry mirror; continuing (may be present already)"
  else
    echo "[+] Installing registry mirror with anonymous pull"
    sudo -E arkade system install registry \
      --bind-addr "192.168.128.1:5000" \
      --type mirror \
      --tls=actuated || echo "[!] Failed to install registry mirror; continuing continuing (may be present already)"
  fi
fi

# ---------- Enroll and install service ----------
echo "[+] Enrolling agent"
if [ -n "$ENDPOINT" ]; then
  sudo -E agent csr        --token "$TOKEN" --endpoint "$ENDPOINT" --home "$HOME"
  sudo -E agent autoenroll --token "$TOKEN" --endpoint "$ENDPOINT" --labels "$LABELS" --home "$HOME"
else
  sudo -E agent csr        --token "$TOKEN" --home "$HOME"
  sudo -E agent autoenroll --token "$TOKEN" --labels "$LABELS" --home "$HOME"
fi

echo "[+] Installing/starting system service"
sudo -E agent install-service --listen-addr "0.0.0.0:"

echo
echo "✅ Actuated agent installed."
echo "   VM_DEV: ${VM_DEV:-<empty>}"
echo "   HOME:   ${HOME}"
if [ ! "$SKIP_REGISTRY" == "true" ]; then
  echo "   REGISTRY MIRROR: OK."
fi
[ -n "$ENDPOINT" ] && echo "   Endpoint: ${ENDPOINT}"

