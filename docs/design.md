# CSI Driver LVM Design Document

## 1. Project Overview

### 1.1 Description
gluesys-csi utilizes AnyStor-E external storage to provide persistent storage for pods.

### 1.2 Key Features
- Create, delete, mount, unmount, and resize block and filesystem volumes via LVM
- Support for thin provisioning (thin volumes)
- Support for snapshots and volume restoration from snapshots
- NFS-based volume sharing across nodes via network zones
- Pacemaker integration for high availability
- Automatic PVC deletion on Pod eviction for StatefulSets
- Support for ephemeral inline volumes

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                      │
│                                                               │
│  ┌──────────────┐         ┌──────────────────────────────────┐ │
│  │   Pods      │         │   External Storage (AnyStor-E)   │ │
│  │              │         │                                  │ │
│  │  ┌────────┐ │         │  ┌────────────┐  ┌────────────┐ │ │
│  │  │ PVC    │ │◄────────┤  │  LVM VG    │  │   NFS      │ │ │
│  │  └────────┘ │         │  │            │  │   Share    │ │ │
│  │              │         │  └────────────┘  └────────────┘ │ │
│  └──────────────┘         │                                  │ │
│         │                │  ┌────────────┐  ┌────────────┐ │ │
│         │                │  │Pacemaker   │  │  Network   │ │ │
│         │                │  │Resources   │  │   Zones    │ │ │
│         │                │  └────────────┘  └────────────┘ │ │
└─────────┼────────────────┼──────────────────────────────────┘
          │                │
          ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CSI Driver Components                    │
│                                                               │
│  ┌──────────────────────┐      ┌──────────────────────────────┐ │
│  │  CSI Plugin Daemon   │      │   Controller Manager        │ │
│  │  (lvmplugin)        │      │                            │ │
│  │                      │      │  ┌────────────────────────┐ │ │
│  │  ┌────────────────┐ │      │  │ LogicalVolume        │ │ │
│  │  │ Identity Server│ │      │  │ Reconciler           │ │ │
│  │  └────────────────┘ │      │  └────────────────────────┘ │ │
│  │  ┌────────────────┐ │      │                            │ │
│  │  │Controller Server│ │      └──────────────────────────────┘ │
│  │  └────────────────┘ │                                       │
│  │  ┌────────────────┐ │                                       │
│  │  │  Node Server  │ │                                       │
│  │  └────────────────┘ │                                       │
│  └──────────────────────┘                                       │
│                    │                                            │
│                    ▼                                            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  Storage Package                          │  │
│  │                                                        │  │
│  │  - LVM Management (Create/Delete/Extend LV)             │  │
│  │  - Filesystem Operations (Format/Mount/Unmount)          │  │
│  │  - NFS Operations (Mount/Unmount/Create/Delete Share)    │  │
│  │  - Snapshot Operations                                   │  │
│  │  - Pacemaker Operations                                │  │
│  │  - Proxy Client (AnyStor-E API)                        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Components

#### 2.2.1 CSI Plugin Daemon (lvmplugin)
- **Location**: `cmd/lvmplugin/main.go`
- **Purpose**: Node-level CSI service that runs on each Kubernetes node
- **Services Implemented**:
  - Identity Server (`pkg/server/identity.go`): Provides driver information
  - Controller Server (`pkg/server/controller.go`): Manages volume lifecycle
  - Node Server (`pkg/server/node.go`): Handles volume operations at node level

#### 2.2.2 Controller Manager
- **Location**: `cmd/controller/main.go`
- **Purpose**: Manages Kubernetes custom resources (LogicalVolume CRD)
- **Component**: LogicalVolume Reconciler

#### 2.2.3 LogicalVolume CRD
- **Location**: `api/v1/LogicalVolume.go`
- **Scope**: Cluster-scoped resource
- **Spec Fields**:
  - `name`: Logical volume name
  - `size`: Volume size
  - `type`: Volume type (thin)
  - `pool`: Thin pool name
  - `poolSize`: Thin pool size
  - `networkZone`: Network zone for sharing
  - `source`: Source logical volume (for snapshots)
- **Status Fields**:
  - `volumeID`: Volume identifier
  - `code`: Status code
  - `currentSize`: Current volume size
  - `phase`: Volume phase (Creating/Available/Deleting/Failed)
  - `message`: Status message
  - `isMaintenanced`: Pacemaker maintenance mode status

#### 2.2.4 Storage Package
- **Location**: `pkg/storage/`
- **Purpose**: Provides interface to AnyStor-E storage API
- **Key Modules**:
  - `logicalvolume.go`: LVM operations
  - `persistentvolume.go`: Volume lifecycle management
  - Proxy API client for AnyStor-E

