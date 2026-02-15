#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="default"
SNAPSHOT_VERSION="v6.3.0"

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      SNAPSHOT_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Install CSI Snapshot Controller and CRDs"
      echo ""
      echo "Options:"
      echo "  -v, --version VERSION        Snapshot sidecar version (default: v6.3.0)"
      echo "  -h, --help                   Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

echo -e "${GREEN}CSI Snapshot Sidecar Installation${NC}"
echo "================================"
echo "Version: $SNAPSHOT_VERSION"
echo "================================"
echo ""

if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}Error: kubectl is not installed${NC}"
  exit 1
fi

echo -e "${YELLOW}Installing Snapshot CRDs...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOT_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOT_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOT_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml

echo -e "${YELLOW}Installing Snapshot Controller...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOT_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOT_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

echo ""
echo -e "${GREEN}Installation completed successfully!${NC}"
