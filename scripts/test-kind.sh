#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "${BASH_SOURCE[0]}")"

CLUSTER_NAME=${CLUSTER_NAME:-evict-rollout}
RELEASE_NAME=${RELEASE_NAME:-evr}
CHART_PATH=${CHART_PATH:-../chart/evict-to-rollout}
CONTROLLER_NAMESPACE=${CONTROLLER_NAMESPACE:-evict-to-rollout}
APP_NAMESPACE=${APP_NAMESPACE:-evict-to-rollout-app}
CRON_FULLNAME="${RELEASE_NAME}-evict-to-rollout"
JOB_NAME="${CRON_FULLNAME}-run-now"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

WORKER_NODE_1="${CLUSTER_NAME}-worker"
WORKER_NODE_2="${CLUSTER_NAME}-worker2"

LOCAL_IMAGE_REPO=${LOCAL_IMAGE_REPO:-evict-to-rollout/kubectl-jq}
LOCAL_IMAGE_TAG=${LOCAL_IMAGE_TAG:-dev}
LOCAL_IMAGE="${LOCAL_IMAGE_REPO}:${LOCAL_IMAGE_TAG}"

cleanup() {
  echo "[cleanup] Tearing down kind cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[build] Building controller image ${LOCAL_IMAGE}"
docker build -f ../Dockerfile.kubectl-jq -t "${LOCAL_IMAGE}" .. >/dev/null

echo "[setup] Creating kind cluster ${CLUSTER_NAME}"
kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml >/dev/null

echo "[setup] Using kube-context ${KUBE_CONTEXT}"
kubectl config use-context "${KUBE_CONTEXT}" >/dev/null

echo "[setup] Loading controller image into kind cluster"
kind load docker-image --name "${CLUSTER_NAME}" "${LOCAL_IMAGE}" >/dev/null

echo "[setup] Temporarily cordoning ${WORKER_NODE_2} to force initial pod placement"
kubectl --context "${KUBE_CONTEXT}" cordon "${WORKER_NODE_2}" >/dev/null

echo "[controller] Installing Helm chart"
helm --kube-context "${KUBE_CONTEXT}" upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${CONTROLLER_NAMESPACE}" \
  --create-namespace \
  --set schedule="*/5 * * * *" \
  --set image.repository="${LOCAL_IMAGE_REPO}" \
  --set image.tag="${LOCAL_IMAGE_TAG}" \
  --set image.pullPolicy="IfNotPresent" >/dev/null

echo "[app] Deploying sample annotated workload"
kubectl --context "${KUBE_CONTEXT}" apply -f testdata/sample-app.yaml >/dev/null

echo "[app] Waiting for sample deployment to become ready"
kubectl --context "${KUBE_CONTEXT}" rollout status deployment/sample-app \
  -n "${APP_NAMESPACE}" --timeout=120s >/dev/null

echo "[setup] Uncordoning ${WORKER_NODE_2}"
kubectl --context "${KUBE_CONTEXT}" uncordon "${WORKER_NODE_2}" >/dev/null

echo "[test] Cordoning target node ${WORKER_NODE_1}"
kubectl --context "${KUBE_CONTEXT}" cordon "${WORKER_NODE_1}" >/dev/null

echo "[test] Triggering controller CronJob manually"
kubectl --context "${KUBE_CONTEXT}" create job "${JOB_NAME}" \
  --from=cronjob/${CRON_FULLNAME} \
  -n "${CONTROLLER_NAMESPACE}" >/dev/null

echo "[test] Waiting for job ${JOB_NAME} completion"
kubectl --context "${KUBE_CONTEXT}" wait job/"${JOB_NAME}" \
  -n "${CONTROLLER_NAMESPACE}" \
  --for=condition=complete --timeout=180s >/dev/null

echo "[assert] Deployment template must have restart annotation"
RESTARTED_AT=$(kubectl --context "${KUBE_CONTEXT}" get deployment/sample-app \
  -n "${APP_NAMESPACE}" \
  -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
if [[ -z "${RESTARTED_AT}" ]]; then
  echo "ERROR: Deployment missing kubectl.kubernetes.io/restartedAt annotation"
  exit 1
fi

echo "[assert] Waiting for restarted deployment to become ready"
kubectl --context "${KUBE_CONTEXT}" rollout status deployment/sample-app \
  -n "${APP_NAMESPACE}" --timeout=180s >/dev/null

echo "[assert] Ready pod should be rescheduled off ${WORKER_NODE_1}"
kubectl --context "${KUBE_CONTEXT}" get pods -n "${APP_NAMESPACE}" -l app=sample-app -o json |
  jq -e --arg TARGET "${WORKER_NODE_1}" '
    .items
    | map(select(any(.status.conditions[]?; .type == "Ready" and .status == "True")))
    | map(.spec.nodeName)
    | any(. != $TARGET)
  ' >/dev/null

echo "[success] End-to-end test passed"
