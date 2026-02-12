#!/bin/bash
# Setup IAM permissions for OpenTelemetry Collector to access CloudWatch
# This script uses eksctl to create IAM service account with IRSA (IAM Roles for Service Accounts)

set -e

# Configuration
export AWS_REGION=${AWS_REGION:-us-west-2}
export CLUSTER_NAME=${CLUSTER_NAME:-otel-demo-cluster}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NAMESPACE=otel-demo
export SERVICE_ACCOUNT=opentelemetry-demo-otelcol
export POLICY_NAME=CloudWatchOTelDemoPolicy

echo "=========================================="
echo "Setting up IAM Permissions with eksctl"
echo "=========================================="
echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Service Account: ${SERVICE_ACCOUNT}"
echo "=========================================="

# Step 1: Create namespace
echo "Step 1: Creating namespace ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Associate IAM OIDC provider (if not already done)
echo "Step 2: Associating IAM OIDC provider with cluster..."
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --approve

# Step 3: Create custom IAM policy for CloudWatch, X-Ray, and Logs
echo "Step 3: Creating custom IAM policy ${POLICY_NAME}..."
cat > /tmp/cloudwatch-otel-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Check if policy exists, if not create it
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn ${POLICY_ARN} 2>/dev/null; then
  echo "Policy ${POLICY_NAME} already exists"
else
  aws iam create-policy \
    --policy-name ${POLICY_NAME} \
    --policy-document file:///tmp/cloudwatch-otel-policy.json
  echo "Policy ${POLICY_NAME} created"
fi

# Step 4: Create IAM service account using eksctl
# This automatically creates the IAM role, trust policy, and Kubernetes service account
echo "Step 4: Creating IAM service account with eksctl..."
echo "This will create:"
echo "  - Kubernetes ServiceAccount: ${SERVICE_ACCOUNT} in namespace ${NAMESPACE}"
echo "  - IAM Role with trust policy for OIDC"
echo "  - Annotation linking ServiceAccount to IAM Role"

eksctl create iamserviceaccount \
  --name ${SERVICE_ACCOUNT} \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --attach-policy-arn ${POLICY_ARN} \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts

# Step 5: Get the created role ARN
echo "Step 5: Getting IAM role ARN..."
ROLE_ARN=$(kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')

echo "=========================================="
echo "IAM Permissions configured successfully!"
echo "=========================================="
echo "Service Account: ${SERVICE_ACCOUNT}"
echo "Namespace: ${NAMESPACE}"
echo "IAM Role ARN: ${ROLE_ARN}"
echo "Custom Policy ARN: ${POLICY_ARN}"
echo "AWS Managed Policy: CloudWatchAgentServerPolicy"
echo "=========================================="
echo ""
echo "Note: The Helm chart will use the existing service account"
echo "created by eksctl. Make sure to set serviceAccount.create=false"
echo "in your Helm values or the deployment will fail."
echo ""
echo "Next step:"
echo "Run ./deploy-demo.sh to deploy the OpenTelemetry demo"

# Cleanup temp files
rm -f /tmp/cloudwatch-otel-policy.json
