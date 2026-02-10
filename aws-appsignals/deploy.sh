#!/bin/bash
# Deploy OpenTelemetry Demo with AWS Application Signals Collector
# This script deploys with Helm and then patches the ConfigMap to work with Application Signals image

set -e

# Configuration
export AWS_REGION=${AWS_REGION:-us-west-2}
export NAMESPACE=otel-demo
export RELEASE_NAME=opentelemetry-demo
export CHART_VERSION=0.40.2

echo "=========================================="
echo "Deploying OpenTelemetry Demo"
echo "with AWS Application Signals Collector"
echo "=========================================="
echo "Region: ${AWS_REGION}"
echo "Namespace: ${NAMESPACE}"
echo "Release: ${RELEASE_NAME}"
echo "Chart Version: ${CHART_VERSION}"
echo "Collector Image: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest"
echo "=========================================="

# Step 1: Add Helm repository
echo "Step 1: Adding OpenTelemetry Helm repository..."
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Step 2: Verify service account exists
echo "Step 2: Verifying IAM service account exists..."
if ! kubectl get sa opentelemetry-demo-otelcol -n ${NAMESPACE} 2>/dev/null; then
  echo "Error: Service account 'opentelemetry-demo-otelcol' not found in namespace '${NAMESPACE}'"
  echo "Please run ./setup-iam-permissions.sh first"
  exit 1
fi

ROLE_ARN=$(kubectl get sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")

if [ -z "$ROLE_ARN" ]; then
  echo "Error: Service account exists but has no IAM role annotation"
  echo "Please run ./setup-iam-permissions.sh to configure IRSA"
  exit 1
fi

echo "Found service account with IAM role: ${ROLE_ARN}"

# Annotate the service account so Helm can adopt it
echo "Annotating service account for Helm adoption..."
kubectl annotate sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  meta.helm.sh/release-name=${RELEASE_NAME} \
  meta.helm.sh/release-namespace=${NAMESPACE} \
  --overwrite

kubectl label sa opentelemetry-demo-otelcol -n ${NAMESPACE} \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

echo "Service account prepared for Helm"

# Step 3: Install or upgrade the demo with Application Signals configuration
echo "Step 3: Installing OpenTelemetry Demo with Helm..."
helm upgrade --install ${RELEASE_NAME} open-telemetry/opentelemetry-demo \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --values opentelemetry-demo-values.yaml \
  --version ${CHART_VERSION} \
  --wait \
  --timeout 10m

# Step 4: Patch ConfigMap to remove unsupported components
echo "Step 4: Patching ConfigMap to remove unsupported components..."
kubectl apply -f configmap-patch.yaml
echo "ConfigMap patched successfully"

# Step 5: Apply ClusterRole for Application Signals processor
echo "Step 5: Applying ClusterRole for Application Signals processor..."
kubectl apply -f clusterrole.yaml

# Step 6: Update deployment to use Application Signals collector image
echo "Step 6: Updating collector image to Application Signals..."
kubectl set image deployment/otel-collector -n ${NAMESPACE} \
  opentelemetry-collector=public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest

# Step 7: Remove health check probes (not supported by Application Signals collector)
echo "Step 7: Removing health check probes..."
kubectl patch deployment otel-collector -n ${NAMESPACE} --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}
]'

# Step 8: Wait for collector to be ready
echo "Step 8: Waiting for collector to be ready..."
kubectl rollout status deployment/otel-collector -n ${NAMESPACE} --timeout=300s

# Step 9: Wait for all pods to be ready
echo "Step 9: Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod --all -n ${NAMESPACE} --timeout=600s

# Step 10: Get deployment status
echo ""
echo "=========================================="
echo "Deployment Status"
echo "=========================================="
kubectl get pods -n ${NAMESPACE}

# Step 11: Get frontend URL
echo ""
echo "=========================================="
echo "Getting Frontend URL..."
echo "=========================================="
echo "Waiting for LoadBalancer to be provisioned (this may take a few minutes)..."
sleep 30

FRONTEND_URL=$(kubectl get svc -n ${NAMESPACE} frontend-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

if [ "$FRONTEND_URL" = "pending" ] || [ -z "$FRONTEND_URL" ]; then
  echo "LoadBalancer is still being provisioned. Run this command to check status:"
  echo "kubectl get svc -n ${NAMESPACE} frontend-proxy"
else
  echo "Frontend URL: http://${FRONTEND_URL}:8080"
fi

# Step 12: Show useful commands
echo ""
echo "=========================================="
echo "Useful Commands"
echo "=========================================="
echo "View all pods:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo ""
echo "View collector logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=opentelemetry-collector -f"
echo ""
echo "Port-forward frontend (if LoadBalancer is not ready):"
echo "  kubectl port-forward -n ${NAMESPACE} svc/frontend-proxy 8080:8080"
echo ""
echo "View services:"
echo "  kubectl get svc -n ${NAMESPACE}"
echo ""
echo "=========================================="
echo "Application Access"
echo "=========================================="
if [ "$FRONTEND_URL" != "pending" ] && [ -n "$FRONTEND_URL" ]; then
  echo "Via LoadBalancer:"
  echo "  Web Store:        http://${FRONTEND_URL}:8080/"
  echo "  Load Generator:   http://${FRONTEND_URL}:8080/loadgen/"
  echo "  Feature Flags:    http://${FRONTEND_URL}:8080/feature/"
  echo ""
fi
echo "Via Port-Forward (kubectl port-forward -n ${NAMESPACE} svc/frontend-proxy 8080:8080):"
echo "  Web Store:        http://localhost:8080/"
echo "  Load Generator:   http://localhost:8080/loadgen/"
echo "  Feature Flags:    http://localhost:8080/feature/"
echo ""
echo "=========================================="
echo "AWS CloudWatch Resources"
echo "=========================================="
echo "Application Signals:"
echo "  https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#application-signals:"
echo ""
echo "Logs:"
echo "  https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups"
echo "  - /aws/otel-demo/application (Application logs)"
echo "  - /aws/application-signals/data (Application Signals metrics)"
echo "  - /aws/application-signals/custom (Custom metrics)"
echo ""
echo "Traces (X-Ray):"
echo "  https://${AWS_REGION}.console.aws.amazon.com/xray/home?region=${AWS_REGION}#/service-map"
echo ""
echo "CloudWatch Metrics:"
echo "  https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#metricsV2:"
echo "  - Namespace: ApplicationSignals"
echo "  - Namespace: ApplicationSignalsCustom"
echo "=========================================="
echo ""
echo "✅ Deployment complete!"
echo "Note: This deployment uses AWS Application Signals collector"
echo "All telemetry is sent ONLY to AWS CloudWatch (no built-in monitoring tools)"
echo ""
echo "To view Application Signals:"
echo "  aws logs tail /aws/application-signals/data --follow --region ${AWS_REGION}"
