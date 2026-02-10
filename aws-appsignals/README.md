# OpenTelemetry Demo with AWS Application Signals

Deploy OpenTelemetry Demo to AWS EKS with **AWS Application Signals** collector. This configuration sends telemetry **ONLY to AWS CloudWatch** (no built-in monitoring tools).

## What is AWS Application Signals?

AWS Application Signals provides:
- **Automatic service discovery** and dependency mapping
- **Pre-built dashboards** for service health
- **SLO monitoring** with automatic breach detection
- **Correlation** between metrics, traces, and logs
- **Root cause analysis** with AI-powered insights

## How This Deployment Works

This deployment uses a **hybrid approach** to work around Helm chart limitations:

1. **Helm deploys** the OpenTelemetry Demo with all services
2. **Automatic patching** removes unsupported components from the collector ConfigMap
3. **Image update** switches to AWS Application Signals collector
4. **RBAC setup** adds necessary Kubernetes permissions
5. **Health probe removal** since Application Signals collector doesn't support health_check extension

All of this is automated in the `deploy.sh` script for a single-command deployment.

### Why This Approach?

The OpenTelemetry Demo Helm chart is designed for the full contrib collector and automatically adds components like `k8s_observer` and `receiver_creator` that are **not available** in the Application Signals collector image. Our deployment script automatically removes these after Helm deployment.

## Quick Start

### Prerequisites

- AWS CLI configured with credentials
- kubectl installed
- helm installed
- eksctl installed

### Deploy

```bash
# 1. Create EKS cluster
./setup-eks-cluster.sh

# 2. Configure IAM permissions
./setup-iam-permissions.sh

# 3. Deploy the demo
./deploy.sh
```

That's it! The demo will be deployed with AWS Application Signals collector.

## What Gets Deployed

### Application Services
- 20+ microservices from OpenTelemetry Demo
- Frontend web UI (via LoadBalancer)
- Load generator

### Collector Configuration
- **Image**: `public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest`
- **Receivers**: 
  - OTLP (4317/4318) - Standard application telemetry
  - OTLP/Application Signals (4316) - Application Signals specific
- **Processors**:
  - `awsapplicationsignals` - Application Signals processing
  - `metricstransform/application_signals` - JVM metrics transformation
  - `resourcedetection` - AWS resource detection (EKS, EC2)
- **Exporters**:
  - X-Ray (traces)
  - CloudWatch Logs (application logs)
  - CloudWatch EMF (Application Signals metrics)

### What's NOT Deployed
- ❌ Grafana
- ❌ Jaeger
- ❌ Prometheus
- ❌ OpenSearch

All telemetry goes **ONLY to AWS CloudWatch**.

## Configuration

### Region
Default: `us-west-2`

To change region, set environment variable:
```bash
export AWS_REGION=us-east-1
./deploy.sh
```

### Cluster Name
Default: `otel-demo-cluster`

To change, edit `setup-eks-cluster.sh`:
```bash
CLUSTER_NAME=my-cluster-name
```

### Namespace
Default: `otel-demo`

To change, edit `deploy.sh`:
```bash
NAMESPACE=my-namespace
```

## Accessing the Application

### Get Frontend URL

```bash
kubectl get svc -n otel-demo frontend-proxy
```

### Access Points

Via LoadBalancer:
- **Web Store**: http://\<LOADBALANCER\>:8080/
- **Load Generator**: http://\<LOADBALANCER\>:8080/loadgen/
- **Feature Flags**: http://\<LOADBALANCER\>:8080/feature/

Via Port-Forward:
```bash
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```
- **Web Store**: http://localhost:8080/
- **Load Generator**: http://localhost:8080/loadgen/
- **Feature Flags**: http://localhost:8080/feature/

## Viewing Telemetry

### AWS Application Signals Console

Main Dashboard:
```
https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#application-signals:
```

Features:
- Service map with dependencies
- Service health metrics (latency, errors, availability)
- SLO monitoring
- Automatic anomaly detection

### CloudWatch Logs

Application Logs:
```bash
aws logs tail /aws/otel-demo/application --follow --region us-west-2
```

Application Signals Data:
```bash
aws logs tail /aws/application-signals/data --follow --region us-west-2
```

Custom Metrics:
```bash
aws logs tail /aws/application-signals/custom --follow --region us-west-2
```

### AWS X-Ray

Service Map:
```
https://us-west-2.console.aws.amazon.com/xray/home?region=us-west-2#/service-map
```

