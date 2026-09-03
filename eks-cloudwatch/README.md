# OpenTelemetry Demo on EKS, exporting to CloudWatch

Deploys the upstream OpenTelemetry Astronomy Shop demo to EKS and sends traces,
metrics, and logs to the CloudWatch OTLP endpoints, alongside the demo's own
Jaeger / Prometheus / Grafana / OpenSearch stack.

Everything is upstream open source: the `open-telemetry/opentelemetry-demo` Helm
chart, the `otel/opentelemetry-collector-contrib` image, and the demo's own SDKs.
No ADOT distro, no CloudWatch agent, no custom collector build. The two pieces
CloudWatch needs, `sigv4authextension` and the `otlphttp` exporter, already ship
in collector-contrib.

Auth is **EKS Pod Identity**.

---

## Contents

- [Prerequisites](#prerequisites)
- [Step 1. Create the cluster](#step-1-create-the-cluster)
- [Step 2. IAM role for the collector](#step-2-iam-role-for-the-collector)
- [Step 3. Enable Transaction Search](#step-3-enable-transaction-search)
- [Step 4. Create the log group](#step-4-create-the-log-group)
- [Step 5. Install the demo](#step-5-install-the-demo)
- [Step 6. Verify telemetry reaches CloudWatch](#step-6-verify-telemetry-reaches-cloudwatch)
- [Accessing the app](#accessing-the-app)
- [Simulating failures](#simulating-failures)
- [AWS resource detection](#aws-resource-detection)
- [Where to look in CloudWatch](#where-to-look-in-cloudwatch)
- [Gotchas](#gotchas)
- [Troubleshooting](#troubleshooting)
- [Cost and teardown](#cost-and-teardown)
- [Files](#files)

---

## Prerequisites

`aws`, `kubectl`, `helm` 3.14+, `eksctl`, `python3`.

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=otel-demo-cluster
export NAMESPACE=otel-demo
```

Use a **dedicated cluster**. The chart renders 31 pods with memory limits
totalling ~10.7 GB, and the load generator drives traffic continuously. On a
shared cluster that competes with whatever else is running.

---

## Step 1. Create the cluster

```bash
eksctl create cluster -f cluster.yaml     # ~15 minutes
```

`cluster.yaml` gives you 2 × `m5.xlarge` (8 vCPU, 32 GB) in us-east-1 on k8s 1.33,
with the `eks-pod-identity-agent` addon and **no OIDC provider**, since Pod
Identity doesn't need one. Non-burstable on purpose: `t3` under the demo's
constant synthetic load either throttles or accrues surplus-credit charges.

eksctl switches your kube context automatically. Confirm:

```bash
kubectl config current-context      # ...@otel-demo-cluster.us-east-1.eksctl.io
kubectl get nodes
```

---

## Step 2. IAM role for the collector

Pod Identity binds an IAM role to a *(namespace, service account)* pair. The
ServiceAccount is still required; Helm creates it as `otel-collector`.

```bash
aws iam create-policy \
  --policy-name OtelDemoCloudWatchOtlpAccess \
  --policy-document file://iam-policy.json

aws iam create-role \
  --role-name otel-demo-cloudwatch-collector \
  --assume-role-policy-document file://trust-policy-pod-identity.json

aws iam attach-role-policy \
  --role-name otel-demo-cloudwatch-collector \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoCloudWatchOtlpAccess"

kubectl create namespace "$NAMESPACE"

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" \
  --service-account otel-collector \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/otel-demo-cloudwatch-collector" \
  --region "$AWS_REGION"
```

The trust policy needs **`sts:TagSession` as well as `sts:AssumeRole`**. Missing
it produces a confusing 403.

Create the association **before** installing the chart. Credential env vars are
injected at pod admission, so an association added later does nothing until you
`kubectl rollout restart ds/otel-collector-agent -n "$NAMESPACE"`.

The role is reusable across clusters. `pods.eks.amazonaws.com` has no per-cluster
binding, so only the association needs recreating on a new cluster.

---

## Step 3. Enable Transaction Search

The X-Ray OTLP endpoint rejects spans unless Transaction Search is on. Without it:
`The OTLP API is supported with CloudWatch Logs as a Trace Segment Destination.`

This is an **account-wide, region-wide** setting that changes how all X-Ray span
ingestion is billed. Check first, it may already be on:

```bash
aws xray get-trace-segment-destination --region "$AWS_REGION"
# want: Destination=CloudWatchLogs, Status=ACTIVE
```

If not:

```bash
aws logs put-resource-policy \
  --region "$AWS_REGION" \
  --policy-name TransactionSearchAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"TransactionSearchXRayAccess\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"xray.amazonaws.com\"},
      \"Action\": \"logs:PutLogEvents\",
      \"Resource\": [
        \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:aws/spans:*\",
        \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/application-signals/data:*\"
      ],
      \"Condition\": {
        \"ArnLike\": {\"aws:SourceArn\": \"arn:aws:xray:${AWS_REGION}:${ACCOUNT_ID}:*\"},
        \"StringEquals\": {\"aws:SourceAccount\": \"${ACCOUNT_ID}\"}
      }
    }]
  }"

aws xray update-trace-segment-destination --destination CloudWatchLogs --region "$AWS_REGION"

# Indexed percentage for Transaction Search analytics. 1% is free.
aws xray update-indexing-rule --name "Default" \
  --rule '{"Probabilistic": {"DesiredSamplingPercentage": 1}}' \
  --region "$AWS_REGION"
```

Allow up to ten minutes before spans become searchable.

---

## Step 4. Create the log group

The logs endpoint writes into an **existing** group and stream. It will not
create them.

```bash
aws logs create-log-group  --log-group-name /otel-demo/application --region "$AWS_REGION"
aws logs create-log-stream --log-group-name /otel-demo/application \
  --log-stream-name otel-collector --region "$AWS_REGION"
aws logs put-retention-policy --log-group-name /otel-demo/application \
  --retention-in-days 7 --region "$AWS_REGION"
```

The group and stream names must match the `x-aws-log-group` and
`x-aws-log-stream` headers in `my-values.yaml`.

---

## Step 5. Install the demo

`my-values.yaml` is ready to use as-is for us-east-1. If you're elsewhere, change
the single `AWS_REGION` value under `extraEnvs`; the sigv4 signers and all three
endpoint URLs derive from it via `${env:AWS_REGION}`.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install my-otel-demo open-telemetry/opentelemetry-demo \
  -n "$NAMESPACE" -f my-values.yaml
```

To review the merged collector config before applying:

```bash
helm template my-otel-demo open-telemetry/opentelemetry-demo \
  -n "$NAMESPACE" -f my-values.yaml \
  --show-only charts/opentelemetry-collector/templates/configmap-agent.yaml
```

Check all three pipelines kept both their original exporter and the CloudWatch
one, because **Helm replaces arrays rather than merging them** and a typo
silently drops a backend:

- `traces` → `otlp_grpc/jaeger`, `debug`, `span_metrics`, `otlp_http/cw_traces`
- `metrics` → `otlp_http/prometheus`, `debug`, `otlp_http/cw_metrics`
- `logs` → `opensearch`, `debug`, `otlp_http/cw_logs`

The chart **does not support `helm upgrade` across chart versions**. To change
versions, `helm uninstall` then install fresh.

---

## Step 6. Verify telemetry reaches CloudWatch

```bash
kubectl -n "$NAMESPACE" rollout status ds/otel-collector-agent
kubectl -n "$NAMESPACE" get pods          # expect 31 Running
```

The DaemonSet is `otel-collector-agent`; the ServiceAccount and Service are
`otel-collector`. Easy to trip on.

Confirm Pod Identity credentials landed. The image is distroless, so
`kubectl exec -- env` fails; read the Pod spec instead:

```bash
kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=opentelemetry-collector \
  -o jsonpath='{range .items[0].spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep AWS_
```

Expect `AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials`,
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/...`,
and `AWS_REGION`.

**Definitive check: per-exporter success and failure counts.** The chart pushes
collector self-telemetry over OTLP instead of exposing a scrape port, so these
live in the in-cluster Prometheus:

```bash
kubectl -n "$NAMESPACE" port-forward svc/prometheus 9090:9090 &

for sig in spans metric_points log_records; do
  for st in sent send_failed; do
    echo "### ${st}_${sig}"
    curl -s --get http://localhost:9090/api/v1/query \
      --data-urlencode "query=sum by (exporter) (otelcol_exporter_${st}_${sig}_total)" \
    | python3 -c 'import sys,json
r=json.load(sys.stdin)["data"]["result"]
[print("   %-24s %s" % (m["metric"].get("exporter","?"), m["value"][1])) for m in r] or print("   (none)")'
  done
done
```

You want zero failures on `otlp_http/cw_traces`, `otlp_http/cw_metrics`, and
`otlp_http/cw_logs`. Small non-zero counts on `opensearch` and
`otlp_http/prometheus` are pre-existing upstream demo noise, unrelated to
CloudWatch.

Spot-check the data itself:

```bash
# Traces
aws logs filter-log-events --log-group-name aws/spans --region "$AWS_REGION" \
  --start-time $(( ($(date +%s) - 600) * 1000 )) \
  --filter-pattern '"otel-demo"' --max-items 1

# Logs
aws logs tail /otel-demo/application --since 5m --region "$AWS_REGION"
```

---

## Accessing the app

Everything is ClusterIP, so use a port-forward. `frontend-proxy` is an Envoy that
routes by path prefix, so **one tunnel reaches every UI**:

```bash
kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080
```

Handy as a shell function:

```bash
otel-demo() { kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080; }
```

| URL | What | Routes to |
|---|---|---|
| <http://localhost:8080/> | Astronomy Shop | `frontend:8080` |
| <http://localhost:8080/feature/> | Feature flag UI | `flagd:4000` |
| <http://localhost:8080/jaeger/ui/> | Jaeger | `jaeger:16686` |
| <http://localhost:8080/grafana/> | Grafana | `grafana:80` |
| <http://localhost:8080/telemetry/> | Telemetry docs | `telemetry-docs:8000` |
| <http://localhost:8080/chatbot/> | LLM agent demo | `chatbot:7860` |
| <http://localhost:8080/profiles/> | **503**, see Gotchas | `firepit`, not deployed |

The port-forward is a local process, not cluster state. It dies on Ctrl+C,
terminal close, or laptop sleep, and nothing restarts it. The app keeps running
and keeps sending telemetry to CloudWatch regardless.

There is **no load generator UI**. The v3.0.0 generator is k6, which is headless
by design and has no Service. Watch it with:

```bash
kubectl logs -n otel-demo deploy/load-generator -f
```

---

## Simulating failures

The demo ships 15 feature flags that inject real faults.

**Via the UI:** <http://localhost:8080/feature/>. Instant, no restart.

**Via `flag.sh`,** for scripted or repeatable runs:

```bash
./flag.sh                        # default action: list current state vs baseline
./flag.sh paymentFailure 100%    # inject
./flag.sh paymentFailure off     # revert one flag
./flag.sh --reset                # restore the chart baseline
```

With no arguments it prints current value, chart baseline, and valid variants for
every flag, marking drift with `*`:

```
  FLAG                        CURRENT   BASELINE  VARIANTS
  cartFailure                 off       off       10%,100%,25%,50%,75%,90%,off
  loadGeneratorTraffic        on        on        off,on
  loadGeneratorVUs            5         5         10,25,5,50
* paymentFailure              100%      off       10%,100%,25%,50%,75%,90%,off
* = differs from the chart baseline (1 flag(s)). ./flag.sh --reset restores it.
```

### The baseline

`--reset` restores this, and `*` in the listing means drift from it. It is **not**
"everything off":

| Flag | Baseline | Why |
|---|---|---|
| `loadGeneratorTraffic` | `on` | The demo's traffic engine, not a fault. A reset that silenced it would stop the telemetry you're observing. |
| `loadGeneratorVUs` | `5` | Chart default load level. |
| `paymentFailure` | `75%` | **Local choice**, not the chart default (`off`). Keeps a steady stream of error spans flowing to CloudWatch. |
| everything else | `off` | All 12 remaining fault flags. |

Edit `BASELINE_JSON` near the top of `flag.sh` to change it. Set `paymentFailure`
to `off` there for a clean, fault-free demo.

### How long a flag change lasts

There are two places a flag value can live, and that decides everything:

```
flagd-config ConfigMap          durable, Helm-owned
        │  copied ONCE by init container "init-config" at pod startup
        ▼
config-rw emptyDir → /etc/flagd/demo.flagd.json
        │            flagd READS this. flagd-ui WRITES this.
        ▼
flagd process → services query it per request
```

flagd's container mounts **only** the emptyDir. The ConfigMap is mounted solely
into the init container, so flagd never sees it at runtime.

| Event | `/feature/` UI change | `./flag.sh` change |
|---|---|---|
| Time passes | persists, no TTL | persists |
| flagd pod restarts | **LOST**, emptyDir is pod-scoped and the init container re-copies the ConfigMap | survives |
| `helm upgrade` | lost | **BLOCKS the upgrade**, see below |
| `helm uninstall` + reinstall | lost | lost |

### `flag.sh` breaks the next `helm upgrade`

`flag.sh` uses `kubectl patch`, which makes `kubectl-patch` the server-side-apply
field manager for `.data.demo.flagd.json`. Helm then refuses to take that field
back, and the upgrade **fails outright** rather than silently overwriting:

```
Error: UPGRADE FAILED: conflict occurred while applying object
otel-demo/flagd-config /v1, Kind=ConfigMap: Apply failed with 1 conflict:
conflict with "kubectl-patch" using v1: .data.demo.flagd.json
```

Resolve it by letting Helm reclaim the field, then re-apply your baseline:

```bash
helm upgrade my-otel-demo open-telemetry/opentelemetry-demo \
  -n "$NAMESPACE" -f my-values.yaml --force-conflicts
./flag.sh --reset
```

`--force-conflicts` regenerates the ConfigMap from the chart, so every flag reverts
to the chart default. The `--reset` afterwards puts your baseline back. Verified:
after the upgrade, `paymentFailure` had dropped from `75%` to `off`, and `--reset`
restored it.

Nothing auto-reverts on a timer, and no app restart is needed for a change to
bite: services query flagd per request, so the fault starts on the next one.

**Flag defaults cannot be set in `my-values.yaml`.** The chart builds the
ConfigMap from a JSON file baked into the chart package:

```yaml
# templates/flagd-config.yaml
data:
  {{ (.Files.Glob "flagd/*.json").AsConfig | nindent 2 }}
```

There is no values key for flag definitions, so after a `helm upgrade` or
reinstall, re-apply your baseline with `./flag.sh --reset`.

If you need a baseline that survives `helm upgrade` untouched, the chart does
expose `components.flagd.additionalVolumes[].configMap.name`. Point `config-ro`
at a ConfigMap you create and own instead of the chart's `flagd-config`. The
tradeoff is that you then carry a full copy of all 15 flag definitions and have to
reconcile it whenever the chart's own flag set changes.

| Flag | Variants | Fault |
|---|---|---|
| `paymentFailure` | `off`, `10%`..`100%` | payment charge throws |
| `cartFailure` | `off`, `10%`..`100%` | cart service errors |
| `paymentUnreachable` | `off`, `on` | payment endpoint unreachable |
| `productCatalogFailure` | `off`, `on` | catalog fails on one product id |
| `adFailure` | `off`, `on` | ad service errors |
| `adHighCpu` | `off`, `on` | ad service CPU burn |
| `adManualGc` | `off`, `on` | forced GC pauses in ad |
| `emailMemoryLeak` | `off`, `1x`..`10000x` | growing heap in email |
| `imageSlowLoad` | `off`, `5sec`, `10sec` | slow image responses |
| `intlShippingSlowdown` | `off`, `5sec`, `10sec` | slow international shipping |
| `kafkaQueueProblems` | `off`, `on` | Kafka backpressure |
| `recommendationCacheFailure` | `off`, `on` | recommendation cache leak |
| `failedReadinessProbe` | `off`, `on` | pod fails readiness |
| `loadGeneratorTraffic` | `on`, `off` | stop/start synthetic traffic |
| `loadGeneratorVUs` | `5`, `10`, `25`, `50` | scale load |

### Why `flag.sh` restarts flagd

The chart does **not** mount `flagd-config` into flagd. An init container copies
it into an `emptyDir` once, at pod startup:

```
initContainer init-config (busybox):
  cp /config-ro/demo.flagd.json /config-rw/demo.flagd.json
       ^ ConfigMap (read-only)      ^ emptyDir (read-write)
```

flagd reads, and flagd-ui writes, the **emptyDir copy**. That indirection is what
lets the `/feature/` UI edit flags at runtime without ConfigMap write access.

The consequence: **patching the ConfigMap has no effect on a running pod**, however
long you wait. There is no kubelet sync to wait for, because the ConfigMap is not
the file flagd watches. So `flag.sh` patches the ConfigMap and then runs
`kubectl rollout restart deploy/flagd`. Pass `NO_RESTART=1` to skip that.

The two methods therefore differ in durability, not just convenience:

| | Takes effect | Survives pod restart |
|---|---|---|
| `/feature/` UI | immediately | **no**, emptyDir is rebuilt from the ConfigMap |
| `flag.sh` | after ~15s flagd restart | yes, the ConfigMap is the source of truth |

### Verified example

`./flag.sh paymentFailure 100%` makes the payment service log
`Error: Payment request failed. Invalid token.`, and the matching error spans
arrive in `aws/spans` carrying `service.name: payment`, `k8s.deployment.name`,
`k8s.pod.name`, `traceId`/`parentSpanId` linking back to checkout, plus
`cloud.account.id`, `cloud.region`, `host.id`, and `host.type`. That is enough to
pivot from a failing span to the pod and the instance.

```bash
aws logs filter-log-events --log-group-name aws/spans --region "$AWS_REGION" \
  --start-time $(( ($(date +%s) - 600) * 1000 )) \
  --filter-pattern '"Payment request failed"' --max-items 2
```

---

## AWS resource detection

`my-values.yaml` overrides the chart's `resourcedetection` processor to add the
`eks` and `ec2` detectors:

```yaml
resourcedetection:
  detectors: [env, system, eks, ec2]   # chart default is [env, system]
  timeout: 15s
  eks:
    resource_attributes:
      k8s.cluster.name:
        enabled: true                  # off by default in the processor
  ec2:
    tags: []
```

**Why it matters.** With the chart default, AWS context was inconsistent: it only
appeared on services whose SDK happened to do its own detection. Measured on live
spans before the change, 2 of 13 services (the Node.js ones) had cloud attributes
and 11 had none, and `k8s.cluster.name` was missing everywhere. That last one is
the real problem, because **every cluster in an account and region writes to the
same `aws/spans` log group**, so without a cluster name you cannot separate this
demo from anything else running.

After the change, all 10 services sampled carried all 9 attributes, uniformly
across Java, C++, Go, Node.js, and Python:

| | Before | After |
|---|---|---|
| `k8s.cluster.name` | absent everywhere | `otel-demo-cluster` |
| `cloud.platform` | only Node.js, as `aws_ec2` | `aws_eks` everywhere |
| `cloud.region`, `cloud.account.id`, `cloud.availability_zone` | only Node.js | everywhere |
| `host.id`, `host.type`, `host.image.id` | only Node.js | everywhere |

Detector ordering matters: `eks` is listed before `ec2` so `cloud.platform`
resolves to `aws_eks` rather than `aws_ec2`. Confirmed on live spans.

**Two prerequisites, both worth checking before you enable this.**

IMDS must be reachable from pods, which needs `HttpEndpoint: enabled` and
`HttpPutResponseHopLimit: 2` or more on the nodes:

```bash
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].MetadataOptions'
```

And `k8s.cluster.name` specifically requires **`ec2:DescribeInstances`** on the
collector role. It's in `iam-policy.json` under the `ResourceDetectionEksClusterName`
statement. Without it the other attributes still work, but the cluster name
silently stays absent.

> **Failure mode to respect.** Per the processor docs, "if a configured resource
> detector fails, the error will propagate and stop the collector from starting."
> A blocked IMDS could therefore take down all telemetry, not just degrade the
> attributes. If you're unsure about IMDS in your environment, drop `ec2` and `eks`
> from the list rather than debugging a CrashLoopBackOff. On this cluster the
> collector came up with 0 restarts and no detector errors.

Instance tags are deliberately not collected. Via the API they need
`ec2:DescribeTags`; via IMDS they need `InstanceMetadataTags` enabled on the node,
which is `disabled` here.

### Knock-on effect: Prometheus cardinality

Enabling these detectors **OOMKilled the in-cluster Prometheus** on first rollout,
six restarts before it settled. Worth understanding, because the same trap applies
to any future resource-attribute change.

The chart promotes selected resource attributes to Prometheus labels:

```yaml
# upstream chart, prometheus.server.otlp.promote_resource_attributes
- cloud.availability_zone
- cloud.region
- k8s.cluster.name
```

Those three were previously **empty**, so they contributed nothing to series
identity. The moment `resourcedetection` started populating them on every
datapoint, every existing series got a new identity, cardinality effectively
doubled, and Prometheus blew past its `400Mi` chart default. It then crash-looped:
OOMKill, restart, memory-heavy WAL replay, OOMKill again.

`my-values.yaml` raises the limit to avoid the spike recurring:

```yaml
prometheus:
  server:
    resources:
      limits:
        memory: 1Gi
      requests:
        memory: 512Mi
```

Nothing to worry about for CloudWatch itself, which ingested throughout. But if
you add more promoted attributes, expect a cardinality step-change and size
Prometheus accordingly.

---

## Where to look in CloudWatch

| Signal | Where |
|---|---|
| Traces / spans | Application Signals → **Transaction Search**, or the `aws/spans` log group |
| Logs | Logs → `/otel-demo/application` |
| Metrics | Metrics → **Query Studio**, using PromQL |

OTLP metrics are **not** visible through `aws cloudwatch list-metrics`. They live
on the PromQL-queryable surface, so use Query Studio.

---

## Gotchas

**Component names in the upstream "bring your own backend" doc are stale.** The
[docs snippet](https://opentelemetry.io/docs/demo/kubernetes-deployment/) uses two
names that no longer match chart 0.41.0 / collector 0.156.0. Copying it verbatim
produces a collector that will not start.

| Doc says | Actual | Why |
|---|---|---|
| `spanmetrics` | **`span_metrics`** | Chart 0.41.0 defines the connector as `span_metrics: {}`. Rendering the doc snippet yields an undefined-component error. |
| `otlphttp` | **`otlp_http`** | `otlphttpexporter/metadata.yaml` at collector v0.156.0 declares `type: otlp_http`, `deprecated_type: otlphttp`. |

Treat the chart's own `values.yaml` as the reference, not the website.

**Arrays are replaced, not merged.** Dropping `span_metrics` from the traces
exporters also breaks the metrics pipeline, where `span_metrics` is a *receiver*.

**`/profiles/` returns 503.** The chart's install NOTES advertises it, but
`firepit` isn't deployed because `otel-ebpf-profiler` is disabled by default. The
collector's `profiles` pipeline also logs harmless connection errors against
`firepit:4317`. CloudWatch has no OTLP profiles endpoint anyway.

**The collector image is distroless.** `kubectl exec -- env` and `-- cat` both
fail with `executable file not found in $PATH`. Read the Pod spec instead.

**`aws/spans` rejects JSON filter patterns.** `{ $.status.code = "ERROR" }`
returns `InvalidParameterException: Invalid filter pattern`. Use plain quoted
substring patterns.

**Upstream chart bug: span names aren't sanitized.** Chart 0.41.0 defines
`transform/sanitize_spans` specifically to prevent span-metric cardinality
explosion, then never references it in any pipeline; the traces pipeline gets
`transform/sanitize_logs` instead. Raw high-cardinality span names therefore flow
into `span_metrics` and on to CloudWatch. `my-values.yaml` has a commented-out
`processors` block on the traces pipeline that fixes this. Uncommenting it is
recommended.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `could not retrieve credential provider ... no EC2 IMDS role found` | No credentials reached the pod. Check the `eks-pod-identity-agent` addon is ACTIVE and that the Pod spec has `AWS_CONTAINER_CREDENTIALS_FULL_URI`. Then `rollout restart ds/otel-collector-agent`, since injection happens at pod admission. |
| Pod Identity env vars absent though the association exists | Pods predate the association. Restart the DaemonSet. Pod Identity also doesn't support Fargate or Windows nodes. |
| Node role permissions used instead of the association | Something earlier in the SDK credential chain is winning. Check for `AWS_ACCESS_KEY_ID` or a mounted `~/.aws/config` in the pod. |
| `403 The security token included in the request is invalid` | Wrong region on the signer, or the trust policy is missing `sts:TagSession`. |
| `403 Missing Authentication Token` | Exporter isn't wired to an authenticator, or the sigv4auth extension isn't listed under `service.extensions`. |
| `The OTLP API is supported with CloudWatch Logs as a Trace Segment Destination` | Transaction Search is off. Redo Step 3. |
| `AccessDenied` on logs only | Log group or stream doesn't exist, or the `x-aws-log-group` header doesn't match the ARNs in `iam-policy.json`. |
| `400` complaining about size | Batch too large. Lower `sending_queue.batch.max_size` for that exporter. |
| `429 Too many requests` | Metrics TPS or new-series limit. Raise `flush_timeout`, or cut metric volume as shown under Cost and teardown. |
| Jaeger or Grafana went empty after an edit | You replaced an exporter array without repeating the upstream names. |
| Flag change had no effect | You patched the ConfigMap without restarting flagd. See "Why `flag.sh` restarts flagd". |

---

## Cost and teardown

Roughly **$0.53/hr (~$12-13/day)**: $0.10/hr control plane, $0.384/hr for two
`m5.xlarge`, plus a NAT gateway. This accrues whether or not you have a
port-forward open.

CloudWatch adds ingestion cost on top. The collector runs as a DaemonSet with the
`hostMetrics`, `kubeletMetrics`, `clusterMetrics`, and `annotationDiscovery`
presets enabled plus the `span_metrics` connector, so metric series scale with
node count. The load generator drives traffic continuously. The metrics endpoint
caps at **500 TPS per account** and 1,000,000 new series per 10-minute window.

To trim metrics before they leave the cluster, add a filter to the metrics
pipeline in `my-values.yaml`:

```yaml
opentelemetry-collector:
  config:
    processors:
      filter/cw_metrics_allowlist:
        error_mode: ignore
        metrics:
          metric:
            - 'not IsMatch(name, "^(app|otel_demo|traces_span_metrics).*")'
    service:
      pipelines:
        metrics:
          # Repeat the full list; Helm replaces arrays
          processors: [k8s_attributes, memory_limiter, resourcedetection, resource, filter/cw_metrics_allowlist]
          exporters: [otlp_http/prometheus, debug, otlp_http/cw_metrics]
```

That filter applies to the whole pipeline, so Prometheus stops seeing the dropped
metrics too. To trim only CloudWatch, split into two metrics pipelines sharing the
same receivers.

Teardown:

```bash
# App only, keep the cluster
helm uninstall my-otel-demo -n "$NAMESPACE"

# Everything
eksctl delete cluster -f cluster.yaml --disable-nodegroup-eviction

aws logs delete-log-group --log-group-name /otel-demo/application --region "$AWS_REGION"
aws iam detach-role-policy --role-name otel-demo-cloudwatch-collector \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoCloudWatchOtlpAccess"
aws iam delete-role --role-name otel-demo-cloudwatch-collector
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoCloudWatchOtlpAccess"

# Optional, and only if nothing else in the account depends on it.
# It is an account-wide, region-wide setting.
# aws xray update-trace-segment-destination --destination XRay --region "$AWS_REGION"
```

Deleting the cluster removes the Pod Identity association with it. The IAM role
and policy survive and are reusable on a future cluster.

---

## Files

Six files, nothing generated.

| File | Purpose |
|---|---|
| `README.md` | This document |
| `cluster.yaml` | eksctl config: 2 × m5.xlarge, Pod Identity agent, no OIDC |
| `my-values.yaml` | Helm values: CloudWatch exporters, sigv4 signers, region env |
| `iam-policy.json` | Permissions policy for the collector role |
| `trust-policy-pod-identity.json` | Role trust policy (`pods.eks.amazonaws.com`, reusable) |
| `flag.sh` | Flip feature flags to inject failures |

---

## Validated against

| Component | Version |
|---|---|
| `open-telemetry/opentelemetry-demo` chart | 0.41.0 (appVersion 3.0.0) |
| `opentelemetry-collector` subchart | 0.165.0 |
| Collector image | `otel/opentelemetry-collector-contrib:0.156.0` |
| Kubernetes | 1.33 on EKS (`eks.41`) |
| Helm | 4.1.0 |

Deployed and verified live in us-east-1: 31/31 pods Running, and per-exporter
counters showing **0 failures** across all three CloudWatch exporters
(22,780 spans, 117,364 datapoints, 9,575 log records at time of check). Demo
spans confirmed present in `aws/spans` with full Kubernetes metadata, and
`/otel-demo/application` receiving log events.

Three things confirmed empirically rather than assumed:

1. **SigV4 over Pod Identity works** with zero 403s across all three endpoints.
2. **Cumulative temporality is accepted** by the metrics endpoint. No
   `cumulativetodelta` processor is needed.
3. **`xray:PutTraceSegments` is sufficient** for the X-Ray OTLP endpoint given
   Transaction Search is enabled.
