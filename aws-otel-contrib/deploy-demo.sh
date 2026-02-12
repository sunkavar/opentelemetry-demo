#!/bin/bash
# Deploy OpenTelemetry Demo to EKS with CloudWatch integration
set -e

export AWS_REGION=${AWS_REGION:-us-west-2}
export NAMESPACE=otel-demo
export RELEASE_NAME=opentelemetry-demo
export CHART_VERSION=0.40.2

echo "=========================================="
echo "Deploying OpenTelemetry Demo"
echo "=========================================="
echo "Region: ${AWS_REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Release: ${RELEASE_NAME}"
echo "=========================================="

echo "Adding OpenTelemetry Helm repository..."
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

echo "Verifying IAM service account exists..."
if ! kubectl get sa opentelemetry-demo-otelcol -n ${NAMESPACE} 2>/dev/null; then
  echo "Error: Service account not found. Run ./setup-iam-permissions.sh first"
  exit 1
fi

ROLE_ARN=$(kubectl get sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

if [ -z "$ROLE_ARN" ]; then
  echo "Error: Service account has no IAM role annotation"
  echo "Run ./setup-iam-permissions.sh to configure IRSA"
  exit 1
fi

echo "Found service account with IAM role: ${ROLE_ARN}"

echo "Annotating service account for Helm adoption..."
kubectl annotate sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  meta.helm.sh/release-name=${RELEASE_NAME} \
  meta.helm.sh/release-namespace=${NAMESPACE} \
  --overwrite

kubectl label sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

echo "Installing OpenTelemetry Demo..."
helm upgrade --install ${RELEASE_NAME} open-telemetry/opentelemetry-demo \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --values opentelemetry-demo-values.yaml \
  --version ${CHART_VERSION} \
  --wait \
  --timeout 10m

echo "Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod --all -n ${NAMESPACE} --timeout=600s

echo ""
echo "=========================================="
echo "Deployment Status"
echo "=========================================="
kubectl get pods -n ${NAMESPACE}

echo ""
echo "Getting Frontend URL..."
sleep 30

FRONTEND_URL=$(kubectl get svc -n ${NAMESPACE} frontend-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

if [ "$FRONTEND_URL" = "pending" ] || [ -z "$FRONTEND_URL" ]; then
  echo "LoadBalancer is still being provisioned"
  echo "Check status: kubectl get svc -n ${NAMESPACE} frontend-proxy"
else
  echo "Frontend URL: http://${FRONTEND_URL}:8080"
fi

echo ""
echo "=========================================="
echo "Access Application"
echo "=========================================="
echo "Port-forward: kubectl port-forward -n ${NAMESPACE} svc/frontend-proxy 8080:8080"
echo "Then visit: http://localhost:8080"
echo ""
echo "=========================================="
echo "AWS CloudWatch Resources"
echo "=========================================="
echo "Logs: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups"
echo "Traces: https://${AWS_REGION}.console.aws.amazon.com/xray/home?region=${AWS_REGION}#/service-map"
echo "Metrics: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#metricsV2:"
echo "=========================================="