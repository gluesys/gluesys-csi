# gluesys-csi #

gluesys-csi utilizes AnyStor-E external storage to provide persistent storage for pods.

It creates LVM logical volumes on AnyStor-E and provides persistent volumes via NFS sharing.

## Key Features

- Create, delete, mount, unmount, and resize filesystem volumes via LVM
- Support for thin provisioning (thin volumes)
- Support for snapshots and volume restoration from snapshots
- NFS-based volume sharing across nodes via network zones
- Pacemaker integration for high availability
- Automatic PVC deletion on Pod eviction for StatefulSets

## Automatic PVC Deletion on Pod Eviction

The persistent volumes created by this CSI driver are strictly node-affine to the node on which the pod was scheduled. This is intentional and prevents pods from starting without the LV data, which resides only on the specific node in the Kubernetes cluster.

Consequently, if a pod is evicted (potentially due to cluster autoscaling or updates to the worker node), the pod may become stuck. In certain scenarios, it's acceptable for the pod to start on another node, despite the potential for data loss. The gluesys-csi-controller can capture these events and automatically delete the PVC without requiring manual intervention by an operator.

To use this functionality, the following is needed:

- This only works on `StatefulSet`s with volumeClaimTemplates and volume references to the `gluesys-csi` storage class
- In addition to that, the `Pod` or `PersistentVolumeClaim` managed by the `StatefulSet` needs the annotation: `gms.io/gluesys-csi.is-eviction-allowed: true`

## Installation ##

### Install snapshot-sidecar

```bash
make install-snapshot-sidecars
```

### Update values.yaml

There is to set thinpool for k8s PV and to set networkZone to share k8s cluter with volume
It is supported one thinpool and one network zone

```yaml
storageClasses:
  thin:
    enabled: true
    additionalAnnotations:
      gms.io/thinpool: "thinpool"
      gms.io/thinpoolSize: "10GiB"
      gms.io/networkZone: "internal"
    # this might be used to mark one of the StorageClasses as default:
    # storageclass.kubernetes.io/is-default-class: "true"
    reclaimPolicy: Delete
```

### Install with helm

```bash
helm install gluesys-csi \
    --set lvm.storageVG='VG1' \
    --set lvm.storageVIP='10.0.24.70' \
    --set lvm.storageAuth='GMS API Token' \
    ./charts/gluesys-csi
```

Now you can use one of following storageClasses:

* `gluesys-csi-thin`

If you want to set port and scheme for connecting AnyStor-E API, following next command.

```bash
helm install gluesys-csi \
    --set lvm.storageVG='VG1' \
    --set lvm.storageVIP='10.0.24.70' \
    --set lvm.storageAuth='GMS API Token' \
    --set lvm.storagePort=8443 \
    --set lvm.storageScheme=https \
    ./charts/gluesys-csi
```


## Test ##

```bash
# Create PVC
kubectl apply -f examples/csi-pvc-thin.yaml
kubectl apply -f examples/csi-pod-thin.yaml

# Create Snapshot
kubectl apply -f examples/csi-snapshot-thin.yaml

# Create PV with snapshot
kubectl apply -f examples/csi-snapshot-thin-restore.yaml
kubectl apply -f examples/csi-pod-thin-restore.yaml

# Delete Snapshot
kubectl delete -f examples/csi-snapshot-thin.yaml

# Delete POD
kubectl delete -f examples/csi-pod-thin.yaml

# Delete PVC
kubectl delete -f examples/csi-pvc-thin.yaml
```
