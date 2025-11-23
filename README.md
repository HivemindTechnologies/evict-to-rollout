# Evict to Rollout

This tool helps single-instance Kubernetes deployments survive node evictions (e.g., Karpenter consolidation or manual drains) without downtime.

## The Problem

When a node is drained, single-instance pods are evicted. Kubernetes kills the pod and starts a new one elsewhere. This causes downtime.
If you use a PodDisruptionBudget (PDB) with `minAvailable: 1`, the eviction is blocked indefinitely, preventing node scale-down.

## The Solution

This script acts as a bridge. It detects:
1.  Nodes that are draining (`unschedulable: true`).
2.  Pods on those nodes with the annotation `evict-with-rollout: "true"`.
3.  Deployments that are currently stable.

When found, it triggers a **rollout** (per default: rolling restart) of the Deployment. This ensures a new pod is started on a different node *before* the old one is killed, guaranteeing zero downtime.

## Usage

### 1. Annotate your Deployment/Pod

Add the annotation to your Deployment (which propagates to Pods):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        evict-with-rollout: "true"
```

Ensure you have a PDB that blocks eviction:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

### 2. Run locally (Dry Run)

```bash
export DRY_RUN=true
./evict_to_rollout.sh
```

### 3. Deploy as CronJob

See `cronjob.yaml` for the full manifest including RBAC permissions.

