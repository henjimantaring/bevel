#!/bin/bash
##############################################################################################
#  Copyright Accenture. All Rights Reserved.
#
#  SPDX-License-Identifier: Apache-2.0
##############################################################################################

set -euo pipefail

echo "Starting build process..."

echo "Adding env variables..."
export PATH=/root/bin:$PATH

# Location inside the container where we will place a working kubeconfig for Ansible
KUBECONFIG_TARGET="/home/bevel/build/config"
export KUBECONFIG="${KUBECONFIG_TARGET}"

# --- Configuration: change if your minikube proxy port differs ---
# Use the proxy port shown by `kubectl cluster-info` on the host (example: 56855)
MINIKUBE_PROXY_PORT="${MINIKUBE_PROXY_PORT:-49875}"
# The hostname we want to use inside the container (matches Minikube certificate SAN)
MINIKUBE_HOSTNAME="${MINIKUBE_HOSTNAME:-minikube}"

echo "KUBECONFIG target: ${KUBECONFIG}"
echo "Minikube proxy port: ${MINIKUBE_PROXY_PORT}"
echo "Minikube hostname to use inside container: ${MINIKUBE_HOSTNAME}"

# Ensure we have a source kubeconfig mounted at /root/.kube/config
if [ ! -r /root/.kube/config ]; then
  echo "ERROR: /root/.kube/config not found or unreadable. Make sure you mounted your host kubeconfig into the container (e.g. -v ~/.kube:/root/.kube:ro)"
  exit 2
fi

# Copy to a workspace copy that Ansible can modify/use
mkdir -p "$(dirname "${KUBECONFIG_TARGET}")"
cp /root/.kube/config "${KUBECONFIG_TARGET}"
chmod 600 "${KUBECONFIG_TARGET}"

# Rewrite server address:
# - Replace any 127.0.0.1:<any-port> or host.docker.internal:<port> with "minikube:<MINIKUBE_PROXY_PORT>"
# - Use "minikube" because Minikube certs include the 'minikube' SAN.
sed -E -i "s|https?://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+|https://${MINIKUBE_HOSTNAME}:${MINIKUBE_PROXY_PORT}|g" "${KUBECONFIG_TARGET}"
sed -E -i "s|https?://127\\.0\\.0\\.1:[0-9]+|https://${MINIKUBE_HOSTNAME}:${MINIKUBE_PROXY_PORT}|g" "${KUBECONFIG_TARGET}"
sed -E -i "s|host\\.docker\\.internal:[0-9]+|${MINIKUBE_HOSTNAME}:${MINIKUBE_PROXY_PORT}|g" "${KUBECONFIG_TARGET}"

# Fix certificate file paths that reference macOS /Users/... to the container path we mounted (/root/.minikube)
sed -E -i "s|/Users/[^/]*/\\.minikube|/root/.minikube|g" "${KUBECONFIG_TARGET}"


# Optional: show top of kubeconfig for debugging
echo "=== kubeconfig preview (first 40 lines) ==="
sed -n '1,40p' "${KUBECONFIG_TARGET}" || true
echo "==========================================="

# Validate connectivity quickly (optional; won't fail run unless kubectl fails)
echo "Testing kubectl connectivity..."
if ! kubectl cluster-info --kubeconfig="${KUBECONFIG_TARGET}" >/dev/null 2>&1; then
  echo "Warning: kubectl cluster-info failed. We'll still try to run the playbook, but Ansible 'kubectl' tasks may fail."
  # You can choose to exit here if connection must be present:
  # exit 3
else
  kubectl get nodes --kubeconfig="${KUBECONFIG_TARGET}"
fi

echo "Validating network yaml..."
ajv validate -s /home/bevel/platforms/network-schema.json -d /home/bevel/build/network.yaml

echo "Running the playbook..."
# ensure ansible uses the KUBECONFIG environment
exec env KUBECONFIG="${KUBECONFIG_TARGET}" ansible-playbook -vvv /home/bevel/platforms/shared/configuration/site.yaml \
  --inventory-file=/home/bevel/platforms/shared/inventory/ -e "@/home/bevel/build/network.yaml" -e 'ansible_python_interpreter=/usr/bin/python3'