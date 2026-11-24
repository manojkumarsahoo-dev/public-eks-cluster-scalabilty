#!/usr/bin/env bash
# Installs Cluster Autoscaler for the cluster named in CLUSTER_NAME.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-manoj}"
CA_VERSION="${CA_VERSION:-1.35.2}"   # use the latest 1.35.x patch release

URL="https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-${CA_VERSION}/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml"

curl -fsSL "$URL" -o /tmp/cluster-autoscaler.yaml
sed -i "s|<YOUR CLUSTER NAME>|${CLUSTER_NAME}|g" /tmp/cluster-autoscaler.yaml
sed -i "s|registry.k8s.io/autoscaling/cluster-autoscaler:v[0-9.]*|registry.k8s.io/autoscaling/cluster-autoscaler:v${CA_VERSION}|g" /tmp/cluster-autoscaler.yaml

kubectl apply -f /tmp/cluster-autoscaler.yaml
kubectl -n kube-system annotate deployment.apps/cluster-autoscaler \
  cluster-autoscaler.kubernetes.io/safe-to-evict="false" --overwrite
# Tell Cluster Autoscaler the region explicitly (avoids region lookup problems)
kubectl -n kube-system set env deployment/cluster-autoscaler AWS_REGION="${AWS_REGION:-us-east-1}"

# Restart so the pod picks up the Pod Identity credentials
kubectl -n kube-system rollout restart deployment/cluster-autoscaler

if ! kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout=180s; then
  echo "=== Cluster Autoscaler is not healthy. Diagnostics: ==="
  kubectl -n kube-system get pods -l app=cluster-autoscaler -o wide || true
  kubectl -n kube-system describe pods -l app=cluster-autoscaler | tail -40 || true
  echo "--- current container logs ---"
  kubectl -n kube-system logs -l app=cluster-autoscaler --tail=60 || true
  echo "--- previous (crashed) container logs ---"
  kubectl -n kube-system logs -l app=cluster-autoscaler --previous --tail=60 || true
  exit 1
fi

echo "Check the discovery flag:"
kubectl -n kube-system get deployment cluster-autoscaler -o yaml | grep node-group-auto-discovery
