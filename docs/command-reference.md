# Command reference

The commands that matter for storage debugging, grouped by the question you are
actually asking. Every command here is read-only.

---

## "What is the state of the claim?"

```bash
kubectl -n <ns> get pvc
kubectl -n <ns> get pvc <name> -o wide
kubectl -n <ns> get pvc <name> -o yaml
```

`STATUS` is the summary. `-o yaml` shows the part that matters for binding:
`spec.accessModes`, `spec.storageClassName`, `spec.volumeMode`,
`spec.selector`.

```bash
# one line per claim with the fields the binder actually matches on
kubectl -n <ns> get pvc -o custom-columns=\
NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,\
CLASS:.spec.storageClassName,MODES:.spec.accessModes,SIZE:.spec.resources.requests.storage
```

## "Did anything explain itself?"

```bash
kubectl -n <ns> describe pvc <name> | sed -n '/Events:/,$p'

# refusals only — a Warning means something rejected the claim
kubectl -n <ns> get events --field-selector \
  involvedObject.kind=PersistentVolumeClaim,type=Warning \
  -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message
```

**The single most informative command in this guide.** Read the event *types*,
not just their presence. A `Warning` is a refusal with a reason. A `Normal
ExternalProvisioning` is Kubernetes telling you which provisioner it is waiting
for — the name of the missing component, handed to you directly.

```bash
# events across the namespace, newest last
kubectl -n <ns> get events --sort-by=.lastTimestamp

# only the ones about volumes
kubectl -n <ns> get events --field-selector reason=ProvisioningFailed
kubectl -n <ns> get events | grep -iE 'provision|volume|mount|pvc'
```

## "Is anything waiting on this claim?"

```bash
kubectl -n <ns> describe pvc <name> | grep 'Used By'
kubectl -n <ns> get pods -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}'
```

A `Pending` claim that nobody references may be exactly correct — most often
because the class uses `WaitForFirstConsumer`.

## "Who is supposed to provision this?"

```bash
kubectl get sc
kubectl get sc <class> -o yaml
kubectl get sc <class> -o jsonpath='{.provisioner}{"\n"}'
kubectl get sc <class> -o jsonpath='{.volumeBindingMode}{"\n"}'
kubectl get sc <class> -o jsonpath='{.reclaimPolicy}{"\n"}'
kubectl get sc <class> -o jsonpath='{.allowedTopologies}{"\n"}'
```

```bash
# which class is the default?
kubectl get sc -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

## "Does that provisioner exist anywhere in the cluster?"

Provisioners do not have to live in the namespace you are working in, so search
everywhere:

```bash
kubectl get pods -A | grep -i <provisioner-fragment>
kubectl get pods -A -o wide | grep -i nfs

# by the deployment rather than the pod
kubectl get deploy -A | grep -i <provisioner-fragment>

# what registered provisioner names does this cluster have?
kubectl get csidrivers
kubectl get storageclass -o jsonpath='{range .items[*]}{.provisioner}{"\n"}{end}' | sort -u
```

## "Is the provisioner healthy, and what does it say?"

```bash
kubectl -n <ns> get pods -l app=<provisioner>
kubectl -n <ns> describe pod -l app=<provisioner> | sed -n '/Events:/,$p'
kubectl -n <ns> logs -l app=<provisioner> --tail=100
kubectl -n <ns> logs -l app=<provisioner> --previous      # the crash before this one
```

The `describe` output is where `MountVolume.SetUp failed ... Output: ...` lives,
which is the real error when the provisioner cannot mount its own volume.

## "What got created?"

```bash
kubectl get pv
kubectl -n <ns> get pv -o custom-columns=\
NAME:.metadata.name,CLASS:.spec.storageClassName,CAP:.spec.capacity.storage,\
MODES:.spec.accessModes,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy

# which PVs actually use NFS, and where do they point?
kubectl get pv -o jsonpath=\
'{range .items[?(@.spec.nfs)]}{.metadata.name}{"\t"}{.spec.nfs.server}{":"}{.spec.nfs.path}{"\n"}{end}'

# what is the PV bound to?
kubectl get pv <pv> -o jsonpath='{.spec.claimRef}{"\n"}'
```

A PV stuck in `Released` still holds its `claimRef` and will not bind to a new
claim until you clear it or delete the PV.

## "Is a Pod actually mounting something?"

Pod events are where mount failures appear — even when the fault is a claim:

```bash
kubectl -n <ns> describe pod <pod> | sed -n '/Events:/,$p'
kubectl -n <ns> describe pod <pod> | grep -iE 'mount|nfs|timed out|denied|unavailable'
```

Inside a running Pod:

```bash
kubectl -n <ns> exec deploy/<workload> -- mount | grep -i nfs
kubectl -n <ns> exec deploy/<workload> -- df -hT
kubectl -n <ns> exec deploy/<workload> -- ls -la /data
kubectl -n <ns> exec deploy/<workload> -- id           # what UID is writing?
kubectl -n <ns> exec deploy/<workload> -- touch /data/probe
```

`mount | grep nfs` shows the options the volume was actually mounted with,
including what the server negotiated. `id` explains most permission failures.

## "Can this node mount NFS at all?"

The question that separates a Kubernetes problem from a kernel problem:

```bash
# on the node (minikube)
minikube ssh -p <profile> -- 'grep -w nfs /proc/filesystems'

# on any cluster: a throwaway privileged Pod
kubectl run nfs-probe --rm -i --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.37",
  "securityContext":{"privileged":true},
  "command":["sh","-c","grep -w nfs /proc/filesystems || echo MISSING"]}]}}'
```

No output from `grep` means the kernel has no NFS client. Fix the host:

```bash
sudo modprobe nfs nfsv3 nfsv4 nfsd
```

## "Can the network reach the server?"

```bash
# does the Service have backing endpoints?
kubectl -n <ns> get svc,endpoints,endpointslices
kubectl -n <ns> describe endpoints nfs-server

# from inside the cluster
kubectl -n <ns> run netcheck --rm -i --restart=Never --image=busybox:1.37 \
  --command -- sh -c 'nc -zv nfs-server 2049; nslookup nfs-server'
```

If `ENDPOINTS` is `<none>`, the Service selector matches no ready Pod — the
server is down or not passing its readiness probe, and no amount of client
configuration will help.

## "What does the server itself think?"

```bash
kubectl -n <ns> logs deploy/nfs-server --tail=50
kubectl -n <ns> logs deploy/nfs-server | grep -iE 'export|denied|refused|error'
```

For an in-cluster server you can also inspect the exports from inside:

```bash
kubectl -n <ns> exec deploy/nfs-server -- cat /etc/exports
kubectl -n <ns> exec deploy/nfs-server -- exportfs -v
```

## "Why was a Pod killed / scheduled where?"

Adjacent but frequently relevant when storage stalls:

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.nodeName}{"\n"}'
kubectl describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
kubectl -n <ns> get pod <pod> -o jsonpath='{.status.conditions}{"\n"}'
```

---

## A one-shot triage script

```bash
ns=nfs-lab
echo "--- claim ---"   ; kubectl -n $ns get pvc
echo "--- events ---"  ; kubectl -n $ns describe pvc data | sed -n '/Events:/,$p'
echo "--- class ---"   ; kubectl get sc nfs-client -o jsonpath='{.provisioner}{" / "}{.volumeBindingMode}{"\n"}'
echo "--- provider --" ; kubectl get pods -A | grep -i provisioner
echo "--- volumes ---" ; kubectl get pv
```

That is the same order `scenarios/01-pvc-pending/diagnose.sh` automates.
