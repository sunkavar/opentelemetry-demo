# Deployment Options for Application Signals Collector

## Why Helm Added Unsupported Components

The OpenTelemetry Demo Helm chart is designed for the **full contrib collector** and automatically adds:
- `k8s_observer` extension for Kubernetes discovery
- `receiver_creator` for dynamic receiver creation
- Various presets for Kubernetes metrics

These components are **not available** in the Application Signals collector image, causing crashes.

## Better Deployment Options

### Option 1: OpenTelemetry Operator (Recommended for Application Signals)

The **OpenTelemetry Operator** is the AWS-recommended way to deploy Application Signals collectors.

**Advantages:**
- ✅ Full control over collector configuration
- ✅ No unwanted components added automatically
- ✅ Native Kubernetes CRD (OpenTelemetryCollector)
- ✅ Used in AWS Application Signals examples
- ✅ Supports auto-instrumentation
- ✅ Better for production deployments

**Installation:**

```bash
# Install cert-manager (required)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Install OpenTelemetry Operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

**Deploy Application Signals Collector:**

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: appsignals-otel
  namespace: otel-demo
spec:
  mode: deployment
  serviceAccount: opentelemetry-demo-otelcol
  image: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest
  config: |
    extensions:
      awsproxy:
      sigv4auth:
        region: "us-west-2"
        service: "xray"
      sigv4auth/logs:
        region: "us-west-2"
        service: "logs"

    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      otlp/application_signals:
        protocols:
          http:
            endpoint: 0.0.0.0:4316

    processors:
      awsapplicationsignals:
        resolvers:
          - platform: eks
      resourcedetection:
        detectors: [env, eks, ec2]
        timeout: 10s
        override: false
      metricstransform/application_signals:
        # ... JVM metrics transformations

    exporters:
      otlphttp:
        traces_endpoint: https://xray.us-west-2.amazonaws.com/v1/traces
        compression: gzip
        auth:
          authenticator: sigv4auth
      awsemf/application_signals:
        region: us-west-2
        log_group_name: "/aws/application-signals/data"
        namespace: "ApplicationSignals"
      awsemf:
        region: us-west-2
        log_group_name: "/aws/application-signals/custom"
        namespace: "ApplicationSignalsCustom"
      otlphttp/logs:
        compression: gzip
        logs_endpoint: https://logs.us-west-2.amazonaws.com/v1/logs
        headers:
          x-aws-log-group: /aws/otel-demo/application
          x-aws-log-stream: default
        auth:
          authenticator: sigv4auth/logs

    service:
      extensions: [sigv4auth, sigv4auth/logs, awsproxy]
      pipelines:
        traces:
          receivers: [otlp, otlp/application_signals]
          processors: [awsapplicationsignals, resourcedetection]
          exporters: [otlphttp]
        metrics/application_signals:
          receivers: [otlp, otlp/application_signals]
          processors: [metricstransform/application_signals, awsapplicationsignals, resourcedetection]
          exporters: [awsemf/application_signals]
        metrics:
          receivers: [otlp]
          processors: [resourcedetection]
          exporters: [awsemf]
        logs:
          receivers: [otlp]
          processors: [resourcedetection]
          exporters: [otlphttp/logs]
```

**Why This Works:**
- You provide the **exact configuration** - nothing is added automatically
- The operator manages the deployment, service, and configmap
- No Helm presets or defaults interfere

---

### Option 2: Plain Kubernetes Manifests (kubectl)

Deploy using raw Kubernetes manifests without Helm.

**Advantages:**
- ✅ Complete control over configuration
- ✅ No Helm magic or presets
- ✅ Simple and transparent
- ✅ Easy to version control

**Disadvantages:**
- ❌ Need to deploy all demo services separately
- ❌ More YAML to maintain
- ❌ No easy upgrades like Helm

**Example:**

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: otel-demo
data:
  config.yaml: |
    extensions:
      awsproxy:
      sigv4auth:
        region: "us-west-2"
        service: "xray"
    # ... rest of config

---
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: otel-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      serviceAccountName: opentelemetry-demo-otelcol
      containers:
      - name: otel-collector
        image: public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest
        args:
          - --config=/conf/config.yaml
        volumeMounts:
        - name: config
          mountPath: /conf
        ports:
        - containerPort: 4317
        - containerPort: 4318
        - containerPort: 4316
      volumes:
      - name: config
        configMap:
          name: otel-collector-config
```

**Deploy:**
```bash
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
```

---

### Option 3: Helm with `alternateConfig` Override (What We Tried)

Use Helm but override the entire config with `alternateConfig`.

**Advantages:**
- ✅ Can still use Helm for demo services
- ✅ Override default configuration

**Disadvantages:**
- ❌ Helm still adds some components (as we experienced)
- ❌ Presets can interfere
- ❌ Not fully reliable for restricted collectors

**Why It Failed:**
Even with `alternateConfig`, the Helm chart's **presets** and **default receivers** were still being added. The chart has hardcoded logic that adds:
- `k8s_observer` for Kubernetes monitoring
- `receiver_creator` for dynamic discovery
- Various Kubernetes-specific components

These are added **outside** of `alternateConfig` in the chart's templates.

---

### Option 4: Fork/Customize Helm Chart

Create a custom Helm chart specifically for Application Signals.

**Advantages:**
- ✅ Full control over chart behavior
- ✅ Can remove all unwanted presets
- ✅ Reusable for your organization

**Disadvantages:**
- ❌ Maintenance burden
- ❌ Need to keep up with upstream changes
- ❌ Overkill for simple deployments

---

## Comparison

| Method | Control | Complexity | Production Ready | AWS Recommended |
|--------|---------|------------|------------------|-----------------|
| **OpenTelemetry Operator** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ✅ Yes | ✅ Yes |
| **kubectl Manifests** | ⭐⭐⭐⭐⭐ | ⭐⭐ | ✅ Yes | ⚠️ Manual |
| **Helm alternateConfig** | ⭐⭐ | ⭐⭐⭐ | ⚠️ Risky | ❌ No |
| **Custom Helm Chart** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ✅ Yes | ⚠️ Manual |

---

## Recommendation for This Project

For the **OpenTelemetry Demo with Application Signals**, I recommend:

### Short-term (Current Approach)
✅ **What we did**: Manual ConfigMap editing + Helm for demo services
- Works for demo/testing
- Quick to implement
- Good for learning

### Long-term (Production)
✅ **OpenTelemetry Operator** for the collector
- Deploy demo services with Helm (without collector)
- Deploy Application Signals collector with Operator
- Best of both worlds

**Example workflow:**
```bash
# 1. Install Operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# 2. Deploy demo services WITHOUT collector
helm install opentelemetry-demo open-telemetry/opentelemetry-demo \
  --set opentelemetry-collector.enabled=false \
  --namespace otel-demo

# 3. Deploy Application Signals collector with Operator
kubectl apply -f appsignals-collector.yaml
```

This gives you:
- ✅ Easy demo service management (Helm)
- ✅ Full collector control (Operator)
- ✅ No configuration conflicts
- ✅ Production-ready approach

---

## What We Learned

The issue wasn't with Helm itself, but with using a **general-purpose Helm chart** (OpenTelemetry Demo) with a **specialized collector image** (Application Signals).

**Key Takeaway:**
When using specialized/restricted collector images like Application Signals, use deployment methods that give you **full configuration control**:
1. OpenTelemetry Operator (best)
2. Plain kubectl manifests (simple)
3. Custom Helm chart (if needed)

Avoid using general-purpose Helm charts that assume a full-featured collector.