## 3. Volume Lifecycle

### 3.1 Volume Creation Flow

```
Kubernetes PVC Request
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Controller Server: CreateVolume()                         │
│ (pkg/server/controller.go:53)                                 │
│ - Validates request                                           │
│ - Checks if LogicalVolume CRD exists                          │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ Create LogicalVolume CRD                                      │
│ - Set phase: Creating                                        │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ LogicalVolume Reconciler: Reconcile()                        │
│ (pkg/controller/logicalvolume_controller.go:48)               │
│ - Watch for LogicalVolume CRD changes                        │
│ - Triggered when CRD is created/updated/deleted              │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ SyncState(): Handle Creation                                  │
│ (pkg/controller/logicalvolume_controller.go:149)              │
│ - Determine if creating from snapshot or new volume           │
└────────────────────────────────────────────────────────────────┘
         │
         ├──────────────────────┬──────────────────────┐
         │                      │                      │
         ▼                      ▼                      ▼
   New Volume             From Snapshot          (Update Status)
         │                      │                      │
         ▼                      ▼                      │
┌────────────────────────────────────────────────────────────────┐
│ CreatePersistentVolume()                                      │
│ (pkg/storage/persistentvolume.go:76)                           │
│                                                                │
│ 1. Create Thin Pool (if needed)                                │
│    - CreateLV(type="thin_pool")                               │
│                                                                │
│ 2. Create Logical Volume                                       │
│    - CreateLV(type="thin")                                     │
│                                                                │
│ 3. Format Filesystem                                           │
│    - FormatFS(XFS)                                             │
│                                                                │
│ 4. Mount Filesystem                                            │
│    - MountFS(XFS)                                              │
│                                                                │
│ 5. Set POSIX Permissions (777 for mmap support)                │
│    - SetChmod()                                                │
│                                                                │
│ 6. Create NFS Share                                           │
│    - CreateShare()                                              │
│    - Enable NFS                                                 │
│    - Configure network zone                                     │
│                                                                │
│ 7. Create Pacemaker Resources (if available)                   │
│    - Get resource template from AnyStor-E                       │
│    - Set maintenance mode                                      │
│    - Create resources (LVM, Filesystem, Share)                 │
│    - Create constraints (colocation, order)                      │
│    - Unset maintenance mode                                    │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ Update LogicalVolume Status                                    │
│ - Phase: Available                                           │
│ - Message: "volume is available"                              │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Controller Server: Retry CreateVolume()                     │
│ - Returns success with VolumeInfo                              │
└────────────────────────────────────────────────────────────────┘
```

### 3.2 Volume Deletion Flow

```
Kubernetes PVC Delete Request
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Controller Server: DeleteVolume()                          │
│ (pkg/server/controller.go:176)                                │
│ - Validates request                                           │
│ - Delete LogicalVolume CRD                                    │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ LogicalVolume Reconciler: Reconcile()                        │
│ - Detect deletion timestamp                                   │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ SyncState(): Handle Deletion                                  │
│ (pkg/controller/logicalvolume_controller.go:103)              │
│ - Set phase: Deleting                                         │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ DeletePersistentVolume()                                      │
│ (pkg/storage/persistentvolume.go:237)                         │
│                                                                │
│ 1. Delete Pacemaker Resources (if exist)                       │
│    - Delete resources (LVM, Filesystem, Share)                 │
│                                                                │
│ 2. Delete NFS Share                                           │
│    - Disable NFS                                               │
│    - Delete share                                              │
│    - Restart NFS daemon                                        │
│                                                                │
│ 3. Unmount Filesystem                                         │
│    - UnmountFS(XFS)                                            │
│                                                                │
│ 4. Delete Logical Volume                                       │
│    - RemoveLV()                                                │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ Remove Finalizer                                               │
│ - Delete LogicalVolume CRD                                    │
└────────────────────────────────────────────────────────────────┘
```

### 3.3 Snapshot Creation Flow

```
Kubernetes VolumeSnapshot Request
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Controller Server: CreateSnapshot()                        │
│ (pkg/server/controller.go:216)                                │
│ - Validate request                                           │
│ - Get source LogicalVolume                                    │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CreatePersistentVolumeSnapshot()                              │
│ (pkg/storage/persistentvolume.go:457)                         │
│ - CreateSnapshot() via AnyStor-E API                          │
│   - Creates LVM snapshot from source LV                        │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ Return Snapshot Info                                          │
│ - Snapshot ID                                                 │
│ - Size                                                        │
│ - Creation time                                               │
└────────────────────────────────────────────────────────────────┘
```

