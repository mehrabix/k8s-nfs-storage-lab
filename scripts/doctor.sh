#!/usr/bin/env bash
# Check whether this cluster can actually mount NFS, and say what to do if not.
#
# NFS mounts happen in the kernel, and the mount is performed by the *kubelet*
# on the node - not by your Pod, not by the container image. So this checks the
# kubelet's path, because that is the one that matters.
#
# A privileged Pod that can mount NFS is NOT proof that the cluster can: a Pod
# brings its own userspace (mount.nfs from its image), while the kubelet uses
# whatever userspace the node ships. Those can disagree, and when they do the
# error only ever appears in the Pod's events.
set -uo pipefail

NS="${NS:-nfs-lab}"
PROBE_SERVER="${PROBE_SERVER:-nfs-doctor-probe.invalid}"

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
no()   { printf '  \033[31mno\033[0m   %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

printf '\n== cluster ==\n'
kubectl version 2>/dev/null | sed 's/^/  /' || true
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'

printf '\n== can the kubelet mount an NFS volume? ==\n'
kubectl create namespace "$NS" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
kubectl -n "$NS" delete pod nfs-doctor --ignore-not-found >/dev/null 2>&1

# Point at a server that does not resolve. The failure *message* tells us
# whether the node's NFS userspace works at all:
#   "Resource temporarily unavailable" / "failed to apply fstab options"
#       -> the node cannot mount NFS, regardless of the server
#   "Failed to resolve" / "Name or service not known" / "Connection timed out"
#       -> the stack works; the probe server is simply unreachable, as intended
cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: nfs-doctor
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.37
      command: ["sh", "-c", "echo kubelet-could-mount"]
      volumeMounts:
        - name: share
          mountPath: /share
  volumes:
    - name: share
      nfs:
        server: ${PROBE_SERVER}
        path: /
EOF

msg=""
# the kubelet's first mount attempt can take up to a couple of minutes, so wait
for _ in $(seq 1 45); do
  phase="$(kubectl -n "$NS" get pod nfs-doctor -o jsonpath='{.status.phase}' 2>/dev/null)"
  case "$phase" in
    Succeeded|Running) break ;;
  esac
  msg="$(kubectl -n "$NS" get events \
    --field-selector 'involvedObject.name=nfs-doctor,reason=FailedMount' \
    -o jsonpath='{.items[-1:].message}' 2>/dev/null)"
  [ -n "$msg" ] && break
  sleep 5
done
kubectl -n "$NS" delete pod nfs-doctor --ignore-not-found >/dev/null 2>&1

status=0
if [ -z "$msg" ]; then
  ok "the kubelet mounted an NFS volume (or gave up without a mount error)"
  info "no FailedMount event was produced for an unresolvable server, which is"
  info "unusual - run the lab and watch the Pod events if anything looks odd."
elif printf '%s' "$msg" | grep -Eq 'Resource temporarily unavailable|failed to apply fstab options|Protocol not supported'; then
  no "the kubelet cannot mount NFS on this node"
  info "$(printf '%s' "$msg" | head -1)"
  printf '\n'
  info "This is the node's userspace NFS stack, not your manifests. On a"
  info "minikube 'docker' node it usually means the nfs-utils shipped in the"
  info "node image is incompatible with the host kernel. Options:"
  info "  * load the modules on the host: sudo modprobe nfs nfsv3 nfsv4 nfsd"
  info "  * if that does not help, recreate the node image: minikube delete && minikube start"
  info "  * or run the lab on a cluster whose nodes ship a working nfs-utils"
  info "    (kind, k3s on a VM, or a managed cluster all work)"
  status=1
else
  ok "the node's NFS userspace works"
  info "the probe failed to reach ${PROBE_SERVER}, which is the expected result"
fi

printf '\n== summary ==\n'
if [ "$status" -eq 0 ]; then
  ok "prerequisites look good - try: make up && make diagnose && make fix"
else
  no "the scenario's broken state will reproduce, but the recovery path needs a"
  info "node that can mount NFS. See docs/nfs-in-kubernetes.md#the-kernel-requirement-with-evidence"
fi
echo
exit "$status"
