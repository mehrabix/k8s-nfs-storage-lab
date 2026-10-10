# The PVC Pending playbook

Every reason a PersistentVolumeClaim can sit in `Pending`, and how to tell them
apart. `Pending` is not one problem — it is at least ten different ones wearing
the same badge.

The whole playbook rests on one question:

> **Was the request refused, or is it simply not answered yet?**

A refusal produces a **`Warning` event with a reason**. A request that nobody
has answered produces a **`Normal` event naming the component Kubernetes is
waiting for**. The second kind is the one that costs people an afternoon,
because `Normal` reads like "nothing to see here" and gets scrolled past.

That single distinction splits the tree in half.

---

## Triage

Run these in order. Stop as soon as one of them explains what you see.

```bash
# 1. what exactly is pending?
kubectl -n <ns> get pvc

# 2. is anything refusing it? (Warning events are refusals)
kubectl -n <ns> get events --field-selector \
  involvedObject.kind=PersistentVolumeClaim,type=Warning \
  -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message

# 3. what does it have instead? (Normal events name who Kubernetes waits for)
kubectl -n <ns> describe pvc <name> | sed -n '/Events:/,$p'

# 4. is anything waiting on it? (no consumer can mean Pending is correct)
kubectl -n <ns> describe pvc <name> | grep 'Used By'

# 5. who is supposed to provision it, and may it wait?
kubectl get sc <class> -o jsonpath='{.provisioner}{"\n"}{.volumeBindingMode}{"\n"}'

# 6. does that provisioner exist anywhere in the cluster?
kubectl get pods -A -o wide | grep -i <provisioner-name-fragment>

# 7. what did a consumer pod say?
kubectl -n <ns> describe pod <consumer-pod> | sed -n '/Events:/,$p'
```

---

## A. The request was refused (Warning events)

You have a `Warning`. Read it literally — it names the cause more often than
people expect.

### A1. StorageClass not found

The claim names a StorageClass that does not exist.

```console
$ kubectl -n app describe pvc data
  Warning  ProvisioningFailed  ...  storageclass.storage.k8s.io "nfs-client" not found
```

**Confirm:** `kubectl get sc` — the class is simply not there.

**Fix:** create the StorageClass, or correct `spec.storageClassName` on the
claim. Note that `storageClassName` is **immutable** on an existing PVC: you
must delete and recreate the claim (which is why you should get it right before
anything depends on it).

### A2. No default StorageClass

The claim omits `storageClassName` and no StorageClass is marked default:

```console
  Warning  ProvisioningFailed  ...  no default StorageClass found for this claim
```

**Confirm:** `kubectl get sc` — look for the annotation
`storageclass.kubernetes.io/is-default-class: "true"`. On modern clusters you
can have several defaults, which is its own bug.

**Fix:** either set `storageClassName` explicitly (always the clearest thing to
do), or mark a class as default:

```bash
kubectl annotate sc <class> storageclass.kubernetes.io/is-default-class=true
```

### A3. Unsupported access mode

The provisioner cannot do what the claim asks. The classic: asking for
`ReadWriteMany` from a provisioner that only creates block volumes.

```console
  Warning  ProvisioningFailed  ...  rbd: unsupported access mode "ReadWriteMany"
```

**Confirm:** read the message; then check what the provisioner supports.

**Fix:** ask for what it can do (`ReadWriteOnce` on block storage), or use a
provisioner that *can* do `ReadWriteMany` — NFS, CephFS, Longhorn, Azure Files.
This is precisely why NFS still matters in 2026: `ReadWriteMany` on a block
device is a category error.

### A4. Quota or capacity refusal

```console
  Warning  ProvisioningFailed  ...  exceeded quota: storage-quota, requested: requests.storage=10Gi
  Warning  ProvisioningFailed  ...  requested capacity is greater than the maximum allowed (5Gi)
```

**Confirm:**

```bash
kubectl -n <ns> get resourcequota -o yaml | grep -A5 'hard:'
kubectl -n <ns> get limitrange -o yaml
```

**Fix:** raise the quota, or ask for less. Many clusters cap a single PVC
(cluster-autoscaler-managed platforms often cap per-volume size limits).

### A5. Provisioning failed inside the provisioner

Generic wrapper. The real cause is in **the provisioner's logs**, not in the
event:

```bash
kubectl -n <provisioner-ns> logs -l app=<provisioner> --tail=100
```

