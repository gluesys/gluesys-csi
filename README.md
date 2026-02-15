# CSI Driver LVM - Install Package

This package contains the required files to install gluesys-csi on a Kubernetes cluster using Helm.

## Package Contents

```
gluesys-csi/
├── install-snapshot.sh                 # Snapshot sidecar installation script
├── charts/gluesys-csi/
│   ├── Chart.yaml                       # Helm chart metadata
│   ├── values.yaml                      # Default configuration values
│   ├── crds/gms.io_logicalvolume.yaml   # Custom Resource Definition
│   └── templates/
│       ├── daemonset.yaml               # CSI node plugin with sidecars
│       ├── deployment.yaml              # CSI controller
│       ├── common.yaml                  # CSIDriver resource
│       └── storageclasses.yaml          # StorageClass definitions
├── docs
│   ├── README.md                        # Introduce Project
│   ├── design.md                        # Details of Project
│   ├── guide-preserved-volume.md        # How to assign an existing volume to a PVC
│   └── limitations.md                   # Limitations of gluesys-csi
└── examples
    ├── csi-pvc-thin.yaml                # Create PVC with default storageclass
    ├── csi-pod-thin.yaml                # Create POD with pvc-thin
    ├── csi-pvc-preserved.yaml           # Create PVC with existing volume
    ├── csi-pod-preserved.yaml           # Create POD with preserved volume
    ├── csi-snapshot-thin.yaml           # Create Snapshot with default PVC
    ├── csi-snapshot-thin-restore.yaml   # Create PVC with snapshot
    ├── csi-pod-thin-restore.yaml        # Create POD with Snapshot PVC
    ├── csi-storageclass-thin.yaml       # Make custom storageclass
    └── csi-snapshotclass-thin.yaml      # Make custom snapshotclass
```

## Prerequisites

- Kubernetes cluster (1.19+)
- kubectl configured
- helm installed (3.x)
- Docker images available:
  - CSI plugin image (gluesys-csi)
  - Controller image (gluesys-csi/controller)
- Private registry with pull secret (if using custom registry)

## Helm Values

| Value                         | Default  | Description                 |
|-------------------------------|----------|-----------------------------|
| `lvm.storageVG`               | required | Storage volume group        |
| `lvm.storageVIP`              | required | Storage VIP address         |
| `lvm.storageAuth`             | required | Storage auth token, Registering the existing storage token in the CSI driver is essential to map your stored data to the Kubernetes environment|
| `lvm.storagePort`             | 80       | Storage port                |
| `lvm.storageScheme`           | http     | Storage scheme (http/https) |
| `pluginImage.repository`      | -        | Plugin image repository     |
| `pluginImage.tag`             | -        | Plugin image tag            |
| `controller.image.repository` | -        | Controller image repository |
| `controller.image.tag`        | -        | Controller image tag        |

## Installation

### 1. Install CSI Driver LVM using Helm

```bash
helm install gluesys-csi ./charts/gluesys-csi \
  -n <namespace> \
  --set lvm.storageVG=<storage-vg> \
  --set lvm.storageVIP=<storage-vip> \
  --set lvm.storageAuth=<storage-auth>
```

### 2. Install with custom options

```bash
helm install gluesys-csi ./charts/gluesys-csi \
  -n csi-system \
  --create-namespace \
  --set lvm.storageVG=VG1 \
  --set lvm.storageVIP=10.0.24.70 \
  --set lvm.storageAuth="GMS_API_TOKEN" \
  --set lvm.storagePort=8443 \
  --set lvm.storageScheme=https
```

### 3. Install Snapshot Sidecar

```bash
./install-snapshot.sh
```

Or manually:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

## Verification

Check pod status:
```bash
kubectl get pods -n <namespace>
```

Expected output:
```
NAME                                      READY   STATUS    RESTARTS   AGE
gluesys-csi-xxxxx                      3/3     Running   0          1m
gluesys-csi-controller-xxxxx           1/1     Running   0          1m
```

Check StorageClass:
```bash
kubectl get storageclass gluesys-csi-thin
```

## Usage

Create a PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gluesys-csi-thin
  resources:
    requests:
      storage: 10Gi
```

Create a Pod using the PVC:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: my-container
    image: nginx
    volumeMounts:
    - mountPath: /data
      name: my-volume
  volumes:
  - name: my-volume
    persistentVolumeClaim:
      claimName: my-pvc
```

## Uninstallation

```bash
helm uninstall gluesys-csi -n <namespace>

# Optional: Uninstall snapshot sidecar
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v6.3.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
```

## Troubleshooting

Check logs:
```bash
# Plugin logs
kubectl logs -n <namespace> -l app=gluesys-csi -c gluesys-csi

# Controller logs
kubectl logs -n <namespace> -l app=gluesys-csi-controller -c controller
```

Describe resources:
```bash
kubectl describe pvc <pvc-name>
kubectl describe pod <pod-name>
kubectl get logicalvolume -o wide
```

## Support

For issues and questions, please refer to the project documentation.
