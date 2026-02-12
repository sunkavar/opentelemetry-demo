# OpenTelemetry Demo - AWS EKS Deployment

Deploy the standard OpenTelemetry demo application to AWS EKS without CloudWatch integration.

## Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl installed
- eksctl installed
- An active EKS cluster (or use the provided setup script)

## Quick Start

### 1. Create EKS Cluster (Optional)

If you don't have an existing cluster:

```bash
./setup-eks-cluster.sh
```

This creates a cluster named `otel-demo` in `us-west-2` with 2 t3.xlarge nodes.

### 2. Deploy OpenTelemetry Demo

```bash
kubectl create namespace otel-demo
kubectl apply -n otel-demo -f https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/kubernetes/opentelemetry-demo.yaml
```

### 3. Verify Deployment

```bash
# Check pod status
kubectl get pods -n otel-demo

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod --all -n otel-demo --timeout=600s
```

## Accessing the Application

### Port Forwarding

Expose the frontend-proxy service locally:

```bash
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```

> **Note:** `kubectl port-forward` runs until terminated with Ctrl-C.
> For multiple services, open separate terminal sessions.

### Available Services

Once port-forwarding is active, access these services:

- **Web Store:** <http://localhost:8080/>
- **Grafana:** <http://localhost:8080/grafana/>
- **Load Generator:** <http://localhost:8080/loadgen/>
- **Jaeger UI:** <http://localhost:8080/jaeger/ui/>
- **Feature Flags:** <http://localhost:8080/feature/>

## Troubleshooting

### Pods Not Starting

```bash
# Check pod logs
kubectl logs -n otel-demo <pod-name>

# Describe pod for events
kubectl describe pod -n otel-demo <pod-name>
```

### Service Not Found

```bash
# List all services
kubectl get svc -n otel-demo

# Verify frontend-proxy exists
kubectl get svc -n otel-demo frontend-proxy
```

### Clean Up Partial Deployments

If you need to redeploy after a failed installation:

```bash
# Delete all resources in the namespace
kubectl delete namespace otel-demo

# Wait for namespace deletion to complete
kubectl get namespace otel-demo --watch

# Redeploy
kubectl create namespace otel-demo
kubectl apply -n otel-demo -f https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/kubernetes/opentelemetry-demo.yaml
```

## Cleanup

### Delete Demo Application

```bash
kubectl delete namespace otel-demo
```

### Delete EKS Cluster

```bash
eksctl delete cluster --name otel-demo --region us-west-2
```

## Architecture

This deployment includes:

- **Frontend Services:** Web store UI and proxy
- **Backend Services:** Multiple microservices (cart, checkout, product catalog, etc.)
- **Observability Stack:**
  - OpenTelemetry Collector
  - Jaeger for distributed tracing
  - Prometheus for metrics
  - Grafana for visualization
- **Supporting Services:** PostgreSQL, Redis, Kafka

All telemetry data stays within the cluster (no CloudWatch integration).
