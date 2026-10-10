#!/usr/bin/env bash
# End-to-end check for scenario 01.
#
#   ./verify.sh broken   # must see a Pending claim with nobody to provision it
#   ./verify.sh fixed    # must see a Bound claim and a writing pod
set -uo pipefail

NS="${NS:-nfs-lab}"
PVC="${PVC:-data}"
PROVISIONER="${PROVISIONER:-k8s-sigs.io/nfs-subdir-external-provisioner}"
MODE="${1:-fixed}"
TIMEOUT="${TIMEOUT:-120}"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (got '$2', want '$3')"; fi; }

# Events about the claim itself, filtered by type. Counting rows avoids
# depending on how `describe` formats an empty event list.
claim_events() { # [$1 = extra field selector]
  local sel="involvedObject.kind=PersistentVolumeClaim"
  [ -n "${1:-}" ] && sel="$sel,$1"
  kubectl -n "$NS" get events --field-selector "$sel" --no-headers 2>/dev/null | grep -c . || true
}

case "$MODE" in
  broken)
    echo "== expecting the broken state =="

    check "PVC phase" \
      "$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null)" "Pending"

    # The claim is not rejected, so there must be no Warning event on it.
    check "Warning events on the claim" "$(claim_events 'type=Warning')" "0"

    # Instead there is a Normal event that names the provisioner Kubernetes
    # is waiting for. That event is the pointer, not the failure.
    check "ExternalProvisioning events on the claim" \
      "$(claim_events 'reason=ExternalProvisioning')" "1"

    msg="$(kubectl -n "$NS" get events \
      --field-selector 'involvedObject.kind=PersistentVolumeClaim,reason=ExternalProvisioning' \
      -o jsonpath='{.items[0].message}' 2>/dev/null)"
    if printf '%s' "$msg" | grep -qF "$PROVISIONER"; then
      ok "the event names the missing provisioner"
    else
      bad "the event does not name '$PROVISIONER' (got: $msg)"
    fi

    check "provisioner pods running" \
      "$(kubectl -n "$NS" get pods -l app=nfs-client-provisioner --no-headers 2>/dev/null | wc -l)" "0"

    check "writer pod not Running" \
      "$(kubectl -n "$NS" get pods -l app=writer -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" \
      "Pending"
    ;;

  fixed)
    echo "== expecting the fixed state =="

    deadline=$((SECONDS + TIMEOUT))
    phase=""
    while [ $SECONDS -lt $deadline ]; do
      phase="$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null)"
      [ "$phase" = "Bound" ] && break
      sleep 3
    done
    check "PVC phase" "$phase" "Bound"

    check "a PV exists with an nfs source" \
      "$(kubectl get pv -o jsonpath='{range .items[?(@.spec.nfs)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c .)" \
      "1"

    check "the PV points at the in-cluster server" \
      "$(kubectl get pv -o jsonpath='{range .items[?(@.spec.nfs)]}{.spec.nfs.server}{end}' 2>/dev/null | grep -c 'nfs-server')" \
      "1"

    check "provisioner pod Running" \
      "$(kubectl -n "$NS" get pods -l app=nfs-client-provisioner -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" \
      "Running"

    deadline=$((SECONDS + TIMEOUT))
    wp=""
    while [ $SECONDS -lt $deadline ]; do
      wp="$(kubectl -n "$NS" get pods -l app=writer -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
      [ "$wp" = "Running" ] && break
      sleep 3
    done
    check "writer pod Running" "$wp" "Running"

    lines="$(kubectl -n "$NS" exec deploy/writer -- wc -l /data/heartbeat 2>/dev/null | awk '{print $1}')"
    if [ -n "$lines" ] && [ "$lines" -ge 1 ] 2>/dev/null; then
      ok "writer has appended $lines line(s) to the shared volume"
    else
      bad "could not read /data/heartbeat from the writer pod"
    fi
    ;;

  *)
    echo "usage: $0 [broken|fixed]" >&2
    exit 2
    ;;
esac

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
