# OpenTelemetry Demo on AWS EKS with CloudWatch

This directory contains configuration and scripts to deploy the OpenTelemetry Demo application to AWS EKS and send telemetry data to AWS CloudWatch in the `us-west-2` region.

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- `kubectl` installed
- `helm` installed (v3+)
- `eksctl` installed
- Sufficient AWS permissions to create EKS clusters, IAM roles, and CloudWatch resources

### Option 1: Automated Deployment (Recommended)

Run the scripts in order:

```bash
cd aws

# 1. Create EKS cluster (15-20 minutes)
./setup-eks-cluster.sh

# 2. Setup IAM permissions for IRSA
./setup-iam-permissions.sh

# 3. Deploy the demo application
./deploy-demo.sh
```

### Option 2: Using Helmfile

If you have Helmfile installed:

```bash
cd aws

# Setup IAM first
./setup-iam-permissions.sh

# Deploy with Helmfile
helmfile apply -f helmfile.yaml
```

### Option 3: Manual Helm Deployment

```bash
cd aws

# Add Helm repo
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Update values file with your AWS Account ID
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed "s/\${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID}/g" opentelemetry-demo-values.yaml > opentelemetry-demo-values-final.yaml

# Install
helm install opentelemetry-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --create-namespace \
  --values opentelemetry-demo-values-final.yaml \
  --version 0.40.2
```

## Configuration

### Region

The default region is `us-west-2`. To change it:

1. Edit `opentelemetry-demo-values.yaml`
2. Update all occurrences of `us-west-2` to your desired region
3. Update the `AWS_REGION` environment variable when running scripts

### IAM Permissions

The deployment uses IRSA (IAM Roles for Service Accounts) to grant the OpenTelemetry Collector permissions to:
- Write logs to CloudWatch Logs
- Send traces to AWS X-Ray
- Publish metrics to CloudWatch

### Telemetry Destinations

The demo sends telemetry to **both** AWS CloudWatch and built-in monitoring tools:

**AWS CloudWatch:**
- **Logs**: CloudWatch Logs group `/aws/otel-demo/application`
- **Traces**: AWS X-Ray
- **Metrics**: CloudWatch Metrics namespace `OtelDemo` (using EMF format)

**Built-in Monitoring Tools:**
- **Logs**: OpenSearch (accessible via Grafana)
- **Traces**: Jaeger UI
- **Metrics**: Prometheus (visualized in Grafana)

This dual-destination setup allows you to:
- Use Grafana/Jaeger for quick local debugging and visualization
- Use AWS CloudWatch for production monitoring, alerting, and long-term retention

## Accessing the Application

### Frontend Application

After deployment, get the frontend URL:

```bash
kubectl get svc -n otel-demo opentelemetry-demo-frontend-proxy
```

Or port-forward locally:

```bash
kubectl port-forward -n otel-demo svc/opentelemetry-demo-frontend-proxy 8080:8080
```

Then visit: http://localhost:8080

### Built-in Monitoring Tools

Access the built-in observability tools:

**Grafana** (dashboards and metrics):
```bash
kubectl port-forward -n otel-demo svc/opentelemetry-demo-grafana 3000:80
```
Visit: http://localhost:3000 (default credentials: admin/admin)

**Jaeger** (distributed tracing):
```bash
kubectl port-forward -n otel-demo svc/opentelemetry-demo-jaeger-query 16686:16686
```
Visit: http://localhost:16686

**OpenSearch Dashboards** (logs):
```bash
kubectl port-forward -n otel-demo svc/opentelemetry-demo-opensearch-dashboards 5601:5601
```
Visit: http://localhost:5601

## Viewing Telemetry

### Option 1: Built-in Tools (Quick Local Access)

**Grafana Dashboards:**
- Port-forward: `kubectl port-forward -n otel-demo svc/opentelemetry-demo-grafana 3000:80`
- Visit: http://localhost:3000
- Pre-configured dashboards for all services

**Jaeger Traces:**
- Port-forward: `kubectl port-forward -n otel-demo svc/opentelemetry-demo-jaeger-query 16686:16686`
- Visit: http://localhost:16686
- Search and analyze distributed traces

**OpenSearch Logs:**
- Port-forward: `kubectl port-forward -n otel-demo svc/opentelemetry-demo-opensearch-dashboards 5601:5601`
- Visit: http://localhost:5601
- Query and analyze application logs

### Option 2: AWS CloudWatch (Production Monitoring)

**CloudWatch Logs:**
```bash
aws logs tail /aws/otel-demo/application --follow --region us-west-2
```
Console: https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#logsV2:log-groups

**X-Ray Traces:**
Console: https://us-west-2.console.aws.amazon.com/xray/home?region=us-west-2#/service-map

**CloudWatch Metrics:**
Console: https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#metricsV2:
- Look for the `OtelDemo` namespace

## Troubleshooting

### Check Collector Logs
```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=opentelemetry-collector -f
```

### Verify IAM Role
```bash
kubectl get sa -n otel-demo opentelemetry-demo-otelcol -o yaml
```

### Check Pod Status
```bash
kubectl get pods -n otel-demo
kubectl describe pod -n otel-demo <pod-name>
```

### Common Issues

1. **Authentication errors**: Verify IRSA configuration and IAM role trust policy
2. **No data in CloudWatch**: Check collector logs for export errors
3. **Pods not starting**: Check node capacity and resource requests

## Cleanup

To remove all resources:

```bash
./cleanup.sh
```

This will:
- Delete the Helm release
- Delete the namespace
- Remove IAM roles and policies
- Optionally delete the EKS cluster

## Architecture

The deployment follows the same pattern as the GCP implementation but uses AWS-specific exporters:

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenTelemetry Demo                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Frontend │  │ Checkout │  │ Payment  │  │   Cart   │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │             │              │             │          │
│       └─────────────┴──────────────┴─────────────┘          │
│                          │                                   │
│                          ▼                                   │
│              ┌───────────────────────┐                      │
│              │ OpenTelemetry         │                      │
│              │ Collector             │                      │
│              │ (with AWS exporters)  │                      │
│              └───────────┬───────────┘                      │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │      AWS CloudWatch    │
              ├────────────────────────┤
              │ • CloudWatch Logs      │
              │ • AWS X-Ray (Traces)   │
              │ • CloudWatch Metrics   │
              └────────────────────────┘
```

## Files

- `helmfile.yaml` - Helmfile configuration for deployment
- `opentelemetry-demo-values.yaml` - Helm values with AWS CloudWatch configuration
- `setup-eks-cluster.sh` - Creates EKS cluster with OIDC provider
- `setup-iam-permissions.sh` - Configures IAM roles and policies for IRSA
- `deploy-demo.sh` - Deploys the demo application
- `cleanup.sh` - Removes all created resources
- `README.md` - This file

## Differences from GCP Implementation

| Aspect | GCP | AWS |
|--------|-----|-----|
| Traces | Google Cloud Trace | AWS X-Ray |
| Logs | Cloud Logging | CloudWatch Logs |
| Metrics | Google Managed Prometheus | CloudWatch Metrics (EMF) |
| Authentication | Workload Identity | IRSA (IAM Roles for Service Accounts) |
| Exporter | `googlecloud` | `otlphttp` + `awsemf` |
| Resource Detection | `gcp` detector | `eks`, `ec2` detectors |

## References

- [AWS CloudWatch OTLP Setup](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPSimplesetup.html)
- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [EKS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Application Signals Demo](https://github.com/aws-observability/application-signals-demo)
- [GCP Implementation](../gcp/README.md)