### 3.4 Volume Mount Flow (Node Publish)

```
Pod Scheduling
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Node Server: NodePublishVolume()                          │
│ (pkg/server/node.go:57)                                      │
│ - Validate request                                           │
│ - Check ephemeral volume                                      │
└────────────────────────────────────────────────────────────────┘
         │
         ├─────────────────────┬──────────────────────┐
         │                     │                      │
         ▼                     ▼                      ▼
   Ephemeral Volume?    Get LogicalVolume    Mount NFS
         │                     │                      │
         ▼                     ▼                      ▼
  Create LV CRD          Check Phase         Get NFS Share
         │                     │                      │
         ▼                     ▼                      ▼
  (Reconciler)        Must be Available   Mount NFS Share
         │                     │                      │
         └─────────────────────┴──────────────────────┘
                                │
                                ▼
                    ┌───────────────────────────────┐
                    │ MountNfs()                   │
                    │ - Create mount directory       │
                    │ - mount -t nfs               │
                    │   -o async,rsize,wsize...     │
                    └───────────────────────────────┘
```

### 3.5 Volume Expansion Flow

```
Kubernetes PVC Resize Request
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Controller Server: ControllerExpandVolume()                │
│ (Not implemented - delegated to node expansion)               │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ CSI Node Server: NodeExpandVolume()                           │
│ (pkg/server/node.go:326)                                     │
│ - Validate request                                           │
│ - Get LogicalVolume                                          │
│ - Determine if block or filesystem                            │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ ExtendLV()                                                   │
│ (pkg/storage/logicalvolume.go:361)                           │
│ - Extend logical volume size via AnyStor-E API                │
│ - For block: Done                                            │
│ - For filesystem: Requires app-side resize                    │
└────────────────────────────────────────────────────────────────┘
```

## 4. Key Components Detail

### 4.1 Storage API Proxy Package
- **Location**: `pkg/proxy/`
- **Purpose**: Generated client for AnyStor-E REST API
- **Key APIs**:
  - LVM API: Manage logical volumes, volume groups
  - LVM Snapshot API: Create/delete snapshots
  - Share API: Manage NFS shares
  - Pacemaker API: Manage HA resources
  - Zone API: Manage network zones
  - Daemon API: Control NFS daemon
  - Explorer API: File operations

### 4.2 Pacemaker Integration
- **Purpose**: High availability for NFS shares
- **Resources Created**:
  - LVM resource: `share_<VG>_<LVName>`
  - Filesystem resource: `rsc_<VG>_<LVName>`
  - VIP resource: `vip_<StorageVIP>`
- **Constraints**:
  - Colocation: Ensure resources run on same node
  - Order: LVM → Filesystem → Share
- **Maintenance Mode**: Set before resource creation to prevent failover

### 4.3 Network Zones
- **Purpose**: Share volumes across specific network segments
- **Configuration**: Specified in StorageClass annotations
  - `gms.io/networkZone`: Zone name (e.g., "internal")
- **NFS Share Configuration**:
  - Zone-specific access control
  - Read/write permissions
  - No root squash for compatibility

### 4.4 Maintenance Mode Management
- **Purpose**: Prevent Pacemaker failover during volume operations
- **Implementation**:
  - Check if other volumes need maintenance (`CheckMaintenanceMode`)
  - Set maintenance on node before operations
  - Unset maintenance when all operations complete
- **Compatibility Check**: Volumes with different names or sources are incompatible

## 5. Configuration

### 5.1 Helm Values
Located at `charts/gluesys-csi/values.yaml`:

```yaml
lvm:
  storageVG: csi-lvm                    # Volume Group name
  storageAuth: '{api token}'            # AnyStor-E API token
  storageVIP: '{vip}'                  # AnyStor-E VIP
  storagePort: 80                      # API port
  storageScheme: http                  # http or https
  driverName: lvm.csi.gms.io          # CSI driver name

storageClasses:
  thin:
    enabled: true
    additionalAnnotations:
      gms.io/thinpool: "thinpool"      # Thin pool name
      gms.io/thinpoolSize: "10GiB"     # Thin pool size
      gms.io/networkZone: "internal"   # Network zone
    reclaimPolicy: Delete
```

### 5.2 StorageClass Parameters
- `type`: Volume type (currently only "thin")
- `gms.io/thinpool`: Thin pool name
- `gms.io/thinpoolSize`: Thin pool size (e.g., "500GiB")
- `gms.io/networkZone`: Network zone for NFS sharing

## 6. API Interfaces

