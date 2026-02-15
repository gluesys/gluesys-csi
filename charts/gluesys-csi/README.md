# CSI Driver LVM Helm Chart

This is the helm chart for the deployment of https://gitlab.gluesys.com/dev3/gluesys-csi.

The source of this helm-chart is [gluesys-csi](https://gitlab.gluesys.com/dev3/gluesys-csi) and gets synced to [helm-charts](https://gitlab.gluesys.com/dev3/helm-charts) after a release.

**The chart requires that you have at least Kubernetes 1.16.**

## Architecture

This chart deploys two components:

1. **DaemonSet** (`gluesys-csi`) - CSI driver that runs on all nodes
   - csi-attacher, csi-provisioner, csi-resizer, csi-snapshotter sidecars
   - gluesys-csi (main CSI plugin)
   - node-driver-registrar
   - liveness-probe

2. **Deployment** (`gluesys-csi-controller`) - Controller for LogicalVolume CRD
   - LogicalVolumeReconciler: Handles creation/deletion of LVM volumes
   - EvictionReconciler: Handles PVC deletion during pod eviction

## CRD Workflow

When a PVC requests storage:

1. CSI `CreateVolume` is called → Creates `LogicalVolume` CRD with phase `Creating`
2. Controller's `LogicalVolumeReconciler` watches CRD → Creates actual LVM volume
3. Once successful → Updates CRD phase to `Available`

