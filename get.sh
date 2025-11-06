#!/usr/bin/env bash
set -euo pipefail

# Actuated Agent installer.
# Copyright OpenFaaS Ltd 2025

# On GCP, SSDs are ephemeral and wiped on every reboot.
# Therefore, an additional "reset-pool" service is added to run before actuated.

# ---------- User-provided env (override when running) ----------
LICENSE="${LICENSE:-}"                     # License purchased from subscribe.openfaas.com
TOKEN="${TOKEN:-}"                         # Long lived API token for joining agents
ENDPOINT="${ENDPOINT:-}"                   # optional
VM_DEV="${VM_DEV:-}"                       # optional override; if empty we'll try finder
BASE_SIZE="${BASE_SIZE:-}"                 # must be empty so downstream uses its own defaults
SKIP_REGISTRY="${SKIP_REGISTRY:-}"         # optional; if set to "true" we skip registry mirror install
LABELS="${LABELS:-}"                       # optional labels for the agent (as CSV)
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"     # optional; for registry mirror auth
DOCKER_USERNAME="${DOCKER_USERNAME:-}"     # optional; for registry mirror auth
IMAGE_REF="${IMAGE_REF:-}"                 # optional; OCI image ref for the agent
KERNEL_REF="${KERNEL_REF:-}"               # optional; OCI image ref for the kernel
SAN="${SAN:-}"                             # optional; Subject Alternative Name for TLS certs. Use when autodetection is failing. "" or "public" will use checkip.amazon.com to find IP. "egress" will make an outbound connection and capture the IP used (needed for private networks)

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
chmod +x ./agent/*.sh || true

arch=$(uname -m)
if [[ "$arch" == "aarch64" ]]; then
    AGENT_SUFFIX="-arm64"
fi

sudo cp ./agent/agent${AGENT_SUFFIX:-""} /usr/local/bin/agent
sudo cp ./agent/reset-pool.sh /usr/local/bin/

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
  sudo -E agent csr        --token "$TOKEN" --endpoint "$ENDPOINT" --home "$HOME" --san "$SAN"
  sudo -E agent autoenroll --token "$TOKEN" --endpoint "$ENDPOINT" --labels "$LABELS" --home "$HOME" --san "$SAN"
else
  sudo -E agent csr        --token "$TOKEN" --home "$HOME" --san "$SAN"
  sudo -E agent autoenroll --token "$TOKEN" --labels "$LABELS" --home "$HOME" --san "$SAN"
fi

echo "[+] Installing/starting system service"
if [ -n "$IMAGE_REF" ] || [ -n "$KERNEL_REF" ]; then
  echo "[=] Using custom image/kernel references"
  sudo -E agent install-service --image-ref "$IMAGE_REF" --kernel-ref "$KERNEL_REF" --listen-addr "0.0.0.0:"
else
  echo "[=] Using default image/kernel references"
  sudo -E agent install-service --listen-addr "0.0.0.0:"
fi

# If we're in GCP, then SSDs are erased/wiped on every reboot.
# Create a systemd service to run /usr/local/bin/reset-pool.sh on
# boot, making sure we capture VM_DEV

GCP_TEST="$(curl -s --connect-timeout 0.1 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/hostname 2>/dev/null | head -n1)"
if [ $? -eq 0 ] && [ -n "$GCP_TEST" ]; then
  if [ -n "$VM_DEV" ]; then
    echo "[+] Detected GCP environment; installing reset-pool.service for ($VM_DEV)"

cat <<EOF | sudo tee /etc/systemd/system/reset-pool.service > /dev/null
[Unit]
Description=Reset actuated pool
After=local-fs.target
Before=actuated.service containerd.service

[Service]
Type=oneshot
# Even though the disk is wiped, it may contain a filesystem header that needs to be removed.
ExecStartPre=wipefs -f -a ${VM_DEV}
# Containerd thinks the snapshots still exist in devmapper, so we have to "reset" it
ExecStartPre=rm -rf /var/lib/containerd
# Run the reset-pool.sh script to reset the pool.
ExecStart=/usr/local/bin/reset-pool.sh
Environment=VM_DEV=${VM_DEV}
RemainAfterExit=true
Restart=no
User=root

[Install]
WantedBy=multi-user.target
EOF

      sudo systemctl daemon-reload && \
      sudo systemctl enable reset-pool.service
    fi
fi

echo
echo "✅ Actuated agent installed."
echo "   VM_DEV: ${VM_DEV:-<empty>}"
echo "   HOME:   ${HOME}"
if [ ! "$SKIP_REGISTRY" == "true" ]; then
  echo "   REGISTRY MIRROR: OK."
fi
[ -n "$ENDPOINT" ] && echo "   Endpoint: ${ENDPOINT}"
