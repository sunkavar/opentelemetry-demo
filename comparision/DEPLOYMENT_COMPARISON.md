# OpenTelemetry Demo Deployment Comparison

Comparison of four deployment approaches for OpenTelemetry Demo on AWS EKS.

## Overview

| Approach | Collector Type | Telemetry Destination | Built-in Tools | Complexity |
|----------|---------------|----------------------|----------------|------------|
| **simple-deployment-no-cw** | Standard OTel Contrib | In-cluster only | ✅ All enabled | ⭐ Easiest |
| **dd-otel-contrib** | Standard OTel Contrib | Datadog + In-cluster | ✅ All enabled | ⭐⭐ Easy-Moderate |
| **otel-contrib-cw** | Standard OTel Contrib | AWS CloudWatch | ❌ All disabled | ⭐⭐ Moderate |
| **otel-custom-collector-cw** | AWS Application Signals | AWS CloudWatch | ❌ All disabled | ⭐⭐⭐ Complex |

---

## 1. simple-deployment-no-cw (Easiest)

### What It Is
Standard OpenTelemetry Demo deployment with all built-in observability tools running in-cluster.

### Onboarding Steps
```bash
# 1. Create EKS cluster (optional)
./setup-eks-cluster.sh

# 2. Deploy demo
kubectl create namespace otel-demo
kubectl apply -n otel-demo -f https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/kubernetes/opentelemetry-demo.yaml

# 3. Access via port-forward
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```

### Pros
- **Simplest setup** - Just 2 commands (after cluster creation)
- **No AWS configuration** - No IAM roles, no IRSA, no CloudWatch setup
- **Immediate visualization** - Grafana, Jaeger, Prometheus included
- **Self-contained** - Everything runs in-cluster
- **No AWS costs** - No CloudWatch ingestion charges
- **Quick iteration** - Fast to deploy and tear down

### Cons
- **No AWS integration** - Can't use CloudWatch, X-Ray, or Application Signals
- **Resource intensive** - Runs Grafana, Jaeger, Prometheus, OpenSearch in-cluster
- **Not production-like** - Doesn't reflect real AWS observability patterns
- **Limited scalability** - All data stored in-cluster
- **Manual access** - Requires port-forwarding for each service

### Best For
- **Learning OpenTelemetry** basics
- **Quick demos** without AWS complexity
- **Development/testing** without AWS costs
- **Understanding the demo app** itself

### Time to Deploy
- **Cluster creation**: 15-20 minutes
- **Demo deployment**: 5-10 minutes
- **Total**: ~25-30 minutes

---

## 2. dd-otel-contrib (Easy-Moderate)

### What It Is
OpenTelemetry Demo with Datadog APM integration, sending telemetry to both Datadog and in-cluster tools (Jaeger, Prometheus, Grafana).

### Onboarding Steps
```bash
# 1. Create EKS cluster
eksctl create cluster --name otel-demo-cluster --region us-east-1 \
  --node-type t3.xlarge --nodes 3

# 2. Add Helm repository
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 3. Create Datadog API key secret
kubectl create secret generic datadog-secret \
  --from-literal=api-key=<YOUR_DATADOG_API_KEY>

# 4. Deploy with Datadog values
helm install otel-demo-cluster open-telemetry/opentelemetry-demo \
  --namespace default \
  -f kubernetes/datadog-values.yaml
```

### Pros
- **Dual observability** - Both Datadog and in-cluster tools (best of both worlds)
- **Standard Helm deployment** - Clean, no patching required
- **Datadog APM features** - Service map, APM stats, distributed tracing
- **Immediate visualization** - Grafana, Jaeger still available locally
- **Simple configuration** - Just add Datadog exporter to values file
- **No AWS-specific setup** - No IRSA, no IAM roles
- **Datadog Connector** - Computes APM stats for service pages and service map

### Cons
- **Datadog costs** - Requires Datadog subscription (~$15-31/host/month)
- **Dual ingestion** - Telemetry sent to both Datadog and in-cluster (higher resource usage)
- **API key management** - Must secure Datadog API key in Kubernetes secret
- **Vendor lock-in** - Tied to Datadog platform
- **More complex than default** - Requires values file and secret creation
- **Resource intensive** - Runs both Datadog export and in-cluster tools