Look for the underlying error — DNS failure, TLS failure, cloud API
rate-limiting, a missing credential, an unreachable server.

---

## B. The request was not answered (only Normal events)

No `Warning` on the claim. Kubernetes has not refused anything — it is waiting
for a provisioner that never arrives, or for a condition that has not happened
yet. The events you *do* see are `Normal`, and they are still worth reading:
they name what Kubernetes is waiting for.

### B1. No provisioner implements the StorageClass

*This is scenario 01.*

The StorageClass exists, the claim is valid, and the program named in
`spec.provisioner` is not running. The volume controller addresses the request
to that name and then announces, over and over, that it is waiting.

**Signature:**

```console
$ kubectl -n nfs-lab describe pvc data | sed -n '/Events:/,$p'
Events:
  Type    Reason                Age               From                         Message
  ----    ------                ----              ----                         -------
  Normal  ExternalProvisioning  1s (x3 over 31s)  persistentvolume-controller  Waiting for a volume to be created either by
                                                                              the external provisioner
                                                                              'k8s-sigs.io/nfs-subdir-external-provisioner' ...

$ kubectl -n nfs-lab get events --field-selector \
    involvedObject.kind=PersistentVolumeClaim,type=Warning --no-headers | wc -l
0

$ kubectl get sc nfs-client -o jsonpath='{.provisioner}{"\n"}'
k8s-sigs.io/nfs-subdir-external-provisioner

$ kubectl get pods -A | grep -i nfs-subdir     # → nothing
```

**Confirm:** zero `Warning` events, one `Normal ExternalProvisioning` whose
message names a provisioner, and no Pod anywhere in the cluster implementing
that name. The absence of the Pod is the proof.

**Fix:** deploy the provisioner, with a `--provisioner` flag that matches the
StorageClass exactly.

**Why it looks like "no information":** the controller has nothing to complain
about. It did its job — it read the StorageClass, resolved the provisioner name
and published the request. There is no failure to report, so there is no
`Warning`. What it *can* say is who it is waiting for, and it says exactly
that. The name you need is sitting in a `Normal` event that most people skim
past.

### B2. The provisioner is deployed but cannot start

The pod exists, so the request *has* a target — but the target is stuck before
it can serve. Look at the pod, not the claim:

```console
$ kubectl -n nfs-lab get pods
nfs-client-provisioner-6b6b86dc4-bl96s   0/1   ContainerCreating   4m

$ kubectl -n nfs-lab describe pod -l app=nfs-client-provisioner | sed -n '/Events:/,$p'
  Warning  FailedMount  ...  MountVolume.SetUp failed for volume "nfs-client-root" : mount failed: exit status 32
  Output: mount.nfs: Connection timed out
```

Common sub-cases:

| Pod state | Look at | Likely cause |
|---|---|---|
| `ContainerCreating` | pod events | its own volume cannot mount (see `docs/error-reference.md`) |
| `CrashLoopBackOff` | pod logs | bad `--provisioner` flag, missing RBAC, wrong server |
| `Pending` | `describe pod` | no node can run it — resources, nodeSelector, taints |
| `Running` but no help | logs | leader-election RBAC missing, so it never acts |

**Fix:** fix the pod. It is a workload like any other; the claim cannot be
answered by a provisioner that is not healthy.

### B3. volumeBindingMode WaitForFirstConsumer

This one is not a bug, and it is the most common false alarm in the field.

```console
$ kubectl get sc nfs-client -o jsonpath='{.volumeBindingMode}{"\n"}'
WaitForFirstConsumer

$ kubectl -n app get pods
No resources found.        # ← no consumer, so nothing is triggered
```

**Why it exists:** the provisioner may need to know *where* the volume will be
used before it can create it — which zone, which node, which topology segment.
So it waits for a Pod to be scheduled, then provisions for that node.

**Confirm:** `Pending` **and** `volumeBindingMode: WaitForFirstConsumer`
**and** no Pod consuming the claim. All three together mean "working as
designed".

**Fix:** none. Create the workload. If you genuinely need the volume before any
Pod exists, switch the class to `Immediate` (that field is immutable — you need
a new StorageClass).

### B4. The consumer pod is the problem

With `WaitForFirstConsumer`, a Pod that cannot be scheduled means the volume is
never provisioned, so the claim stays `Pending` and the *real* error is on the
Pod:

```console
$ kubectl -n app describe pod web | grep -A3 Events
  Warning  FailedScheduling  ...  0/3 nodes are available:
    2 Insufficient memory, 1 node(s) had untolerated taint {dedicated: db}
```

