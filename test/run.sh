#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Sets up the end-to-end test environment by:
# - creating a kind cluster
# - deploying cert-manager
# - deploying cert-manager-csi
# The end-to-end test suite will then be run against this environment.
# The cluster will be deleted after tests have run.

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/.."
cd "$REPO_ROOT"

BIN_DIR="$REPO_ROOT/bin"
mkdir -p "$BIN_DIR"
# install_multiplatform will install a binary for either Linux of macOS
# $1 = path to install to
# $2 = filename to save as
# $3 = linux-specific URL
# $4 = mac-specific URL
install_multiplatform() {
  case "$(uname -s)" in

   Darwin)
     curl -Lo "$1/$2" "$4"
     ;;

   Linux)
     curl -Lo "$1/$2" "$3"
     ;;

   *)
     echo 'Unsupported OS!'
     exit 1
     ;;
  esac

  chmod +x "$1/$2"
}

if ! command -v kind; then
  echo "'kind' command not found - installing..."
  install_multiplatform "${BIN_DIR}" kind "https://github.com/kubernetes-sigs/kind/releases/download/v0.5.1/kind-linux-amd64" "https://github.com/kubernetes-sigs/kind/releases/download/v0.5.1/kind-darwin-amd64"
fi

if ! command -v kubectl; then
  echo "'kubectl' command not found - installing..."
  install_multiplatform "${BIN_DIR}" kubectl "https://dl.k8s.io/release/v1.16.15/bin/linux/amd64/kubectl" "https://dl.k8s.io/release/v1.16.15/bin/darwin/amd64/kubectl"
fi

if ! command -v go; then
  echo "'go' command not found - please install from https://golang.org"
  exit 1
fi

if ! command -v docker; then
  echo "'docker' command not found - please install from https://docker.com"
  exit 1
fi

export PATH="$BIN_DIR:$PATH"

CLUSTER_NAME="cert-manager-csi-cluster"
if [ -z "${SKIP_CLEANUP:-}" ]; then
  trap "kind delete cluster --name=$CLUSTER_NAME" EXIT
else
  echo "Skipping cleanup due to SKIP_CLEANUP flag set - run 'kind delete cluster --name=$CLUSTER_NAME' to cleanup"
fi
echo "Creating kind cluster named '$CLUSTER_NAME'"
kind create cluster --image=kindest/node@sha256:bced4bc71380b59873ea3917afe9fb35b00e174d22f50c7cab9188eac2b0fb88 --name="$CLUSTER_NAME"
export KUBECONFIG="$(kind get kubeconfig-path --name="$CLUSTER_NAME")"

CERT_MANAGER_MANIFEST_URL="https://github.com/jetstack/cert-manager/releases/download/v1.4.0/cert-manager.yaml"
echo "Installing cert-manager in test cluster using manifest URL '$CERT_MANAGER_MANIFEST_URL'"
kubectl create -f "$CERT_MANAGER_MANIFEST_URL"

echo "Building cert-manager-csi binary"
CGO_ENABLED=0 GOARCH=amd64 GOOS=linux go build -o ./bin/cert-manager-csi ./cmd

CERT_MANAGER_CSI_DOCKER_IMAGE="quay.io/jetstack/cert-manager-csi"
CERT_MANAGER_CSI_DOCKER_TAG="canary"
echo "Building cert-manager-csi container"
docker build -t "$CERT_MANAGER_CSI_DOCKER_IMAGE:$CERT_MANAGER_CSI_DOCKER_TAG" .

echo "Loading '$CERT_MANAGER_CSI_DOCKER_IMAGE:$CERT_MANAGER_CSI_DOCKER_TAG' image into kind cluster"
kind load docker-image --name="$CLUSTER_NAME" "$CERT_MANAGER_CSI_DOCKER_IMAGE:$CERT_MANAGER_CSI_DOCKER_TAG"

echo "Deploying cert-manager-csi into test cluster"
./bin/helm upgrade --install -n cert-manager cert-manager-csi ./deploy/charts/csi --set image.repository=$CERT_MANAGER_CSI_DOCKER_IMAGE --set image.tag=$CERT_MANAGER_CSI_DOCKER_TAG

echo "Waiting 30s to allow Deployment & DaemonSet controllers to create pods"
sleep 30

kubectl get pods -A
echo "Waiting for all pods to be ready..."
kubectl wait --for=condition=Ready pod --all --all-namespaces --timeout=5m

echo "Executing end-to-end test suite"

# Export variables used by test suite
export REPO_ROOT
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export CLUSTER_NAME
export KUBECTL=$(command -v kubectl)
go test -v -timeout 30m "./test/e2e/suite"