### Best For
- **Teams already using Datadog** for other services
- **Hybrid observability** - Want both Datadog and local tools
- **Datadog APM evaluation** - Testing Datadog with OpenTelemetry
- **Multi-cloud deployments** - Datadog works across AWS, GCP, Azure
- **Avoiding AWS lock-in** - Prefer vendor-neutral observability

### Time to Deploy
- **Cluster creation**: 15-20 minutes
- **Helm setup**: 2-3 minutes
- **Demo deployment**: 5-10 minutes
- **Total**: ~25-35 minutes

### Configuration Highlights
- Uses `otel/opentelemetry-collector-contrib` image (required for Datadog exporter)
- **Datadog Connector**: Computes APM stats from traces (required for service pages)
- **Dual pipelines**: Exports to both Datadog and in-cluster backends
- **Trace pipeline**: `[otlp/jaeger, debug, spanmetrics, datadog, datadog/connector]`
- **Metrics pipeline**: `[otlphttp/prometheus, debug, datadog]` with `datadog/connector` as receiver
- **Logs pipeline**: `[opensearch, debug, datadog]`
- **Key settings**:
  - `span_name_as_resource_name: true` - Maps OTel span names to Datadog resource names
  - `compute_stats_by_span_kind: true` - Generates stats for client/server/producer/consumer spans
  - `peer_tags_aggregation: true` - Aggregates stats for service-to-service dependencies

### Why Datadog Connector is Critical
Without the Datadog connector, services appear as "not yet instrumented" in Datadog. The connector:
- Computes pre-aggregated APM stats from raw spans
- Acts as exporter in traces pipeline (consuming spans)
- Acts as receiver in metrics pipeline (producing stats)
- Enables Datadog service pages, service map, and APM dashboards

---

## 3. otel-contrib-cw (Moderate)

### What It Is
OpenTelemetry Demo using standard contrib collector, sending telemetry exclusively to AWS CloudWatch.

### Onboarding Steps
```bash
# 1. Create EKS cluster with OIDC
./setup-eks-cluster.sh

# 2. Configure IAM permissions (IRSA)
./setup-iam-permissions.sh

# 3. Deploy demo with Helm
./deploy-demo.sh
```

### Pros
- **AWS native** - Uses CloudWatch, X-Ray, CloudWatch Metrics
- **Standard collector** - Uses official `otel/opentelemetry-collector-contrib` image
- **Helm-based** - Clean deployment using official Helm chart
- **No patching** - Straightforward configuration via values file
- **Production-ready** - Reflects real AWS observability setup
- **Reduced cluster resources** - No in-cluster monitoring tools

### Cons
- **AWS costs** - CloudWatch ingestion charges (~$267/month for full demo)
- **IAM complexity** - Requires IRSA setup and IAM role configuration
- **No immediate visualization** - Must use AWS Console
- **Region-specific** - Hardcoded to us-west-2 (requires editing for other regions)
- **More steps** - 3 scripts vs 2 commands

### Best For
- **Learning AWS observability** with OpenTelemetry
- **Production-like setups** using standard OTel collector
- **CloudWatch integration** without Application Signals
- **Cost-conscious AWS deployments** (can disable sampling)

### Time to Deploy
- **Cluster creation**: 15-20 minutes
- **IAM setup**: 2-3 minutes
- **Demo deployment**: 5-10 minutes
- **Total**: ~25-35 minutes

### Configuration Highlights
- Uses `awsemf` exporter for metrics (EMF format)
- Uses `awsxray` exporter for traces
- Uses `awscloudwatchlogs` exporter for logs
- Disables all built-in tools (Grafana, Jaeger, Prometheus, OpenSearch)

---

## 4. otel-custom-collector-cw (Most Complex)

### What It Is
OpenTelemetry Demo using AWS Application Signals collector with advanced AWS-specific features.

### Onboarding Steps
```bash
# 1. Create EKS cluster with OIDC
./setup-eks-cluster.sh

# 2. Configure IAM permissions (IRSA)
./setup-iam-permissions.sh

# 3. Deploy with custom collector
./deploy.sh
```

