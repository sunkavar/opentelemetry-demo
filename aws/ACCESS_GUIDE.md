# Access Guide - OpenTelemetry Demo on AWS EKS

## Quick Access via LoadBalancer

Your LoadBalancer URL: `a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com`

All monitoring tools are accessible through the **frontend-proxy** service!

### Via LoadBalancer (Public Access)

| Tool | URL |
|------|-----|
| **Web Store** | http://a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com:8080/ |
| **Grafana** | http://a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com:8080/grafana/ |
| **Jaeger** | http://a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com:8080/jaeger/ui/ |
| **Load Generator** | http://a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com:8080/loadgen/ |
| **Feature Flags** | http://a3949afdde35e47efa4ebe5b0b952149-63959022.us-west-2.elb.amazonaws.com:8080/feature/ |

### Via Port-Forward (Local Access)

```bash
# Port-forward the frontend-proxy
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```

Then access:

| Tool | URL |
|------|-----|
| **Web Store** | http://localhost:8080/ |
| **Grafana** | http://localhost:8080/grafana/ |
| **Jaeger** | http://localhost:8080/jaeger/ui/ |
| **Load Generator** | http://localhost:8080/loadgen/ |
| **Feature Flags** | http://localhost:8080/feature/ |

## Direct Service Access (Alternative)

If you prefer to access services directly:

### Grafana
```bash
kubectl port-forward -n otel-demo svc/grafana 3000:80
```
Visit: http://localhost:3000  
Credentials: `admin` / `admin`

### Jaeger
```bash
kubectl port-forward -n otel-demo svc/jaeger 16686:16686
```
Visit: http://localhost:16686

### Prometheus
```bash
kubectl port-forward -n otel-demo svc/prometheus 9090:9090
```
Visit: http://localhost:9090

### OpenSearch (API only)
```bash
kubectl port-forward -n otel-demo svc/opensearch 9200:9200
```
Query: `curl http://localhost:9200/_cat/indices`

## AWS CloudWatch Access

### CloudWatch Logs

**Via CLI:**
```bash
# Tail logs in real-time
aws logs tail /aws/otel-demo/application --follow --region us-west-2

# View last hour
aws logs tail /aws/otel-demo/application --since 1h --region us-west-2

# Filter for errors
aws logs tail /aws/otel-demo/application --follow --filter-pattern "ERROR" --region us-west-2
```

**Via Console:**
```
https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2#logsV2:log-groups/log-group/$252Faws$252Fotel-demo$252Fapplication
```

### AWS X-Ray (Traces)

**Via Console:**
```
https://us-west-2.console.aws.amazon.com/xray/home?region=us-west-2#/service-map
```

**Via CLI:**
```bash
# Get service graph
aws xray get-service-graph --region us-west-2 --start-time $(date -u -d '1 hour ago' +%s) --end-time $(date -u +%s)

# Get trace summaries
aws xray get-trace-summaries --region us-west-2 --start-time $(date -u -d '1 hour ago' +%s) --end-time $(date -u +%s)
```

## What Each Tool Shows

### Web Store
- **Purpose**: Demo e-commerce application
- **Features**: Browse products, add to cart, checkout
- **Use**: Generate traffic to create telemetry data

### Grafana
- **Purpose**: Metrics visualization and dashboards
- **Features**: Pre-built dashboards for all services
- **Credentials**: admin/admin
- **Data Source**: Prometheus

### Jaeger
- **Purpose**: Distributed tracing UI
- **Features**: 
  - Search traces by service, operation, tags
  - View trace timeline and spans
  - Service dependency graph
  - Compare traces
- **Data**: Traces from all microservices

### Load Generator
- **Purpose**: Generate synthetic traffic
- **Features**:
  - Configure request rate
  - Set number of users
  - Control traffic patterns
- **Use**: Create consistent load for testing

### Feature Flags
- **Purpose**: Toggle feature flags dynamically
- **Features**: Enable/disable features without redeployment
- **Service**: Powered by flagd

### Prometheus
- **Purpose**: Metrics storage and querying
- **Features**:
  - PromQL query interface
  - Metrics explorer
  - Target health status
- **Data**: Application metrics from all services

