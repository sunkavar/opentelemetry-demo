#!/bin/bash
# Setup IAM permissions for OpenTelemetry Collector using IRSA
set -e

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

echo "Creating namespace ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo "Associating IAM OIDC provider with cluster..."
eksctl utils associate-iam-oidc-provider \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --approve

echo "Creating custom IAM policy ${POLICY_NAME}..."
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

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn ${POLICY_ARN} 2>/dev/null; then
  echo "Policy ${POLICY_NAME} already exists"
else
  aws iam create-policy \
    --policy-name ${POLICY_NAME} \
    --policy-document file:///tmp/cloudwatch-otel-policy.json
  echo "Policy ${POLICY_NAME} created"
fi

echo "Creating IAM service account with eksctl..."
eksctl create iamserviceaccount \
  --name ${SERVICE_ACCOUNT} \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --attach-policy-arn ${POLICY_ARN} \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts

ROLE_ARN=$(kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')

echo "=========================================="
echo "IAM Permissions configured successfully!"
echo "=========================================="
echo "Service Account: ${SERVICE_ACCOUNT}"
echo "Namespace: ${NAMESPACE}"
echo "IAM Role ARN: ${ROLE_ARN}"
echo "=========================================="
echo ""
echo "Next step: Run ./deploy-demo.sh"

rm -f /tmp/cloudwatch-otel-policy.json