#!/usr/bin/env bash
# Read-only diagnosis for "the PVC that never binds".
#
# Nothing here changes the cluster. It collects the evidence a human would
# collect, in the order a human should collect it.
#
#   ./diagnose.sh
set -uo pipefail

NS="${NS:-nfs-lab}"
SC="${SC:-nfs-client}"
PVC="${PVC:-data}"

hr()   { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }

hr "1) What does the claim say?"
kubectl -n "$NS" get pvc "$PVC" 2>&1 | sed 's/^/   /'

hr "2) What does Kubernetes say about it?"
kubectl -n "$NS" get events \
  --field-selector involvedObject.kind=PersistentVolumeClaim \
  -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message 2>&1 | sed 's/^/   /'

warnings="$(kubectl -n "$NS" get events \
  --field-selector 'involvedObject.kind=PersistentVolumeClaim,type=Warning' \
  --no-headers 2>/dev/null | grep -c . || true)"

if [ "${warnings:-0}" -eq 0 ]; then
  note ""
  note "Zero Warning events. Nothing refused this claim - it has simply not been"
  note "answered. The only message is a Normal ExternalProvisioning event, and"
  note "that message is not an error: it names the provisioner Kubernetes is"
  note "waiting for. Use it as a pointer, not as a failure."
fi

hr "3) Which StorageClass does it use, and who is supposed to provision it?"
kubectl -n "$NS" get pvc "$PVC" -o jsonpath='   storageClassName: {.spec.storageClassName}{"\n"}' 2>&1
provisioner="$(kubectl get sc "$SC" -o jsonpath='{.provisioner}' 2>/dev/null)"
note "provisioner expected : ${provisioner:-<storageclass missing>}"
binding="$(kubectl get sc "$SC" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"
note "volumeBindingMode   : ${binding:-<unknown>}"

if [ "$binding" = "WaitForFirstConsumer" ]; then
  note ""
  note "WaitForFirstConsumer: Pending is expected until a Pod schedules."
  note "Check for a consumer pod before concluding anything real is broken."
fi

hr "4) Is anything actually running that provisioner?"
kubectl -n "$NS" get pods -o wide 2>&1 | sed 's/^/   /'
note ""
running="$(kubectl -n "$NS" get pods -l app=nfs-client-provisioner \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)"
if [ -z "$running" ]; then
  note "No provisioner pod in this namespace."
  note "Check the whole cluster before concluding it is missing:"
  note "  kubectl get pods -A | grep -i provisioner"
else
  echo "$running" | sed 's/^/   provisioner pod: /'
fi

hr "5) If a provisioner pod exists but is stuck, why?"
stuck="$(kubectl -n "$NS" get pods -l app=nfs-client-provisioner \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{end}' 2>/dev/null)"
if [ -n "$stuck" ]; then
  kubectl -n "$NS" describe pod -l app=nfs-client-provisioner 2>&1 \
    | sed -n '/^Events:/,$p' | tail -6 | sed 's/^/   /'
  note ""
  note "The Output: line inside MountVolume.SetUp failed is the real error."
  note "See docs/error-reference.md for what each one means."
else
  note "(no provisioner pod to inspect)"
fi

hr "6) Did anything else notice the claim is unsatisfied?"
kubectl -n "$NS" get events --field-selector 'involvedObject.kind=Pod' \
  -o custom-columns=OBJ:.involvedObject.name,REASON:.reason,MESSAGE:.message 2>&1 \
  | grep -iE 'schedul|volume|mount|OBJ' | sed 's/^/   /'
note ""
note "nfs-server endpoints:"
kubectl -n "$NS" get endpointslice -l kubernetes.io/service-name=nfs-server \
  -o custom-columns=NAME:.metadata.name,ADDRESSES:.endpoints[*].addresses,PORTS:.ports[*].port 2>&1 | sed 's/^/   /'

hr "Verdict"
cat <<'EOF'
   Pending + no Warning events + the ExternalProvisioning message naming a
   provisioner that is not running
       -> nobody is going to answer this claim. Deploy the provisioner.

   Pending + a provisioner pod stuck in ContainerCreating with an
   Output: line in its events
       -> the provisioner cannot mount its own volume. Fix that first;
          the claim is merely downstream of it.

   Pending + WaitForFirstConsumer
       -> not a bug. The claim waits for a Pod to be scheduled first.
EOF
