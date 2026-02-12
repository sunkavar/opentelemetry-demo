# OpenTelemetry Demo on AWS EKS with CloudWatch

Deploy the OpenTelemetry Demo to AWS EKS and send telemetry data exclusively to AWS CloudWatch (no built-in monitoring tools).

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl installed
- helm installed (v3+)
- eksctl installed
- Sufficient AWS permissions to create EKS clusters, IAM roles, and CloudWatch resources

### Deployment Steps

Run the scripts in order:

```bash
# 1. Create EKS cluster (15-20 minutes)
./setup-eks-cluster.sh

# 2. Setup IAM permissions for IRSA
./setup-iam-permissions.sh

# 3. Deploy the demo application
./deploy-demo.sh
```

## Configuration

### Region

Default region is `us-west-2`. To change:

1. Edit `opentelemetry-demo-values.yaml`
2. Update all `us-west-2` references to your region
3. Set `AWS_REGION` environment variable when running scripts

### IAM Permissions

Uses IRSA (IAM Roles for Service Accounts) to grant the OpenTelemetry Collector permissions to:
- Write logs to CloudWatch Logs
- Send traces to AWS X-Ray
- Publish metrics to CloudWatch Metrics

### Telemetry Destinations

All telemetry is sent exclusively to AWS CloudWatch:

- **Logs**: CloudWatch Logs group `/aws/otel-demo/application`
- **Traces**: AWS X-Ray
- **Metrics**: CloudWatch Metrics namespace `OtelDemo` (EMF format)

Built-in monitoring tools (Prometheus, Grafana, Jaeger, OpenSearch) are disabled to reduce resource usage.

## Accessing the Application

### Frontend Application

Get the LoadBalancer URL:

```bash
kubectl get svc -n otel-demo frontend-proxy
```

Or port-forward locally:

```bash
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```

Then visit: <http://localhost:8080>

## Viewing Telemetry in AWS CloudWatch

### CloudWatch Logs

```bash
# Tail logs in real-time
aws logs tail /aws/otel-demo/application --follow --region us-west-2
```

Console: <https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#logsV2:log-groups>

### X-Ray Traces

Console: <https://us-west-2.console.aws.amazon.com/xray/home?region=us-west-2#/service-map>

### CloudWatch Metrics

Console: <https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#metricsV2:>

Look for the `OtelDemo` namespace.

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

Remove all resources:

```bash
./cleanup.sh
```

This will:
- Delete the Helm release
- Delete the namespace
- Remove IAM roles and policies
- Optionally delete the EKS cluster

## Architecture

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
│              │ (AWS exporters only)  │                      │
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

- `opentelemetry-demo-values.yaml` - Helm values with AWS CloudWatch configuration
- `setup-eks-cluster.sh` - Creates EKS cluster with OIDC provider
- `setup-iam-permissions.sh` - Configures IAM roles and policies for IRSA
- `deploy-demo.sh` - Deploys the demo application
- `cleanup.sh` - Removes all created resources
- `README.md` - This file

## References

- [AWS CloudWatch OTLP Setup](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-OTLPSimplesetup.html)
- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [EKS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
