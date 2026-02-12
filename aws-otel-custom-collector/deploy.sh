#!/bin/bash
# Deploy OpenTelemetry Demo with AWS Application Signals Collector
set -e

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
echo "Collector Image: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest"
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

echo "Installing OpenTelemetry Demo with Helm..."
helm upgrade --install ${RELEASE_NAME} open-telemetry/opentelemetry-demo \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --values opentelemetry-demo-values.yaml \
  --version ${CHART_VERSION} \
  --wait \
  --timeout 10m

echo "Patching ConfigMap to remove unsupported components..."
kubectl apply -f configmap-patch.yaml

echo "Applying ClusterRole for Application Signals processor..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-role
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "namespaces", "endpoints", "services"]
    verbs: ["list", "watch", "get"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "daemonsets", "deployments", "statefulsets"]
    verbs: ["list", "watch", "get"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["list", "watch"]
  - apiGroups: [""]
    resources: ["nodes/proxy"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["nodes/stats", "configmaps", "events"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["aws-auth"]
    verbs: ["get"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: otel-collector-role-binding
subjects:
  - kind: ServiceAccount
    name: opentelemetry-demo-otelcol
    namespace: otel-demo
roleRef:
  kind: ClusterRole
  name: otel-collector-role
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Updating collector image to Application Signals..."
kubectl set image deployment/otel-collector -n ${NAMESPACE} \
  opentelemetry-collector=public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest

echo "Removing health check probes..."
kubectl patch deployment otel-collector -n ${NAMESPACE} --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}
]'

echo "Waiting for collector to be ready..."
kubectl rollout status deployment/otel-collector -n ${NAMESPACE} --timeout=300s

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
echo "Application Signals: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#application-signals:"
echo "Logs: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups"
echo "Traces: https://${AWS_REGION}.console.aws.amazon.com/xray/home?region=${AWS_REGION}#/service-map"
echo "Metrics: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#metricsV2:"
echo "=========================================="