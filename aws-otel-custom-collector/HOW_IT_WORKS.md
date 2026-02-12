# How the Application Signals Deployment Works

## The Challenge

The AWS Application Signals collector image (`public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest`) has a **limited set of components**:

**Supported:**
- Receivers: `otlp`
- Processors: `awsapplicationsignals`, `resourcedetection`, `metricstransform`
- Extensions: `awsproxy`, `sigv4auth`
- Exporters: `otlphttp`, `awsemf`

**NOT Supported:**
- `k8s_observer` extension
- `receiver_creator` receiver
- `health_check` extension
- `memory_limiter` processor
- `batch` processor
- Many other contrib components

The OpenTelemetry Demo Helm chart automatically adds unsupported components, causing the collector to crash.

## The Solution

Our `deploy.sh` script uses a **hybrid approach**:

### Step-by-Step Process

```
1. Helm Install
   ├─> Deploys all demo services
   ├─> Creates ConfigMap with unsupported components
   └─> Uses wrong collector image

2. ConfigMap Patch
   ├─> Applies configmap-patch.yaml
   ├─> Removes k8s_observer extension
   ├─> Removes receiver_creator receiver
   └─> Keeps only supported components

3. Image Update
   ├─> Changes collector image to Application Signals
   └─> kubectl set image deployment/otel-collector

4. RBAC Setup
   ├─> Applies clusterrole.yaml
   ├─> Grants permissions for awsapplicationsignals processor
   └─> Allows access to Kubernetes resources

5. Health Probe Removal
   ├─> Removes liveness probe (port 13133)
   ├─> Removes readiness probe (port 13133)
   └─> Application Signals collector doesn't support health_check

6. Rollout
   ├─> Waits for new pods to start
   └─> Collector runs successfully
```

### Why Each Step is Needed

#### 1. Helm Install
- **Why**: Easiest way to deploy all 20+ demo services
- **Problem**: Adds unsupported components to collector config
- **Solution**: Patch after deployment

#### 2. ConfigMap Patch
- **Why**: Remove components not in Application Signals image
- **What's removed**:
  ```yaml
  extensions:
    k8s_observer:  # ❌ Not supported
  
  receivers:
    receiver_creator/metrics:  # ❌ Not supported
  
  service:
    extensions:
      - k8s_observer  # ❌ Remove from list
    pipelines:
      metrics:
        receivers:
          - receiver_creator/metrics  # ❌ Remove from list
  ```
- **Result**: Clean config with only supported components

#### 3. Image Update
- **Why**: Helm values don't override the image reliably
- **Command**: `kubectl set image deployment/otel-collector`
- **Result**: Uses Application Signals collector

#### 4. RBAC Setup
- **Why**: `awsapplicationsignals` processor needs Kubernetes access
- **Permissions needed**:
  - List/watch pods, services, nodes
  - Get configmaps (for aws-auth)
  - Access to resource metadata
- **Result**: Processor can discover services and enrich telemetry

#### 5. Health Probe Removal
- **Why**: Application Signals collector doesn't have `health_check` extension
- **Problem**: Liveness/readiness probes check port 13133
- **Solution**: Remove probes entirely
- **Result**: Pods stay running

## Files Explained

### opentelemetry-demo-values.yaml
Helm values file with Application Signals configuration:
- Disables built-in monitoring tools (Grafana, Jaeger, etc.)
- Configures Application Signals processors and exporters
- Sets up receivers for OTLP and Application Signals
- **Note**: Some components here are overridden by Helm defaults

### configmap-patch.yaml
Clean ConfigMap with only supported components:
- No `k8s_observer`
- No `receiver_creator`
- Only `awsproxy` and `sigv4auth` extensions
- Only `otlp` receivers
- Only supported processors

### clusterrole.yaml
RBAC permissions for Application Signals:
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "nodes", "endpoints"]
    verbs: ["list", "watch", "get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["aws-auth"]
    verbs: ["get"]
```

### deploy.sh
Main deployment script that orchestrates everything:
1. Validates prerequisites
2. Deploys with Helm
3. Patches ConfigMap
4. Updates image
5. Applies RBAC
6. Removes health probes
7. Waits for rollout
8. Shows status and URLs

## Alternative Approaches

### Option 1: OpenTelemetry Operator (Better for Production)
```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: appsignals-otel
spec:
  image: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest
  config: |
    # Your exact config - nothing added automatically
```

**Pros:**
- ✅ No automatic component addition
- ✅ Full control over configuration
- ✅ Production-ready
- ✅ AWS recommended

**Cons:**
- ❌ Need to deploy demo services separately
- ❌ More complex setup

### Option 2: Plain kubectl Manifests
Deploy everything with raw Kubernetes YAML.

**Pros:**
- ✅ Complete control
- ✅ No Helm magic

**Cons:**
- ❌ Much more YAML to maintain
- ❌ No easy upgrades

### Option 3: Custom Helm Chart
Fork and modify the OpenTelemetry Demo chart.

**Pros:**
- ✅ Full control
- ✅ Reusable

**Cons:**
- ❌ Maintenance burden
- ❌ Need to track upstream changes

## Why Our Approach Works

Our hybrid approach gives you:
- ✅ **Single command deployment**: `./deploy.sh`
- ✅ **All demo services**: Helm manages 20+ microservices
- ✅ **Application Signals collector**: Automatic patching makes it work
- ✅ **Repeatable**: Script can be run multiple times
- ✅ **Transparent**: Each step is logged and explained

## Troubleshooting

### Collector Crashes with "unknown type" errors
**Cause**: ConfigMap patch didn't apply
**Solution**: 
```bash
kubectl apply -f configmap-patch.yaml
kubectl rollout restart deployment/otel-collector -n otel-demo
```

### Collector restarts continuously
**Cause**: Health probes still present
**Solution**:
```bash
kubectl patch deployment otel-collector -n otel-demo --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}
]'
```

### RBAC errors in logs
**Cause**: ClusterRole not applied
**Solution**:
```bash
kubectl apply -f clusterrole.yaml
kubectl rollout restart deployment/otel-collector -n otel-demo
```

### Wrong collector image
**Cause**: Image update didn't apply
**Solution**:
```bash
kubectl set image deployment/otel-collector -n otel-demo \
  opentelemetry-collector=public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest
```

## Verification

Check that everything is working:

```bash
# 1. Collector is running
kubectl get pods -n otel-demo | grep otel-collector
# Should show: 1/1 Running

# 2. Using correct image
kubectl get deployment otel-collector -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest

# 3. No unsupported components in config
kubectl get configmap otel-collector -n otel-demo -o yaml | grep -E "k8s_observer|receiver_creator"
# Should return nothing

# 4. Processing telemetry
kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=20
# Should show: "Everything is ready. Begin running and processing data."
```

## Summary

This deployment proves that you **can** use the Application Signals collector with Helm, but it requires post-deployment patching. For production, consider using the OpenTelemetry Operator for cleaner configuration management.

The key insight: **Helm is great for deploying services, but specialized collector images need configuration control that Helm charts don't always provide.**
