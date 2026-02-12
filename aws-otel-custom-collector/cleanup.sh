#!/bin/bash
# Cleanup all OpenTelemetry Demo resources
set -e

export AWS_REGION=${AWS_REGION:-us-west-2}
export CLUSTER_NAME=${CLUSTER_NAME:-otel-demo-cluster}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NAMESPACE=otel-demo
export RELEASE_NAME=opentelemetry-demo
export POLICY_NAME=CloudWatchOTelDemoPolicy

echo "=========================================="
echo "Cleaning up OpenTelemetry Demo Resources"
echo "=========================================="
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "=========================================="

read -p "This will delete all resources. Are you sure? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
  echo "Cleanup cancelled"
  exit 0
fi

echo "Deleting Helm release..."
helm uninstall ${RELEASE_NAME} -n ${NAMESPACE} || echo "Helm release not found"

echo "Deleting ClusterRole and ClusterRoleBinding..."
kubectl delete clusterrole otel-collector-role --ignore-not-found=true
kubectl delete clusterrolebinding otel-collector-role-binding --ignore-not-found=true

echo "Deleting namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

echo "Deleting IAM service account..."
eksctl delete iamserviceaccount \
  --name opentelemetry-demo-otelcol \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo "IAM service account already deleted"

echo "Deleting custom IAM policy..."
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
aws iam delete-policy --policy-arn ${POLICY_ARN} 2>/dev/null || echo "Policy already deleted"

echo ""
read -p "Delete EKS cluster ${CLUSTER_NAME}? (yes/no): " delete_cluster
if [ "$delete_cluster" = "yes" ]; then
  echo "Deleting EKS cluster (this will take 10-15 minutes)..."
  eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
else
  echo "Keeping EKS cluster ${CLUSTER_NAME}"
fi

echo ""
echo "=========================================="
echo "Cleanup completed!"
echo "=========================================="
echo ""
echo "Note: CloudWatch log groups retained. To delete manually:"
echo "  aws logs delete-log-group --log-group-name /aws/otel-demo/application --region ${AWS_REGION}"
echo "  aws logs delete-log-group --log-group-name /aws/application-signals/data --region ${AWS_REGION}"