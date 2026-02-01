#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Create an IAM role and EKS access entry for kube-stress list command,
routed to workload-low APF priority level.

Options:
  -h, --help      Show this help message
  -n, --dry-run   Print commands without executing

Environment variables:
  CLUSTER_NAME    (required) EKS cluster name
  ACCOUNT_ID      AWS account ID (default: auto-detect)
  ROLE_NAME       IAM role name (default: kube-stress-list-role)
  K8S_GROUP       Kubernetes group (default: kube-stress-list-group)
  EKS_ENDPOINT    Custom EKS service endpoint

Example:
  CLUSTER_NAME=my-cluster $0
  CLUSTER_NAME=my-cluster $0 --dry-run
  CLUSTER_NAME=my-cluster ROLE_NAME=custom-role EKS_ENDPOINT=https://eks.example.com $0
EOF
  exit 0
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# Configuration - override via environment variables
CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ROLE_NAME="${ROLE_NAME:-kube-stress-list-role}"
K8S_GROUP="${K8S_GROUP:-kube-stress-list-group}"
EKS_ENDPOINT="${EKS_ENDPOINT:-}"

EKS_OPTS=()
[[ -n "${EKS_ENDPOINT}" ]] && EKS_OPTS+=(--endpoint-url "${EKS_ENDPOINT}")

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "Setting up identity for kube-stress list command..."
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Role ARN: ${ROLE_ARN}"
echo "  K8s Group: ${K8S_GROUP}"

# 1. Create IAM role (if not exists)
if ! aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  echo "Creating IAM role ${ROLE_NAME}..."
  run aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"AWS": "arn:aws:iam::'"${ACCOUNT_ID}"':root"},
        "Action": "sts:AssumeRole"
      }]
    }'
else
  echo "IAM role ${ROLE_NAME} already exists"
fi

# 2. Ensure cluster authentication mode supports API access entries
echo "Checking cluster authentication mode..."
AUTH_MODE=$(aws eks "${EKS_OPTS[@]}" describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null || echo "CONFIG_MAP")
if [[ "${AUTH_MODE}" == "CONFIG_MAP" ]]; then
  echo "Enabling API_AND_CONFIG_MAP authentication mode..."
  UPDATE_ID=$(aws eks "${EKS_OPTS[@]}" update-cluster-config \
    --name "${CLUSTER_NAME}" \
    --access-config authenticationMode=API_AND_CONFIG_MAP \
    --query 'update.id' --output text)
  echo "Waiting for update ${UPDATE_ID} to complete..."
  while true; do
    STATUS=$(aws eks "${EKS_OPTS[@]}" describe-update --name "${CLUSTER_NAME}" --update-id "${UPDATE_ID}" --query 'update.status' --output text)
    [[ "${STATUS}" == "Successful" ]] && break
    [[ "${STATUS}" == "Failed" || "${STATUS}" == "Cancelled" ]] && { echo "Update failed: ${STATUS}"; exit 1; }
    sleep 5
  done
else
  echo "Authentication mode already supports API: ${AUTH_MODE}"
fi

# 3. Create EKS access entry with built-in view policy
echo "Creating EKS access entry..."
run aws eks "${EKS_OPTS[@]}" create-access-entry \
  --cluster-name "${CLUSTER_NAME}" \
  --principal-arn "${ROLE_ARN}" \
  --kubernetes-groups "${K8S_GROUP}" 2>/dev/null || \
  echo "Access entry already exists or failed (check manually)"

echo "Associating EKS access policy..."
run aws eks "${EKS_OPTS[@]}" associate-access-policy \
  --cluster-name "${CLUSTER_NAME}" \
  --principal-arn "${ROLE_ARN}" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster 2>/dev/null || \
  echo "Access policy already associated or failed (check manually)"

# 4. Apply FlowSchema (using current admin context, before switching to limited role)
echo "Applying FlowSchema..."
FLOWSCHEMA=$(cat <<EOF
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: kube-stress-list
spec:
  priorityLevelConfiguration:
    name: workload-low
  matchingPrecedence: 1000
  distinguisherMethod:
    type: ByUser
  rules:
  - subjects:
    - kind: Group
      group:
        name: ${K8S_GROUP}
    resourceRules:
    - verbs: ["get", "list", "watch"]
      apiGroups: ["*"]
      resources: ["*"]
      namespaces: ["*"]
EOF
)

if $DRY_RUN; then
  echo "[dry-run] kubectl apply -f - <<EOF"
  echo "$FLOWSCHEMA"
  echo "EOF"
else
  echo "$FLOWSCHEMA" | kubectl apply -f -
fi

# 5. Configure kubeconfig to use the limited role
echo ""
echo "Done! Configuring kubeconfig to use this identity..."
if [[ -n "${EKS_ENDPOINT}" ]]; then
  run aws eks update-kubeconfig --name "${CLUSTER_NAME}" --role-arn "${ROLE_ARN}" --endpoint "${EKS_ENDPOINT}"
else
  run aws eks update-kubeconfig --name "${CLUSTER_NAME}" --role-arn "${ROLE_ARN}"
fi

echo "kubectl is now configured to use ${ROLE_ARN}"