Traces:
```bash
aws xray get-trace-summaries \
  --region us-west-2 \
  --start-time $(date -u -d '1 hour ago' +%s) \
  --end-time $(date -u +%s)
```

### CloudWatch Metrics

Namespaces:
- `ApplicationSignals` - Service metrics with Application Signals processing
- `ApplicationSignalsCustom` - Custom application metrics

View in Console:
```
https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#metricsV2:
```

## Troubleshooting

### Check Pods

```bash
kubectl get pods -n otel-demo
```

All pods should be in `Running` state.

### Check Collector Logs

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=opentelemetry-collector -f
```

Look for:
- ✅ "Everything is ready. Begin running and processing data."
- ✅ No errors about authentication or permissions
- ✅ Successful exports to X-Ray and CloudWatch

### Verify Collector Image

```bash
kubectl get deployment -n otel-demo -o jsonpath='{.items[*].spec.template.spec.containers[?(@.name=="otc-container")].image}'
```

Should show: `public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest`

### Check IAM Permissions

```bash
kubectl get sa opentelemetry-demo-otelcol -n otel-demo -o yaml
```

Should have annotation: `eks.amazonaws.com/role-arn: arn:aws:iam::...`

### No Data in Application Signals

1. Check collector is running
2. Check IAM permissions are configured
3. Check collector logs for errors
4. Verify region is correct (us-west-2)
5. Wait 5-10 minutes for telemetry to appear

## Files

- `opentelemetry-demo-values.yaml` - Helm values with Application Signals configuration
- `setup-eks-cluster.sh` - Create EKS cluster
- `setup-iam-permissions.sh` - Configure IAM roles for IRSA
- `deploy.sh` - Deploy the demo
- `cleanup.sh` - Clean up all resources

## Files

- `opentelemetry-demo-values.yaml` - Helm values with Application Signals configuration
- `configmap-patch.yaml` - Patch to remove unsupported components from Helm-generated ConfigMap
- `clusterrole.yaml` - RBAC permissions for Application Signals processor
- `setup-eks-cluster.sh` - Create EKS cluster
- `setup-iam-permissions.sh` - Configure IAM roles for IRSA
- `deploy.sh` - **Main deployment script** (automated Helm + patching)
- `cleanup.sh` - Clean up all resources

## Key Differences from Standard Deployment

| Feature | Standard | Application Signals |
|---------|----------|-------------------|
| **Collector Image** | `otel/opentelemetry-collector-contrib` | `public.ecr.aws/d8u3t5w4/appsignals-otel-collector:latest` |
| **Built-in Tools** | ✅ Grafana, Jaeger, Prometheus, OpenSearch | ❌ Disabled |
| **Telemetry Destination** | AWS + Built-in tools | AWS only |
| **Metrics Namespace** | `OtelDemo` | `ApplicationSignals` |
| **Special Processors** | Standard | `awsapplicationsignals` |
| **JVM Metrics** | Standard names | Transformed for Application Signals |
| **Receiver Ports** | 4317, 4318 | 4317, 4318, 4316 |

## Cost Estimate

For the demo with 20+ services running 24/7:

- **Metrics**: ~100 metrics × $0.30 = $30/month
- **Traces**: ~43M traces × $5.00 = $216/month
- **Logs**: ~43 GB × $0.50 = $21.50/month
- **Total**: ~$267.50/month

### Cost Optimization

1. **Enable sampling**:
   - Configure trace sampling in the collector
   - Use Application Signals sampling rules

2. **Filter metrics**:
   - Only send necessary metrics
   - Use metric filters to reduce cardinality

3. **Set log retention**:
   ```bash
   aws logs put-retention-policy \
     --log-group-name /aws/application-signals/data \
     --retention-in-days 7 \
     --region us-west-2
   ```

4. **Stop when not in use**:
   ```bash
   kubectl scale deployment --all --replicas=0 -n otel-demo
   ```

## Cleanup

Remove all resources:

```bash
./cleanup.sh
```

This will:
- Delete the Helm release
- Delete the namespace
- Remove IAM service account
- Delete the EKS cluster

## References

- [AWS Application Signals Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals.html)
- [Application Signals Collector](https://gallery.ecr.aws/d8u3t5w4/appsignals-otel-collector)
- [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/)

---

**Region**: us-west-2  
**Namespace**: otel-demo  
**Collector**: AWS Application Signals  
**Telemetry**: CloudWatch only
