#!/usr/bin/env bash
# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# setup-s3-backend.sh - Deploy Rook/Ceph with a single-node RGW into the
# current kubectl context and emit a Chainsaw-compatible S3 credentials
# values file.
#
# Owned by the sample driver: this driver is the component that interfaces
# directly with the S3 backend, so the backend tooling lives here. The
# container-object-storage-interface (cosi) Prow CI calls this script to
# stand up its E2E S3 backend.
#
# Scope: maintained for our Prow CI environment. May work on a local
# cluster with extra raw disks attached, but local environments are not a
# supported target - we keep maintenance focused on CI.
#
# Output: a YAML values file with the S3 credentials, written to
# ${OUT_CREDS_FILE:-./s3-credentials.yaml}.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOK_DIR="${SCRIPT_DIR}/rook"

ROOK_VERSION="${ROOK_VERSION:-v1.19.4}"
ROOK_RAW_BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"

ROOK_NS="rook-ceph"

OBJECT_STORE="my-store"
OBJECT_USER="my-user"
USER_SECRET="rook-ceph-object-user-${OBJECT_STORE}-${OBJECT_USER}"

OUT_CREDS_FILE="${OUT_CREDS_FILE:-${PWD}/s3-credentials.yaml}"

# When true, Rook is configured to discover /dev/loop* devices and the
# CephCluster's storage.deviceFilter is scoped to loop devices only. Used by
# the COSI Prow CI, where OSDs are backed by loop-mounted files on a kind
# node (see hack/setup-kind.sh in the container-object-storage-interface
# repo). Default false: real disks should not opt into loop discovery.
LOOP_DEVICE_OSDS="${LOOP_DEVICE_OSDS:-false}"

# ---------------------------------------------------------------------------
# Apply everything up front. CRDs must land first (server-side) so the
# CephCluster/CephObjectStore/CephObjectStoreUser objects are recognized; the
# rest can race - Rook's reconcilers handle ordering. We then wait on the
# statuses that actually matter for the e2e suite.
# ---------------------------------------------------------------------------
echo "==> Applying Rook CRDs (${ROOK_VERSION})"
kubectl apply --server-side -f "${ROOK_RAW_BASE}/crds.yaml"

echo "==> Applying Rook common/operator/csi-operator + CephCluster + CephObjectStore + CephObjectStoreUser"
kubectl apply -f "${ROOK_RAW_BASE}/common.yaml"
kubectl apply --server-side -f "${ROOK_RAW_BASE}/csi-operator.yaml"
kubectl apply -f "${ROOK_RAW_BASE}/operator.yaml"

if [ "${LOOP_DEVICE_OSDS}" = "true" ]; then
  # ROOK_CEPH_ALLOW_LOOP_DEVICES: Rook skips loop devices by default; the
  # operator config toggle opts back in.
  kubectl -n "${ROOK_NS}" patch configmap rook-ceph-operator-config \
    --type merge \
    -p '{"data":{"ROOK_CEPH_ALLOW_LOOP_DEVICES":"true"}}'

  # deviceFilter: the upstream cluster-test.yaml uses useAllDevices: true,
  # which would grab every /dev/[sh]d? on the runner too. Scope OSD
  # discovery to loop devices only so the runner's system disk is untouched.
  curl --fail --location --silent "${ROOK_RAW_BASE}/cluster-test.yaml" \
    | sed '/useAllDevices: true/a\    deviceFilter: "^loop[0-9]+$"' \
    | kubectl apply -f -
else
  kubectl apply -f "${ROOK_RAW_BASE}/cluster-test.yaml"
fi

kubectl apply -f "${ROOK_RAW_BASE}/object-test.yaml"
kubectl apply -f "${ROOK_DIR}/object-user.yaml"

# ---------------------------------------------------------------------------
# Wait for the statuses required by the e2e suite.
# ---------------------------------------------------------------------------
echo "==> Waiting for Rook operator to be Available (up to 2 min)"
kubectl -n "${ROOK_NS}" wait deployment rook-ceph-operator \
  --for=condition=Available --timeout=120s

