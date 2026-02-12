#!/bin/bash
# Setup EKS cluster for OpenTelemetry Demo with CloudWatch integration
# Region: us-west-2

set -e

# Configuration
export AWS_REGION=${AWS_REGION:-us-west-2}
export CLUSTER_NAME=${CLUSTER_NAME:-otel-demo}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=========================================="
echo "Creating EKS Cluster for OpenTelemetry Demo"
echo "=========================================="
echo "Region: ${AWS_REGION}"
echo "Cluster Name: ${CLUSTER_NAME}"
echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "=========================================="

# Step 1: Create EKS cluster
echo "Step 1: Creating EKS cluster (this will take 15-20 minutes)..."
eksctl create cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --version 1.34 \
  --nodegroup-name standard-workers \
  --node-type t3.xlarge \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed \
  --with-oidc

# Step 2: Update kubeconfig
echo "Step 2: Updating kubeconfig..."
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

# Step 3: Verify cluster
echo "Step 3: Verifying cluster access..."
kubectl get nodes