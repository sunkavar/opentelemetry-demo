#!/bin/bash
# Cleanup all resources created for OpenTelemetry Demo

set -e

# Configuration
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

# Step 1: Delete Helm release
echo "Step 1: Deleting Helm release..."
helm uninstall ${RELEASE_NAME} -n ${NAMESPACE} || echo "Helm release not found"

# Step 2: Delete namespace
echo "Step 2: Deleting namespace..."
kubectl delete namespace ${NAMESPACE} --ignore-not-found=true

# Step 3: Delete IAM service account (created by eksctl)
echo "Step 3: Deleting IAM service account..."
eksctl delete iamserviceaccount \
  --name opentelemetry-demo-otelcol \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} 2>/dev/null || echo "IAM service account already deleted"

# Step 4: Delete custom IAM policy
echo "Step 4: Deleting custom IAM policy..."
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
aws iam delete-policy --policy-arn ${POLICY_ARN} 2>/dev/null || echo "Policy already deleted"

# Step 5: Ask about EKS cluster deletion
echo ""
read -p "Do you want to delete the EKS cluster ${CLUSTER_NAME}? (yes/no): " delete_cluster
if [ "$delete_cluster" = "yes" ]; then
  echo "Step 5: Deleting EKS cluster (this will take 10-15 minutes)..."
  eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
else
  echo "Keeping EKS cluster ${CLUSTER_NAME}"
fi

# Step 6: Clean up local files
echo "Step 6: Cleaning up local files..."
# No local files to clean up with eksctl approach

echo ""
echo "=========================================="
echo "Cleanup completed!"
echo "=========================================="
echo ""
echo "Note: CloudWatch log groups and X-Ray traces are retained."
echo "To delete them manually:"
echo "  aws logs delete-log-group --log-group-name /aws/otel-demo/application --region ${AWS_REGION}"
echo "  aws logs delete-log-group --log-group-name /aws/otel-demo/metrics --region ${AWS_REGION}"