### 6.1 CSI Controller Service Capabilities
- CREATE_DELETE_VOLUME
- GET_CAPACITY
- CREATE_DELETE_SNAPSHOT

### 6.2 CSI Node Service Capabilities
- STAGE_UNSTAGE_VOLUME
- EXPAND_VOLUME
- GET_VOLUME_STATS

## 7. Error Handling

### 7.1 Volume Phases
- **Creating**: Volume creation in progress
- **Available**: Volume ready for use
- **Deleting**: Volume deletion in progress
- **Failed**: Volume operation failed

### 7.2 Retry Logic
- CreateVolume/DeleteVolume return `Aborted` status if operation in progress
- Controller retries until phase reaches Available
- Finalizer ensures cleanup before deletion

## 8. Deployment Architecture

### 8.1 Components
- **CSI Plugin DaemonSet**: Runs on each worker node
  - Implements Identity, Controller, Node services
- **Controller Deployment**: Manages LogicalVolume CRDs
  - Leader election support (optional)

### 8.2 Sidecar Containers
- csi-provisioner: Handles PVC provisioning
- csi-attacher: Attaches volumes to pods
- csi-snapshotter: Manages snapshots
- csi-resizer: Handles volume expansion
- livenessprobe: Health monitoring
- node-driver-registrar: Registers driver with kubelet

## 9. Special Features

### 9.1 Automatic PVC Deletion on Pod Eviction
- **Purpose**: Handle pod eviction gracefully
- **Requirements**:
  - Works only with StatefulSets using volumeClaimTemplates
  - Pod or PVC must have annotation: `gms.io/gluesys-csi.is-eviction-allowed: true`
- **Behavior**: When pod is evicted, controller can delete PVC to allow restart on different node

### 9.2 Ephemeral Inline Volumes
- **Purpose**: Short-lived volumes that are created/destroyed with pod
- **Behavior**:
  - Created in NodePublishVolume
  - Deleted in NodeUnpublishVolume
  - Volume names start with "csi-"

### 9.3 Compatibility Mode
- **Purpose**: Backward compatibility with v0.3.x storage class names
- **Configuration**: `compat03x: true` in Helm values
- **Storage Classes**: `csi-lvm-sc-thin` instead of `gluesys-csi-thin`

## 10. Directory Structure

```
gluesys-csi/
├── api/
│   └── v1/
│       ├── LogicalVolume.go         # LogicalVolume CRD definition
│       ├── groupversion_info.go    # API version info
│       └── zz_generated.deepcopy.go # Generated deep copy methods
├── cmd/
│   ├── controller/
│   │   └── main.go               # Controller manager entry point
│   └── lvmplugin/
│       └── main.go               # CSI plugin daemon entry point
├── charts/
│   └── gluesys-csi/          # Helm chart
│       ├── Chart.yaml
│       ├── values.yaml           # Configuration values
│       └── templates/           # Kubernetes manifests
├── pkg/
│   ├── controller/
│   │   └── logicalvolume_controller.go  # LogicalVolume reconciler
│   ├── server/
│   │   ├── driver.go            # Driver initialization
│   │   ├── identity.go          # CSI Identity service
│   │   ├── controller.go        # CSI Controller service
│   │   └── node.go             # CSI Node service
│   ├── storage/
│   │   ├── logicalvolume.go     # LVM operations
│   │   ├── persistentvolume.go   # Volume lifecycle
│   │   ├── parse.go            # Parsing utilities
│   │   └── util.go             # Utility functions
│   └── proxy/                  # AnyStor-E API client
├── config/                     # Kubernetes configuration
│   ├── crd/                   # Custom Resource Definitions
│   ├── rbac/                  # RBAC configuration
│   ├── default/                # Default configuration
│   ├── manager/               # Manager configuration
│   ├── network-policy/        # Network policies
│   └── prometheus/           # Prometheus monitoring
├── examples/                  # Example manifests
│   ├── csi-pvc-thin.yaml
│   ├── csi-pod-thin.yaml
│   ├── csi-snapshot-thin.yaml
│   └── ...
└── docs/                      # Documentation
```

## 11. Key Functions Reference

### 11.1 Controller Operations
| Function | Location | Description |
|----------|----------|-------------|
| `CreateVolume()` | pkg/server/controller.go:53 | Creates volume, creates LogicalVolume CRD |
| `DeleteVolume()` | pkg/server/controller.go:176 | Deletes volume, deletes LogicalVolume CRD |
| `CreateSnapshot()` | pkg/server/controller.go:216 | Creates LVM snapshot |
| `DeleteSnapshot()` | pkg/server/controller.go:290 | Deletes LVM snapshot |
| `GetCapacity()` | pkg/server/controller.go:347 | Returns available capacity |

