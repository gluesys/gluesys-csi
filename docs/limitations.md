# csi-driver-lvm Limitations Guide

## 1. Basic Value Limitations

### 1.1 StorageClass Required Parameters

| Parameter | Description | Limitation |
|-----------|-------------|-------------|
| `type` | LV type | **Only thin is supported** |
| `gms.io/thinpool` | thin pool name | Required, created if not exists |
| `gms.io/thinpoolSize` | thin pool size | **Must be within total VG capacity** (e.g., 500GiB) |
| `gms.io/networkZone` | Network zone for NFS share | Required, must be a valid zone name |

### 1.2 StorageClass Configuration During Helm Installation

```yaml
# charts/csi-driver-lvm/values.yaml
storageClasses:
  thin:
    enabled: true
    additionalAnnotations:
      gms.io/thinpool: "csi-pool"
      gms.io/thinpoolSize: "500GiB"
      gms.io/networkZone: "internal"
    reclaimPolicy: Delete  # Kubernetes standard parameter (reference only)
```

### 1.3 Volume Creation Limitations

- **Block Device Volumes**: Not supported
- **Capacity Units**: Kubernetes standard quantity format (e.g., 10Gi, 100Mi)
- **PV Creation**: `volumeBindingMode: WaitForFirstConsumer` is required (created after pod scheduling)
- **Preserved LV**: Supports using existing LVs as PVs (requires `gms.io/lv` annotation on PVC)
- **Multiple Pods Using Same PVC**: No issues with multiple pods using the same PVC

## 2. Capacity-Related Limitations

### 2.1 Thin Provisioning Pool Overallocation

**Thin Provisioning Pool Overallocation Risk**:

- thinpool is defined in storageclass
- thinpool can be specified via custom storageclass
- thinpoolSize setting affects VG
- Thin provisioning allows allocating more logical space than actual physical space
- Example:
  - Thin pool size: 500GB
  - Create 10 thin LVs each of 100GB → Total allocation 1TB (logical)

**Mandatory Limitation**: `thinpoolSize` must be specified **within total VG capacity**

## 3. Thin Pool Management (TODO)

### 3.1 Auto Deletion Not Implemented

- Unused thinpools are not automatically deleted
- Unused pools may waste space
- Thinpool creation is defined by storageclass, so configuration changes are infrequent
- **Solution**: Periodic manual cleanup of unused thinpools required (development planned)

## 4. Snapshot-Related Limitations

### 4.1 Snapshot Feature Support

- **CreateSnapshot**: Implemented
- **DeleteSnapshot**: Implemented
- **Snapshot Restore**: Supported
- **Snapshot Name**: Created in `lvm-{snapshotId}` format

### 4.2 How to Use Snapshots

```bash
# Create snapshot
kubectl apply -f examples/csi-snapshot-thin.yaml

# Restore volume from snapshot
kubectl apply -f examples/csi-snapshot-thin-restore.yaml
kubectl apply -f examples/csi-pod-thin-restore.yaml
```

## 5. Pacemaker HA Configuration

### 5.1 Automatic HA Configuration Conditions

- **Pacemaker Availability**: Automatic configuration only when Pacemaker is available on AnyStor-E
- **VIP Resource**: Share resource creation only when `vip_{storageVIP}` resource exists
- **Automatic Creation Process**:
  1. Query Pacemaker resource list
  2. Verify VIP resource and get node information
  3. Set maintenance mode (prevent failover)
  4. Create LVM/Filesystem/Share resource templates
  5. Unset maintenance mode
- **Setup Required**: Only works in AnyStor-E environment where Pacemaker is enabled

### 5.2 HA Limitations

- HA functionality does not work in environment without Pacemaker installed
- Manual Pacemaker configuration required (if automatic configuration is not possible)

## 6. API Performance Limitations

### 6.1 Bulk Request Processing and Maintenance Mode

- **GMS API Dependency**: All LVM/Share/NFS operations require GMS API calls
- **Synchronous Processing**: Sequential API calls for volume creation/deletion
- **Maintenance Mode Management**:
  - Pacemaker maintenance mode required during volume creation/deletion/expansion
  - `CheckMaintenanceMode()` function identifies volumes requiring maintenance mode
  - Only volumes with same pool/source are compatible (api/v1/LogicalVolume.go:66-76)
- Volume creation may be delayed depending on bulk request situation

## 7. Kubernetes Configuration-Related Limitations

### 7.1 StorageClass Addition and Kasten Backup

- Multiple StorageClasses can be added (configure in helm values.yaml or create by referencing examples/csi-storageclass-thin.yaml)
- **Kasten Backup Specification**: StorageClass used in Kasten must be a StorageClass that can be specified in csi-driver-lvm
- **Recommendation**: Clearly define and manage StorageClass to be used for backup

### 7.2 Eviction Feature (Automatic PVC Deletion)