### Pros
- **AWS Application Signals** - Advanced service discovery, SLO monitoring, AI-powered insights
- **Pre-built dashboards** - Automatic service health dashboards
- **Automatic correlation** - Links metrics, traces, and logs
- **Root cause analysis** - AI-powered anomaly detection
- **JVM metrics transformation** - Optimized for Application Signals
- **Additional receiver** - Port 4316 for Application Signals specific telemetry

### Cons
- **Most complex** - Requires post-deployment patching and image swapping
- **Hybrid approach** - Helm + manual patching due to chart limitations
- **Custom collector image** - Uses AWS-specific collector (not standard contrib)
- **Higher AWS costs** - Application Signals adds additional charges
- **More moving parts** - RBAC setup, ConfigMap patching, image updates, health probe removal
- **Maintenance overhead** - More complex troubleshooting

### Best For
- **Production AWS deployments** requiring advanced observability
- **SLO monitoring** and breach detection
- **Service dependency mapping** with automatic discovery
- **Teams using Application Signals** already
- **Advanced AWS observability** features

### Time to Deploy
- **Cluster creation**: 15-20 minutes
- **IAM setup**: 2-3 minutes
- **Demo deployment**: 10-15 minutes (includes patching)
- **Total**: ~30-40 minutes

### Why So Complex?
The OpenTelemetry Demo Helm chart is designed for the standard contrib collector and automatically adds components like `k8s_observer` and `receiver_creator` that are **not available** in the Application Signals collector image. The deployment script works around this by:

1. Creating RBAC resources (ClusterRole embedded in deploy.sh)
2. Deploying with Helm using standard values
3. Patching the ConfigMap to remove unsupported components
4. Swapping the collector image to Application Signals version
5. Removing health check probes (not supported by Application Signals collector)

### Configuration Highlights
- Uses `public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest` image
- Includes `awsapplicationsignals` processor
- Includes `metricstransform/application_signals` for JVM metrics
- Additional OTLP receiver on port 4316
- Requires ClusterRole for Kubernetes API access
- Exports to `ApplicationSignals` namespace (not `OtelDemo`)

---

## Detailed Comparison

### Deployment Complexity

#### simple-deployment-no-cw
```
1. Create cluster (optional)
2. kubectl apply
3. kubectl port-forward
```
**Complexity**: ⭐ (Simplest)

#### dd-otel-contrib
```
1. Create cluster
2. Add Helm repository
3. Create Datadog API key secret
4. Create datadog-values.yaml
5. Helm install with values file
```
**Complexity**: ⭐⭐ (Easy-Moderate)

#### otel-contrib-cw
```
1. Create cluster with OIDC
2. Create IAM role + policy
3. Create service account with IRSA
4. Helm install with values file
```
**Complexity**: ⭐⭐ (Moderate)

#### otel-custom-collector-cw
```
1. Create cluster with OIDC
2. Create IAM role + policy
3. Create service account with IRSA
4. Create ClusterRole + ClusterRoleBinding
5. Helm install with values file
6. Patch ConfigMap to remove unsupported components
7. Update collector image
8. Remove health probes
9. Wait for rollout
```
**Complexity**: ⭐⭐⭐ (Complex)

### Prerequisites Comparison

| Requirement | simple-deployment-no-cw | dd-otel-contrib | otel-contrib-cw | otel-custom-collector-cw |
|-------------|-------------------------|-----------------|-----------------|--------------------------|
| AWS CLI | ✅ | ✅ | ✅ | ✅ |
| kubectl | ✅ | ✅ | ✅ | ✅ |
| eksctl | ✅ | ✅ | ✅ | ✅ |
| helm | ❌ | ✅ | ✅ | ✅ |
| Datadog account | ❌ | ✅ | ❌ | ❌ |
| Datadog API key | ❌ | ✅ | ❌ | ❌ |
| AWS IAM permissions | Basic | Basic | Advanced | Advanced |
| EKS OIDC provider | ❌ | ❌ | ✅ | ✅ |
| Understanding of IRSA | ❌ | ❌ | ✅ | ✅ |
| Understanding of RBAC | ❌ | ❌ | ❌ | ✅ |

### Cost Comparison (Monthly, 24/7 operation)