### 11.2 Node Operations
| Function | Location | Description |
|----------|----------|-------------|
| `NodePublishVolume()` | pkg/server/node.go:57 | Mounts NFS share to target path |
| `NodeUnpublishVolume()` | pkg/server/node.go:179 | Unmounts NFS share |
| `NodeExpandVolume()` | pkg/server/node.go:326 | Expands logical volume |
| `NodeGetVolumeStats()` | pkg/server/node.go:290 | Returns volume usage statistics |

### 11.3 Reconciler Operations
| Function | Location | Description |
|----------|----------|-------------|
| `Reconcile()` | pkg/controller/logicalvolume_controller.go:48 | Main reconciliation loop |
| `SyncState()` | pkg/controller/logicalvolume_controller.go:61 | Synchronizes volume state |
| `handleCreation()` | pkg/controller/logicalvolume_controller.go:149 | Handles volume creation |
| `handleDeletion()` | pkg/controller/logicalvolume_controller.go:103 | Handles volume deletion |

### 11.4 Storage Operations
| Function | Location | Description |
|----------|----------|-------------|
| `CreateLV()` | pkg/storage/logicalvolume.go:269 | Creates logical volume |
| `ExtendLV()` | pkg/storage/logicalvolume.go:361 | Extends logical volume |
| `RemoveLV()` | pkg/storage/logicalvolume.go:395 | Removes logical volume |
| `FormatFS()` | pkg/storage/logicalvolume.go:98 | Formats filesystem (XFS) |
| `MountFS()` | pkg/storage/logicalvolume.go:124 | Mounts filesystem |
| `UnmountFS()` | pkg/storage/logicalvolume.go:151 | Unmounts filesystem |
| `CreateShare()` | pkg/storage/logicalvolume.go:470 | Creates NFS share |
| `DeleteShare()` | pkg/storage/logicalvolume.go:575 | Deletes NFS share |
| `CreateSnapshot()` | pkg/storage/logicalvolume.go:647 | Creates LVM snapshot |
| `DeleteSnapshot()` | pkg/storage/logicalvolume.go:678 | Deletes LVM snapshot |
| `CreatePersistentVolume()` | pkg/storage/persistentvolume.go:76 | Creates persistent volume |
| `DeletePersistentVolume()` | pkg/storage/persistentvolume.go:237 | Deletes persistent volume |

## 12. Dependencies

### 12.1 Kubernetes Dependencies
- `sigs.k8s.io/controller-runtime`: Controller runtime framework
- `k8s.io/client-go`: Kubernetes Go client
- `k8s.io/api`: Kubernetes API types
- `github.com/container-storage-interface/spec/lib/go/csi`: CSI specification

### 12.2 Storage Dependencies
- `github.com/antihax/optional`: Optional parameters for API calls
- Generated proxy client (pkg/proxy/): AnyStor-E API client

## 13. Monitoring and Observability

### 13.1 Metrics
- HTTP metrics endpoint (configurable via `--metrics-bind-address`)
- Health probe endpoint (default: `:8081`)
- Structured JSON logging using `log/slog`

### 13.2 Health Checks
- Healthz check: Basic health status
- Readyz check: Component readiness status
- Liveness probe: Container health monitoring

## 14. Security Considerations

### 14.1 RBAC
- Role-based access control configured
- Separate roles for controller and node components
- Metrics authentication support

### 14.2 Network Security
- Network policies allow metrics traffic
- TLS support for HTTPS connections to AnyStor-E
- Network zone-based access control for NFS shares

### 14.3 TLS Configuration
- HTTPS scheme support for AnyStor-E API
- Insecure skip verify option (configurable)
- Custom CA certificates can be configured

## 15. Troubleshooting

### 15.1 Common Issues

#### Volume Creation Stuck in "Creating" Phase
- Check controller logs for errors
- Verify AnyStor-E API connectivity
- Check thin pool capacity
- Verify Pacemaker availability

#### NFS Mount Failures
- Verify share creation in AnyStor-E
- Check network zone configuration
- Verify NFS daemon status
- Check firewall rules

#### Pacemaker Resource Failures
- Check maintenance mode status
- Verify resource templates
- Check constraint definitions
- Verify node availability

### 15.2 Log Locations
- Controller logs: Follow controller-manager pod logs
- Plugin logs: Follow lvmplugin DaemonSet pod logs
- Sidecar logs: Follow respective sidecar container logs

## 16. Future Enhancements
Potential areas for improvement:
- Block device support (currently returns Unimplemented)
- More filesystem type support (currently only XFS)
