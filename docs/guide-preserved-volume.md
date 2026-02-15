# Guide: Connecting Existing Volumes as PVs

## Overview

This feature allows you to connect existing volumes (LVs) that are already running on AnyStor-E to Kubernetes PVCs through csi-driver-lvm. You can use existing LVs in Kubernetes while preserving them.

## Key Features

- Connect existing AnyStor-E LVs as PVs
- Preserve LV when PVC is deleted (no snapshots)
- Maintain data on existing LVs
- Faster volume creation (reuses existing LV)

## Prerequisites

1. An existing LV must be created on AnyStor-E
2. csi-driver-lvm must be installed
3. The path and format information of the LV must be confirmed

## Usage

### 1. Check Existing LV

First, confirm the name of the existing LV to be used on AnyStor-E.

```bash
# Check LV list in AnyStor-E API or UI
# Example: existing-lv-name
```

### 2. Create PVC

Specify the existing LV name using the `gms.io/lv` annotation when creating a PVC.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-preserved
  annotations:
    gms.io/lv: existing-lv-name
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: csi-driver-lvm-thin
  volumeMode: Filesystem
  resources:
    requests:
      storage: 100Mi
```

**Important Notes:**
- You must specify the exact existing LV name in the `gms.io/lv` annotation
- An error will occur if the specified LV does not exist on AnyStor-E
- The value in the `storage` field is used as the PVC request size and may differ from the actual LV size

### 3. Create Pod

Create a Pod using the created PVC.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-preserved
spec:
  containers:
    - name: my-container
      image: nginx:latest
      volumeMounts:
        - mountPath: /data
          name: my-volume
  volumes:
    - name: my-volume
      persistentVolumeClaim:
        claimName: pvc-preserved
```

### 4. Apply Examples

```bash
# Create PVC
kubectl apply -f examples/csi-pvc-preserved.yaml

# Check PVC status
kubectl get pvc pvc-preserved

# Create Pod
kubectl apply -f examples/csi-pod-preserved.yaml

# Check Pod status
kubectl get pod pod-preserved
```

## Volume Deletion Behavior

When deleting a PVC, the following occurs:

1. If there are no snapshots, no resources are controlled
2. If there are snapshots, they are removed as follows:
   - Pacemaker resources are removed
   - LV (Logical Volume) is deleted

```bash
# Delete PVC
kubectl delete -f examples/csi-pvc-preserved.yaml
```

## Recovery Scenario

```bash
# Delete PVC
kubectl delete pvc pvc-preserved

# Create PV from snapshot
kubectl apply -f examples/csi-pvc-snapshot-restore.yaml
```

**Note**: When restoring from a snapshot, if the snapshot's original LogicalVolume does not exist, the name is changed to LogicalVolume and resources are configured

## Limitations

1. **LV Existence Check**: The specified LV must exist on AnyStor-E
2. **Format Compatibility**: The existing LV must be formatted as XFS. Mount errors may occur with other formats
3. **Network Zone**: The existing LV must have a network zone set that matches the `gms.io/networkZone` in the StorageClass
4. **Single Use**: Data corruption may occur if the same LV is used simultaneously by multiple PVCs

## Troubleshooting

### Error: "Preserved LV not found in AnyStor-E"

**Cause**: The specified LV does not exist on AnyStor-E

**Solution**:
1. Check LV name on AnyStor-E
2. Modify the PVC's `gms.io/lv` annotation to the correct name
3. Recreate PVC

```bash
kubectl annotate pvc pvc-preserved gms.io/lv=correct-lv-name --overwrite
kubectl delete pvc pvc-preserved
kubectl apply -f examples/csi-pvc-preserved.yaml
```

### Error: "Failed to mount"

**Cause**: Existing LV format is incompatible or mount path issue

**Solution**:
1. Check LV format on AnyStor-E (XFS recommended)
2. If existing format is not XFS, format on AnyStor-E
3. Recreate PVC

### PVC Stuck in Available Status

**Cause**: Reconciler failed to complete volume creation

**Solution**:
1. Check csi-controller logs
2. Check AnyStor-E connection status
3. Check Pacemaker status

```bash
kubectl logs -n csi-driver-lvm deployment/csi-controller-manager
```

## Monitoring

### Check PVC Status

```bash
kubectl get pvc
kubectl describe pvc pvc-preserved
```

### Check LogicalVolume CRD Status

```bash
kubectl get logicalvolume
kubectl describe logicalvolume <volume-name>
```

### Check Pod Logs

```bash
kubectl logs pod-preserved
```

### Check CSI Driver Logs

```bash
kubectl logs -n csi-driver-lvm -l app=csi-lvmplugin
kubectl logs -n csi-driver-lvm -l app=csi-controller-manager
```

## Recommendations

1. **Verify in Test Environment First**: Verify in a test environment before applying to production data
2. **Backup Required**: Backup the data on the existing LV before creating the PVC
3. **Naming Convention**: Manage existing LV names clearly to prevent mistakes
4. **Documentation**: Document which LV is used by which PVC

## Notes

- If there are no snapshots, the existing LV is preserved so data remains even after PVC deletion
- To reconnect the same LV as a PV again, simply recreate the PVC using the `gms.io/lv` annotation
- Choose the appropriate method based on the recovery scenario
