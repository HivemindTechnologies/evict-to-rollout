#!/usr/bin/env bash
set -euo pipefail

# Configuration
ANNOTATION_KEY="evict-with-rollout"
ANNOTATION_VALUE="true"
DRY_RUN=${DRY_RUN:-false} # Set to true to print actions without executing

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"
}

declare -A RESTARTED_DEPLOYMENTS=()

# 1. Find Draining Nodes (unschedulable=true)
log "Checking for unschedulable nodes..."
NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name')

if [ -z "$NODES" ]; then
  log "No unschedulable nodes found. Exiting."
  exit 0
fi

for NODE in $NODES; do
  log "Processing node $NODE"

  # 2. Find Candidate Pods on this Node
  # We fetch all pods on the node and filter by annotation in jq to avoid complex field-selectors
  PODS_JSON=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$NODE" -o json)

  # Parse interesting pods: Name, Namespace, OwnerReferences
  # We look for pods with the specific annotation
  CANDIDATES=$(echo "$PODS_JSON" | jq -c --arg key "$ANNOTATION_KEY" --arg val "$ANNOTATION_VALUE" \
    '.items[] | select(.metadata.annotations[$key] == $val) | {name: .metadata.name, namespace: .metadata.namespace, owners: .metadata.ownerReferences}')

  if [ -z "$CANDIDATES" ]; then
    log "No candidate pods with annotation '$ANNOTATION_KEY=$ANNOTATION_VALUE' found on node $NODE."
    continue
  fi

  echo "$CANDIDATES" | while read -r POD_DATA; do
    POD_NAME=$(echo "$POD_DATA" | jq -r '.name')
    NAMESPACE=$(echo "$POD_DATA" | jq -r '.namespace')

    log "Analyzing pod $NAMESPACE/$POD_NAME on node $NODE"

    # 3. Traverse Ownership: Pod -> ReplicaSet -> Deployment
    # We expect the immediate owner to be a ReplicaSet
    RS_NAME=$(echo "$POD_DATA" | jq -r '.owners[]? | select(.kind=="ReplicaSet") | .name')

    if [ -z "$RS_NAME" ]; then
      log "Skipping pod $NAMESPACE/$POD_NAME: not owned by a ReplicaSet (direct Deployment management?)"
      continue
    fi

    # Fetch the ReplicaSet to find its owner (The Deployment)
    # Allow failure in case RS is gone (race condition)
    if ! RS_JSON=$(kubectl get rs "$RS_NAME" -n "$NAMESPACE" -o json 2>/dev/null); then
      log "Warning: Could not fetch ReplicaSet $RS_NAME for pod $NAMESPACE/$POD_NAME. Skipping."
      continue
    fi

    DEPLOY_NAME=$(echo "$RS_JSON" | jq -r '.metadata.ownerReferences[]? | select(.kind=="Deployment") | .name')

    if [ -z "$DEPLOY_NAME" ]; then
      log "Skipping pod $NAMESPACE/$POD_NAME: ReplicaSet $RS_NAME is not owned by a Deployment."
      continue
    fi

    log "Found parent Deployment $NAMESPACE/$DEPLOY_NAME for pod $NAMESPACE/$POD_NAME"

    # 4. Check Deployment Stability
    # We want to ensure we don't trigger a restart if one is already in progress.
    # Criteria for "Stable":
    # - observedGeneration == generation (Controller has seen the latest spec)
    # - replicas == readyReplicas (All pods are up)
    # - replicas == updatedReplicas (No old pods lingering - optional, but safer)
    # - replicas > 0 (Don't restart scaled-down deployments)
    # - !paused (Don't touch paused deployments)

    if ! DEPLOY_JSON=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o json 2>/dev/null); then
      log "Warning: Could not fetch Deployment $NAMESPACE/$DEPLOY_NAME. Skipping."
      continue
    fi

    IS_STABLE=$(echo "$DEPLOY_JSON" | jq -r '
            .status.observedGeneration == .metadata.generation and
            (.status.replicas // 0) == (.status.readyReplicas // 0) and
            (.status.replicas // 0) == (.status.updatedReplicas // 0) and
            (.status.replicas // 0) > 0 and
            (.spec.paused != true)
        ')

    if [ "$IS_STABLE" != "true" ]; then
      log "Skipping deployment $NAMESPACE/$DEPLOY_NAME: not stable (rolling out or degraded)."
      continue
    fi

    RESTART_KEY="$NAMESPACE/$DEPLOY_NAME"
    if [[ -n "${RESTARTED_DEPLOYMENTS[$RESTART_KEY]:-}" ]]; then
      log "Skipping deployment $NAMESPACE/$DEPLOY_NAME: already restarted during this run."
      continue
    fi

    # 5. Action: Trigger Rollout
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] Would trigger rollout for deployment $NAMESPACE/$DEPLOY_NAME"
    else
      log "Triggering rollout restart for deployment $NAMESPACE/$DEPLOY_NAME"
      kubectl rollout restart deployment "$DEPLOY_NAME" -n "$NAMESPACE"
      log "Rollout triggered for deployment $NAMESPACE/$DEPLOY_NAME"
    fi

    RESTARTED_DEPLOYMENTS[$RESTART_KEY]=1
  done
done

log "Done."
