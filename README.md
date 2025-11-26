# Evict to Rollout

This tool helps single-instance Kubernetes deployments survive node evictions (e.g., Karpenter consolidation or manual drains) without downtime.

## The Problem

When a node is drained, single-instance pods are evicted. Kubernetes kills the pod and starts a new one elsewhere. This causes downtime.
If you use a PodDisruptionBudget (PDB) with `minAvailable: 1`, the eviction is blocked indefinitely, preventing node scale-down.

## The Solution

This script acts as a bridge. It detects:
1.  Nodes that are draining (`unschedulable: true`).
2.  Pods on those nodes with the annotation `evict-to-rollout: "true"`.
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
        evict-to-rollout: "true"
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

## Deployment Options

### Helm (recommended)

This repository ships a Helm chart (`chart/evict-to-rollout`) so you can tweak the schedule, annotation selector, and naming without forking the manifest.

```bash
helm upgrade --install evict-to-rollout \
  oci://ghcr.io/hivemindtechnologies/evict-to-rollout \
  --version 0.1.0 \
  --namespace kube-system --create-namespace \
  --set schedule="*/2 * * * *" \
  --set annotationSelector.key="evict-with-rollout" \
  --set annotationSelector.value="true"
```

Key values:

| Value | Description | Default |
| --- | --- | --- |
| `schedule` | Cron expression for how often to scan nodes | `*/1 * * * *` |
| `annotationSelector.key`/`.value` | Annotation pair that marks pods for rollout | `evict-with-rollout` / `true` |
| `image.repository` / `.tag` | Container image that provides `kubectl` + `jq` | `ghcr.io/hivemindtechnologies/evict-to-rollout/kubectl-jq` / *(empty = use chart `appVersion`)* |
| `serviceAccount.create` | Whether to create a dedicated SA | `true` |
| `rbac.create` | Whether to install ClusterRole + binding | `true` |

See `chart/evict-to-rollout/values.yaml` for the full list.

## Development & Testing

This repo ships a `devbox.json` so everyone (including CI) uses the same versions of `helm`, `kubectl`, `kind`, and `jq`.

```bash
# Start a dev shell with all tools:
devbox shell

# Lint the chart:
devbox run lint

# Run the end-to-end test (requires Docker since it spins up kind):
devbox run test
```

The test script (`scripts/test-kind.sh`) creates a 3-node kind cluster, installs the Helm chart, deploys a sample annotated app, cordons a node, runs the controller job manually, and asserts that the deployment was restarted and rescheduled onto a different node.

GitHub Actions mirrors the same flow via `.github/workflows/ci.yaml`:

- on every PR, it runs `helm lint` and the kind-based integration test.
- on pushes to `main`, it additionally publishes:
  - the multi-arch `kubectl-jq` image tagged as `latest` and `${LAST_TAG}-sha.${GITHUB_SHA::7}`
  - a Helm chart tagged as `${LAST_TAG}-sha.${GITHUB_SHA::7}` to `oci://ghcr.io/hivemindtechnologies/evict-to-rollout`
- on git tag pushes (e.g. `v0.2.0`), the same workflow publishes **stable** artifacts tagged with the release version

### Release workflow

The CI pipeline keeps versions in sync automatically:

- For pushes to `main`, it reads the most recent git tag (or `0.0.0` if none exists) and publishes snapshot artifacts tagged as `<last-tag>-sha.<short-sha>`.
- For pushes to annotated tags (e.g. `v0.3.0`), it strips the `v` prefix and publishes both the Docker image and the Helm chart with the exact release version.
- The pipeline patches `chart/evict-to-rollout/Chart.yaml` on the fly so that `version` and `appVersion` match the artifact tag, and the default image tag in the chart inherits from `appVersion`.

For local testing the kind script (`devbox run test`) builds the image and loads it directly into the cluster, so no registry push is required.

## References

Related issues:

- https://github.com/kubernetes-sigs/karpenter/issues/1599
- https://github.com/kubernetes-sigs/karpenter/issues/2600
- https://github.com/kubernetes/kubernetes/issues/90977