| Component | simple-deployment-no-cw | dd-otel-contrib | otel-contrib-cw | otel-custom-collector-cw |
|-----------|-------------------------|-----------------|-----------------|--------------------------|
| **EKS Cluster** | $73 | $73 | $73 | $73 |
| **EC2 Nodes (3x t3.xlarge)** | $150 | $150 | $150 | $150 |
| **CloudWatch Metrics** | $0 | $0 | $30 | $30 |
| **CloudWatch Logs** | $0 | $0 | $21.50 | $21.50 |
| **X-Ray Traces** | $0 | $0 | $216 | $216 |
| **Application Signals** | $0 | $0 | $0 | Additional |
| **Datadog APM** | $0 | $450-930 | $0 | $0 |
| **Total** | **~$223** | **~$673-1,153** | **~$490** | **~$500+** |

**Notes**: 
- simple-deployment-no-cw has no external observability costs but higher in-cluster resource usage
- dd-otel-contrib: Datadog APM pricing is ~$15-31/host/month (3 nodes = $450-930/month)
- dd-otel-contrib also runs in-cluster tools (Grafana, Jaeger, etc.) adding resource overhead

### Observability Features

| Feature | simple-deployment-no-cw | dd-otel-contrib | otel-contrib-cw | otel-custom-collector-cw |
|---------|-------------------------|-----------------|-----------------|--------------------------|
| **Metrics** | Prometheus (in-cluster) | Datadog + Prometheus | CloudWatch Metrics | CloudWatch + Application Signals |
| **Traces** | Jaeger (in-cluster) | Datadog APM + Jaeger | X-Ray | X-Ray + Application Signals |
| **Logs** | In-cluster | Datadog + OpenSearch | CloudWatch Logs | CloudWatch Logs |
| **Dashboards** | Grafana (included) | Datadog + Grafana | Manual in CloudWatch | Auto-generated in Application Signals |
| **Service Map** | Jaeger UI | Datadog Service Map + Jaeger | X-Ray Service Map | Application Signals Service Map |
| **APM Stats** | ❌ | ✅ Datadog Connector | ❌ | ✅ Application Signals |
| **SLO Monitoring** | ❌ | ✅ Datadog SLOs | Manual | ✅ Automatic |
| **Anomaly Detection** | ❌ | ✅ Datadog Watchdog | ❌ | ✅ AI-powered |
| **Root Cause Analysis** | Manual | ✅ Datadog APM | Manual | ✅ Automatic |
| **Multi-cloud Support** | ❌ | ✅ | ❌ | ❌ |

### Troubleshooting Difficulty

#### simple-deployment-no-cw
- **Easy**: All logs in-cluster via `kubectl logs`
- **Easy**: Grafana UI for immediate visualization
- **Easy**: Jaeger UI for trace inspection
- **Difficulty**: ⭐ (Easiest)

#### dd-otel-contrib
- **Easy**: Collector logs via `kubectl logs`
- **Easy**: Datadog UI for APM visualization
- **Easy**: Local Grafana/Jaeger still available
- **Moderate**: Datadog connector configuration issues
- **Moderate**: API key authentication issues
- **Common issue**: Services show "not yet instrumented" if connector misconfigured
- **Difficulty**: ⭐⭐ (Easy-Moderate)

#### otel-contrib-cw
- **Moderate**: Check collector logs + AWS Console
- **Moderate**: IAM permission issues possible
- **Moderate**: Multiple AWS services to check
- **Difficulty**: ⭐⭐ (Moderate)

#### otel-custom-collector-cw
- **Complex**: Collector logs + AWS Console + Application Signals
- **Complex**: IAM + RBAC permission issues
- **Complex**: ConfigMap patching issues
- **Complex**: Image compatibility issues
- **Complex**: Health probe issues
- **Difficulty**: ⭐⭐⭐ (Most Complex)

### When to Use Each

#### Use simple-deployment-no-cw when:
- Learning OpenTelemetry basics
- Quick demos or POCs
- No external observability platform needed
- Want to avoid external costs
- Need immediate visualization
- Don't care about production patterns

#### Use dd-otel-contrib when:
- Already using Datadog for other services
- Want unified observability across multi-cloud
- Need Datadog APM features (service map, APM stats, Watchdog)
- Want both Datadog and local tools (hybrid approach)
- Prefer vendor-neutral OpenTelemetry instrumentation
- Avoiding AWS-specific lock-in
- Need advanced APM features without AWS complexity