### OpenSearch
- **Purpose**: Log storage and search
- **Access**: API only (no UI)
- **Data**: Application logs from all services
- **Note**: Logs are also in CloudWatch Logs

## Useful Commands

### Check Deployment Status
```bash
# View all pods
kubectl get pods -n otel-demo

# View all services
kubectl get svc -n otel-demo

# Check collector logs
kubectl logs -n otel-demo -l app.kubernetes.io/component=opentelemetry-collector -f
```

### Get LoadBalancer URL
```bash
kubectl get svc -n otel-demo frontend-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Generate Traffic
```bash
# Using curl
for i in {1..100}; do
  curl -s http://localhost:8080 > /dev/null
  echo "Request $i completed"
  sleep 1
done

# Or use the Load Generator UI
# Visit: http://localhost:8080/loadgen/
```

### View Logs from Specific Service
```bash
# Frontend logs
kubectl logs -n otel-demo -l app.kubernetes.io/name=frontend -f

# Checkout service logs
kubectl logs -n otel-demo -l app.kubernetes.io/name=checkout -f

# Payment service logs
kubectl logs -n otel-demo -l app.kubernetes.io/name=payment -f
```

## Troubleshooting

### LoadBalancer Not Accessible
```bash
# Check LoadBalancer status
kubectl describe svc -n otel-demo frontend-proxy

# Check if pods are ready
kubectl get pods -n otel-demo

# Use port-forward as alternative
kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080
```

### No Data in Grafana
1. Wait a few minutes for metrics to be scraped
2. Check Prometheus targets: http://localhost:9090/targets
3. Verify collector is running: `kubectl get pods -n otel-demo | grep otel-collector`

### No Traces in Jaeger
1. Generate some traffic to the web store
2. Check collector logs for errors
3. Verify Jaeger is receiving data: `kubectl logs -n otel-demo -l app.kubernetes.io/name=jaeger`

### No Logs in CloudWatch
```bash
# Check collector logs
kubectl logs -n otel-demo -l app.kubernetes.io/component=opentelemetry-collector | grep -i "log\|error"

# Verify IAM permissions
kubectl get sa opentelemetry-demo-otelcol -n otel-demo -o yaml

# Check if log group exists
aws logs describe-log-groups --log-group-name-prefix /aws/otel-demo --region us-west-2
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Frontend Proxy                        │
│              (LoadBalancer Service)                      │
│                                                          │
│  Routes:                                                 │
│  /              → Web Store                              │
│  /grafana/      → Grafana                                │
│  /jaeger/ui/    → Jaeger                                 │
│  /loadgen/      → Load Generator                         │
│  /feature/      → Feature Flags                          │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│              Application Services                        │
│  (Frontend, Checkout, Payment, Cart, etc.)              │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼ OTLP
┌─────────────────────────────────────────────────────────┐
│           OpenTelemetry Collector                        │
└─────────────────────────────────────────────────────────┘
                          │
                ┌─────────┴─────────┐
                ▼                   ▼
    ┌───────────────────┐   ┌──────────────────┐
    │  Built-in Tools   │   │  AWS CloudWatch  │
    │  • Grafana        │   │  • Logs          │
    │  • Jaeger         │   │  • X-Ray         │
    │  • Prometheus     │   │                  │
    │  • OpenSearch     │   │                  │
    └───────────────────┘   └──────────────────┘
```

## Next Steps

1. **Explore the Web Store**: Make some purchases to generate traces
2. **View Traces in Jaeger**: See how requests flow through services
3. **Check Grafana Dashboards**: View service metrics and RED metrics
4. **Query Logs in CloudWatch**: Search for errors or specific events
5. **View X-Ray Service Map**: Understand service dependencies
6. **Use Load Generator**: Create consistent traffic patterns
7. **Toggle Feature Flags**: See how features can be controlled dynamically

## Security Note

⚠️ **Warning**: The LoadBalancer is publicly accessible. For production:
- Use internal LoadBalancer
- Add authentication/authorization
- Use AWS WAF
- Restrict security groups
- Enable TLS/SSL

To make LoadBalancer internal, add this annotation in values.yaml:
```yaml
components:
  frontend-proxy:
    service:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-internal: "true"
```

---

**Region**: us-west-2  
**Namespace**: otel-demo  
**Deployment**: OpenTelemetry Demo v2.2.0