**Fix:** fix the scheduling problem. The storage will follow.

### B5. Static provisioning with a PV that does not match

No provisioner involved. You created a PersistentVolume by hand and the claim
will not bind to it. The binder matches on a strict set of fields:

| Field | Must match |
|---|---|
| `spec.accessModes` | the PV must offer **at least** what the claim requests |
| `spec.capacity.storage` | the PV must be **≥** the request |
| `spec.storageClassName` | both must name the same class, or both be empty |
| `spec.volumeMode` | `Filesystem` vs `Block` |
| `spec.selector` | if the claim has one, the PV labels must satisfy it |
| `status.phase` | the PV must be `Available`, not `Released`, `Failed` or `Bound` |

**Confirm:**

```bash
kubectl get pv -o custom-columns=\
NAME:.metadata.name,CLASS:.spec.storageClassName,CAP:.spec.capacity.storage,\
MODE:.spec.accessModes,VMODE:.spec.volumeMode,STATUS:.status.phase
kubectl -n <ns> get pvc <name> -o yaml | grep -A6 'spec:'
```

With `storageClassName: ""` on both sides, expect a single `Normal` event
rather than an error — the binder did not refuse anything, it just found no
pair:

```console
  Type    Reason         Age   From                         Message
  ----    ------         ----  ----                         -------
  Normal  FailedBinding  7s    persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

**Common traps:**

- a claim asking `RWX` while the hand-made PV offers only `RWO`
- `storageClassName: ""` on the claim vs `nfs-client` on the PV — `""` means
  "no class", which is *not* the same as "any class"
- a PV left in `Released` after its previous claim was deleted, with a
  `reclaimPolicy: Retain` that keeps it unusable until you clear
  `spec.claimRef`

### B6. Topology and node affinity

The PV was created for a node or zone that no longer exists, or the claim
carries `volume.kubernetes.io/selected-node` for a node that went away. The
binder will not bind it to anything else.

**Confirm:**

```bash
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeAffinity}{"\n"}{end}'
kubectl -n <ns> get pvc <name> -o jsonpath='{.metadata.annotations}{"\n"}'
```

**Fix:** delete and recreate the volume for the current topology, or remove the
stale `selected-node` annotation.

---

## Decision tree

```
PVC is Pending
│
├─ Are there Warning events on the claim?
│  │
│  ├─ YES → the request was refused. Read the reason.
│  │        "not found"           → A1: StorageClass missing
│  │        "no default class"    → A2: no default StorageClass
│  │        "unsupported access"  → A3: RWX on block storage
│  │        "exceeded quota"      → A4: quota / max size
│  │        "failed to provision" → A5: read the provisioner's logs
│  │
│  └─ NO → nothing refused it. Look at the Normal events instead:
│          │
│          ├─ Normal ExternalProvisioning naming a provisioner?
│          │   └─ does a Pod implement that name?
│          │       ├─ NO  → B1: nobody is listening. Deploy it.   ← scenario 01
│          │       └─ YES → is it Running and Ready?
│          │                ├─ NO  → B2: fix the provisioner Pod
│          │                └─ YES → check its logs; usually RBAC or leader election
│          │
│          ├─ volumeBindingMode == WaitForFirstConsumer?
│          │   └─ any consumer Pod?  NO → B3: working as designed. Create the workload.
│          │                          YES → B4: the Pod cannot schedule. Fix the Pod.
│          │
│          └─ is a hand-made PV involved?  → B5/B6: it does not match, or wrong topology
```

---

## Production notes

- **Alert on "a claim has been Pending for longer than X"**, not just on
  failing pods. A missing provisioner takes storage down cluster-wide while
  every dashboard stays green.
- **The provisioner is a single point of failure for all new volumes.** If it
  runs `replicas: 1` and that replica is evicted onto a broken node, every new
  PVC hangs. Run two replicas with leader election and a PodDisruptionBudget.
- **Pin the provisioner version.** An upgraded provisioner that changes its
  provisioner name silently orphans every StorageClass pointing at the old
  name.
- **For NFS specifically:** `ReadWriteMany` is why you are here, so also plan
  for what NFS does not give you — no fencing, no POSIX locking guarantees
  across all clients, and a network dependency in the write path. See
  [nfs-in-kubernetes.md](nfs-in-kubernetes.md#what-nfs-does-not-give-you).