**Feature Description**: Automatically deletes PVC when a pod is evicted (expelled) to allow restart on a different node

**Operation Conditions**:

- StatefulSet includes `volumeClaimTemplates`
- Pod or PVC has annotation `gms.io/csi-driver-lvm.is-eviction-allowed: true`

**Limitations**:

- Does not work for Deployment/DaemonSet
- Automatic deletion does not occur without annotation
- **Data Loss Risk**: Automatic PVC deletion on eviction causes data loss

**Use Scenarios**:

- Pod eviction due to cluster autoscaling or worker node updates
- Only use when data loss is acceptable

### 7.3 ReclaimPolicy (Not Implemented)

- **Current State**: ReclaimPolicy can only be set as a Kubernetes StorageClass parameter
- **Actual Behavior**: Only the `IsPreserved` flag works
  - `IsPreserved: true`: Only removes LV and HA configuration on AnyStor-E when PVC is deleted
  - `IsPreserved: false`: Removes all LV-related resources on AnyStor-E when PVC is deleted
- **Note**: Delete/Retain settings of ReclaimPolicy currently have no effect (planned for future implementation)

## 8. Functional Limitations

### 8.1 Unsupported Features

- **Block Device**: Not supported

## 9. Operational Limitations

### 9.1 LogicalVolume CRD-Based Operation

- Volume creation/deletion is managed through LogicalVolume CRD
- **Volume Status**: Creating → Available → Deleting
- **Duplicate Requests**: Returns Aborted for same volume creation
- **Timeout**: CRD creation/deletion timeout of 40 seconds

### 9.2 Capacity Expansion

- **Filesystem Expansion**: Automatic support (NodeExpandVolume)
- **Block Volume Expansion**: Not supported

## 10. LV Preservation for Preserved LV Usage

### 10.1 Preserved LV Characteristics

- **Design Feature**: Volumes set with `IsPreserved: true` only remove share resources on AnyStor-E when PVC is deleted, not the LV
- **Limitation**: AnyStor-E allows only one NFS configuration on a share path
- **Behavior**:
  - Only Kubernetes resources (PV) are deleted when PVC is deleted
  - LV on AnyStor-E is preserved
  - Same LV can be reused by different PVCs (using `gms.io/lv` annotation)

**Important Notes**:

- Data corruption risk if same LV is used simultaneously by multiple PVCs
- Backup recommended before reuse

## 12. Recommended Settings and Guidelines

| Item | Recommended Setting | Reason |
|------|-------------------|--------|
| type | thin | Only supported type |
| thinPoolSize | Expected LV total capacity × 1.2 | Prevent overallocation |
| volumeBindingMode | WaitForFirstConsumer | Created after scheduling |
| reclaimPolicy | Retain (reference only) | Recommend using IsPreserved flag |
| networkZone | Separate zones | Network isolation |

## 13. Summary of Key Risks

1. **Thin Provisioning Overallocation**: Can allocate more than actual physical space, capacity calculation essential
2. **Eviction Data Loss**: Data disappears with automatic PVC deletion
3. **Preserved LV Annotation**: Must specify `gms.io/lv` annotation correctly when reusing existing LVs
4. **Synchronous Processing**: API bottleneck possible with bulk requests
5. **Pacemaker HA**: Automatic configuration only in environment where Pacemaker is enabled
6. **Kasten Backup Specification**: Must specify referencing StorageClass installed via helm

## 14. Other Limitations

### 14.1 Network Zone Consistency

- Network zone of existing LV must match `gms.io/networkZone` in StorageClass when using Preserved LV
- Mount failure possible if mismatched

### 14.2 Format Compatibility

- Preserved LV must be formatted as XFS
- Mount error occurs with other formats

### 14.3 Maintenance Mode Management

- Wait time may occur during incompatible volume operations
- Bottleneck concern for large-scale volume creation/deletion

### 14.4 Behavior of Snapshot and Preserved LV Combination

**Recommended Method**: Backup Preserved LV with snapshot, remove original, and reuse snapshot with original name

**Operation Description**:

1. **Create Preserved LV Snapshot**
   ```bash
   kubectl apply -f examples/csi-snapshot-thin.yaml
   ```
   - Snapshot created on AnyStor-E in `lvm-{snapshotId}` format
   - Original LV information preserved as Origin

2. **Remove Preserved LV** (when IsPreserved flag is set, only LV and HA are removed)
   ```bash
   # Share information is preserved when IsPreserved flag is set
   kubectl delete pvc <preserved-pvc>
   ```

3. **Create Snapshot PV**
   ```bash
   kubectl apply -f examples/csi-snapshot-thin-restore.yaml
   ```
   - Create new PV from snapshot
   - Set original LV name in Source of new volume

4. **Create Like Normal PV**
   ```bash
   kubectl apply -f examples/csi-pod-thin-restore.yaml
   ```
   - Use renamed snapshot like original PV