#### Use otel-contrib-cw when:
- Need AWS CloudWatch integration
- Want production-like setup
- Using standard OTel collector
- Don't need Application Signals features
- Want simpler deployment than custom collector
- Cost-conscious (can optimize sampling)

#### Use otel-custom-collector-cw when:
- Need AWS Application Signals features
- Want automatic service discovery
- Need SLO monitoring and breach detection
- Want AI-powered root cause analysis
- Already using Application Signals
- Willing to handle deployment complexity

---

## Migration Path

### From simple-deployment-no-cw → dd-otel-contrib
**Effort**: Low
- Add Helm repository
- Create Datadog API key secret
- Create datadog-values.yaml with Datadog exporter
- Redeploy with Helm (keeps in-cluster tools)

### From simple-deployment-no-cw → otel-contrib-cw
**Effort**: Moderate
- Add IAM setup script
- Switch from kubectl to Helm
- Update values file for AWS exporters
- Remove built-in tools

### From dd-otel-contrib → otel-contrib-cw
**Effort**: Moderate
- Add IAM/IRSA setup
- Replace Datadog exporter with AWS exporters
- Remove Datadog connector
- Remove in-cluster tools
- Update pipeline configuration

### From otel-contrib-cw → otel-custom-collector-cw
**Effort**: High
- Add RBAC setup
- Add ConfigMap patching
- Switch collector image
- Update receiver ports
- Add Application Signals processor
- Remove health probes

### From simple-deployment-no-cw → otel-custom-collector-cw
**Effort**: Very High
- Combine all changes from both migrations
- Significant architectural changes

---

## Recommendation

### For Learning
**Start with**: `simple-deployment-no-cw`
- Simplest to understand
- No external dependencies
- Immediate feedback

### For Datadog Users
**Use**: `dd-otel-contrib`
- Unified observability with existing Datadog services
- Best if already paying for Datadog
- Hybrid approach keeps local tools available
- Multi-cloud flexibility

### For AWS Production
**Start with**: `otel-contrib-cw`
- Production-ready AWS integration
- Standard collector (easier to maintain)
- Lower complexity than custom collector
- Best cost/feature balance for AWS-only deployments

### For Advanced AWS Features
**Use**: `otel-custom-collector-cw`
- Only if you need Application Signals features
- Be prepared for deployment complexity
- Have strong AWS + Kubernetes knowledge

---

## Summary

| Criteria | Winner |
|----------|--------|
| **Easiest to deploy** | simple-deployment-no-cw |
| **Fastest to deploy** | simple-deployment-no-cw |
| **Lowest cost** | simple-deployment-no-cw |
| **Best for learning** | simple-deployment-no-cw |
| **Best for Datadog users** | dd-otel-contrib |
| **Best for multi-cloud** | dd-otel-contrib |
| **Best for AWS production** | otel-contrib-cw |
| **Most AWS features** | otel-custom-collector-cw |
| **Best for SLO monitoring** | dd-otel-contrib or otel-custom-collector-cw |
| **Best APM features** | dd-otel-contrib |
| **Easiest to troubleshoot** | simple-deployment-no-cw |
| **Most maintainable** | otel-contrib-cw |
| **Best hybrid approach** | dd-otel-contrib |

## Decision Tree

```
Are you learning OpenTelemetry?
├─ YES → simple-deployment-no-cw
└─ NO → Do you already use Datadog?
    ├─ YES → dd-otel-contrib
    └─ NO → Is this AWS-only?
        ├─ YES → Do you need Application Signals features?
        │   ├─ YES → otel-custom-collector-cw
        │   └─ NO → otel-contrib-cw
        └─ NO → Consider dd-otel-contrib for multi-cloud
```

**Overall Recommendation**: 
- **Learning**: Start with `simple-deployment-no-cw`
- **Datadog users**: Use `dd-otel-contrib` for unified observability
- **AWS production**: Use `otel-contrib-cw` for best cost/feature balance
- **Advanced AWS**: Use `otel-custom-collector-cw` only if you need Application Signals
