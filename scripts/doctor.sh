#!/usr/bin/env bash
# Check that this machine can actually mount NFS, and say what to do if not.
#
# NFS mounts happen in the kernel. If the nfs client module is not loaded on
# the host that runs your nodes, the in-cluster server and every mount will
# fail, and it will look like a Kubernetes problem when it is not one.
set -uo pipefail

NS="${NS:-nfs-lab}"
IMAGE="${IMAGE:-busybox:1.37}"

say() { printf '%s\n' "$*"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; }
no()  { printf '  \033[31mno\033[0m   %s\n' "$*"; }

say "== cluster =="
kubectl version 2>/dev/null | sed 's/^/  /' || true
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'

say
say "== nfs client support on the node kernel =="
kubectl create namespace "$NS" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1

out="$(kubectl -n "$NS" run nfs-doctor --rm -i --restart=Never --quiet \
  --image="$IMAGE" --command -- \
  sh -c 'if grep -qw nfs /proc/filesystems; then echo "client=yes"; else echo "client=no"; fi; if [ -d /proc/fs/nfsd ]; then echo "server=yes"; else echo "server=no"; fi' 2>&1)"

if echo "$out" | grep -q 'client=yes'; then
  ok "the node kernel supports the NFS client"
else
  no "the node kernel cannot mount NFS yet"
fi
if echo "$out" | grep -q 'server=yes'; then
  ok "the node kernel supports running an NFS server (nfsd)"
else
  no "the node kernel cannot run an NFS server yet"
fi

if ! echo "$out" | grep -q 'client=yes' || ! echo "$out" | grep -q 'server=yes'; then
  say
  say "Fix it on the host (not in Kubernetes):"
  say "  sudo modprobe nfs nfsv3 nfsv4 nfsd"
  say "  # to make it survive a reboot:"
  say "  echo -e 'nfs\nnfsv3\nnfsv4\nnfsd' | sudo tee /etc/modules-load.d/nfs.conf"
  say
  say "If it is already loaded on the host, the minikube docker driver node"
  say "shares its kernel, so no restart is needed."
  exit 1
fi

say
ok "prerequisites look good"
