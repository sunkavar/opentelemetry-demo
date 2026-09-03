#!/usr/bin/env bash
# Flip OpenTelemetry demo feature flags to inject failures, without the UI.
#
#   ./flag.sh                          DEFAULT ACTION: list flags, current value,
#                                      chart baseline, and valid variants
#   ./flag.sh paymentFailure 100%      set a flag
#   ./flag.sh paymentFailure off       turn it back off
#   ./flag.sh --reset                  restore the chart baseline (all faults off,
#                                      load generator left ON)
#
# WHY THIS RESTARTS flagd
#
# The chart does NOT mount the ConfigMap into flagd directly. An init container
# named init-config runs, once at pod startup:
#
#   cp /config-ro/demo.flagd.json /config-rw/demo.flagd.json
#
# where config-ro is the flagd-config ConfigMap and config-rw is an emptyDir.
# flagd reads, and flagd-ui writes, the emptyDir copy. That indirection is what
# lets the /feature/ UI edit flags at runtime without ConfigMap write access.
#
# The consequence: patching the ConfigMap has NO effect on a running pod, no
# matter how long you wait. The copy only happens at startup. So this script
# patches the ConfigMap and then restarts the flagd deployment.
#
# TRADEOFFS vs the /feature/ UI:
#   this script  - scriptable, survives pod restarts, but bounces flagd (~15s)
#                  and discards any edits made in the UI
#   /feature/ UI - instant, no restart, but lives only in the emptyDir and is
#                  lost whenever the flagd pod is recreated
#
# Env overrides: NS (default otel-demo), CM (default flagd-config),
#                NO_RESTART=1 to skip the rollout restart

set -euo pipefail

NS="${NS:-otel-demo}"
CM="${CM:-flagd-config}"
KEY="demo.flagd.json"

need() { command -v "$1" >/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
need kubectl
need python3

# ---------------------------------------------------------------------------
# BASELINE: the desired steady state for this deployment.
#
# --reset restores exactly this, and the "*" marker in the listing flags drift
# from it. Anything NOT listed here is assumed to belong in its "off"/"false"
# variant, which covers the remaining fault flags.
#
#   loadGeneratorTraffic / loadGeneratorVUs
#       ON by design. These are the demo's traffic engine, not faults. A reset
#       that silenced them would stop the telemetry you are trying to observe.
#
#   paymentFailure: 75%
#       LOCAL CHOICE, not the chart default (the chart ships "off"). Kept on so
#       there is always a steady stream of error spans to look at in CloudWatch.
#       Set this back to "off" for a clean, fault-free demo.
#
# NOTE ON DURABILITY: the chart builds the flagd-config ConfigMap from a JSON
# file baked into the chart package:
#     data: {{ (.Files.Glob "flagd/*.json").AsConfig }}
# There is therefore NO Helm values key for flag defaults, so this baseline
# cannot live in my-values.yaml. It survives flagd pod restarts, but a
# `helm upgrade` or reinstall regenerates the ConfigMap from the chart and wipes
# it. Re-apply with `./flag.sh --reset` afterwards.
# ---------------------------------------------------------------------------
export BASELINE_JSON='{"loadGeneratorTraffic": "on", "loadGeneratorVUs": "5", "paymentFailure": "75%"}'

read_flags() {
  kubectl get cm "$CM" -n "$NS" -o "jsonpath={.data.${KEY//./\\.}}"
}

case "${1:-}" in
  ""|-l|--list)
    read_flags | python3 -c '
import sys, json, os
cfg = json.load(sys.stdin)
flags = cfg.get("flags", {})
baseline = json.loads(os.environ["BASELINE_JSON"])

def expected(name, f):
    if name in baseline:
        return baseline[name]
    for cand in ("off", "false"):
        if cand in f.get("variants", {}):
            return cand
    return None

w = max(len(n) for n in flags) + 2
print("  " + "FLAG".ljust(w) + "CURRENT   BASELINE  VARIANTS")
drift = 0
for n in sorted(flags):
    f = flags[n]
    cur = str(f.get("defaultVariant", "?"))
    exp = str(expected(n, f))
    variants = ",".join(f.get("variants", {}).keys())
    mark = "  "
    if cur != exp:
        mark = "* "
        drift += 1
    print(mark + n.ljust(w) + cur.ljust(10) + exp.ljust(10) + variants)
print("")
if drift:
    print("* = differs from baseline (" + str(drift) + " flag(s)). ./flag.sh --reset restores it.")
else:
    print("all flags at baseline.")
'
    exit 0
    ;;
esac

if [[ "${1:-}" == "--reset" ]]; then
  TARGET_ALL=1
else
  TARGET_ALL=0
  FLAG="$1"
  VARIANT="${2:-}"
  if [[ -z "$VARIANT" ]]; then
    echo "error: no variant given. usage: $0 <flag> <variant>   (see: $0 --list)" >&2
    exit 1
  fi
fi

CURRENT_JSON="$(read_flags)"

if [[ "$TARGET_ALL" == "1" ]]; then
  NEW_JSON="$(printf '%s' "$CURRENT_JSON" | python3 -c '
import sys, json, os
cfg = json.load(sys.stdin)
baseline = json.loads(os.environ["BASELINE_JSON"])
changed = []
for n, f in cfg.get("flags", {}).items():
    v = f.get("variants", {})
    # Baseline wins where defined, so the load generator is left ON.
    if n in baseline:
        target = baseline[n]
    else:
        target = next((c for c in ("off", "false") if c in v), None)
    if target is None or target not in v:
        continue
    old = f.get("defaultVariant")
    if old != target:
        changed.append(n + ": " + str(old) + " -> " + str(target))
        f["defaultVariant"] = target
sys.stderr.write("reset: " + (", ".join(changed) if changed else "already at baseline") + "\n")
print(json.dumps(cfg, indent=2))
')"
else
  NEW_JSON="$(printf '%s' "$CURRENT_JSON" | FLAG="$FLAG" VARIANT="$VARIANT" python3 -c '
import sys, json, os
cfg = json.load(sys.stdin)
flag = os.environ["FLAG"]
variant = os.environ["VARIANT"]
flags = cfg.get("flags", {})
if flag not in flags:
    sys.exit("error: unknown flag " + repr(flag) + ". valid: " + str(sorted(flags)))
valid = list(flags[flag].get("variants", {}).keys())
if variant not in valid:
    sys.exit("error: invalid variant " + repr(variant) + " for " + flag + ". valid: " + str(valid))
old = flags[flag].get("defaultVariant")
flags[flag]["defaultVariant"] = variant
sys.stderr.write(flag + ": " + str(old) + " -> " + variant + "\n")
print(json.dumps(cfg, indent=2))
')"
fi

# Patch only the one data key, so Helm ownership labels/annotations survive.
printf '%s' "$NEW_JSON" | python3 -c '
import sys, json
body = {"data": {"'"$KEY"'": sys.stdin.read()}}
print(json.dumps(body))
' | kubectl patch cm "$CM" -n "$NS" --type merge --patch-file /dev/stdin >/dev/null

echo "patched configmap/$CM in $NS"

if [[ "${NO_RESTART:-0}" == "1" ]]; then
  echo "NO_RESTART=1 set. flagd will NOT see this until its pod is recreated."
  exit 0
fi

echo "restarting flagd so the init container re-copies the config..."
kubectl rollout restart deploy/flagd -n "$NS" >/dev/null
kubectl rollout status deploy/flagd -n "$NS" --timeout=120s
echo "done. allow ~30s for traffic to start hitting the new behaviour."