echo "==> Waiting for CephCluster to reach Ready phase (up to 10 min)"
DEADLINE=$(( $(date +%s) + 600 ))
while true; do
  PHASE=$(kubectl get cephcluster my-cluster -n "${ROOK_NS}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${PHASE}" = "Ready" ]; then
    echo "  CephCluster is Ready"
    break
  fi
  if [ "$(date +%s)" -gt "${DEADLINE}" ]; then
    echo "ERROR: CephCluster did not reach Ready within 10 minutes (phase=${PHASE})"
    kubectl describe cephcluster my-cluster -n "${ROOK_NS}" || true
    exit 1
  fi
  echo "  phase=${PHASE:-<pending>}, retrying in 15s..."
  sleep 15
done

echo "==> Waiting for RGW pods to be Ready (up to 5 min)"
DEADLINE=$(( $(date +%s) + 300 ))
while true; do
  if kubectl get pod -n "${ROOK_NS}" -l "app=rook-ceph-rgw,rgw=${OBJECT_STORE}" \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
    | grep -qw true; then
    echo "  RGW pod ready"
    break
  fi
  if [ "$(date +%s)" -gt "${DEADLINE}" ]; then
    echo "ERROR: RGW pod did not become Ready within 5 minutes"
    kubectl get pods -n "${ROOK_NS}" -l "app=rook-ceph-rgw,rgw=${OBJECT_STORE}" || true
    exit 1
  fi
  echo "  waiting for RGW pod..."
  sleep 10
done

echo "==> Waiting for CephObjectStoreUser secret to appear (up to 2 min)"
DEADLINE=$(( $(date +%s) + 120 ))
while true; do
  if kubectl get secret "${USER_SECRET}" -n "${ROOK_NS}" >/dev/null 2>&1; then
    echo "  secret ${USER_SECRET} found"
    break
  fi
  if [ "$(date +%s)" -gt "${DEADLINE}" ]; then
    echo "ERROR: secret ${USER_SECRET} did not appear within 2 minutes"
    kubectl get cephobjectstoreuser "${OBJECT_USER}" -n "${ROOK_NS}" -o yaml || true
    exit 1
  fi
  echo "  waiting for secret..."
  sleep 5
done

# ---------------------------------------------------------------------------
# Extract credentials and write the values file.
# ---------------------------------------------------------------------------
echo "==> Extracting S3 credentials from secret ${USER_SECRET}"

ACCESS_KEY=$(kubectl get secret "${USER_SECRET}" -n "${ROOK_NS}" \
  -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret "${USER_SECRET}" -n "${ROOK_NS}" \
  -o jsonpath='{.data.SecretKey}' | base64 -d)

# The RGW Service is created by Rook with the name rook-ceph-rgw-<store>.
ENDPOINT="http://rook-ceph-rgw-${OBJECT_STORE}.${ROOK_NS}.svc.cluster.local"

mkdir -p "$(dirname "${OUT_CREDS_FILE}")"
cat > "${OUT_CREDS_FILE}" <<EOF
# Generated by hack/setup-s3-backend.sh - DO NOT EDIT or commit.
# Re-run hack/setup-s3-backend.sh to refresh after cluster recreation.
s3Endpoint: "${ENDPOINT}"
# RGW accepts any region; AWS SDK v2 rejects empty strings, so use a placeholder.
s3Region: "us-east-1"
adminAccessKeyId: "${ACCESS_KEY}"
adminSecretAccessKey: "${SECRET_KEY}"
accessKeyId: "${ACCESS_KEY}"
accessSecretKey: "${SECRET_KEY}"
EOF

echo "==> Rook setup complete."
echo "    Credentials written to ${OUT_CREDS_FILE}"
echo "    Endpoint : ${ENDPOINT}"
echo "    AccessKey: ${ACCESS_KEY}"
