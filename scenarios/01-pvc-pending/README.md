# Scenario 01 — the PVC that stays `Pending`

**Difficulty:** intermediate · **Time:** ~15 minutes · **Read-only diagnosis first**

---

## 1. The symptom

You deploy a claim and a workload that uses it. The workload never starts:

```console
$ kubectl -n nfs-lab get pvc,po
NAME                         STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/data   Pending                                      nfs-client     5m

NAME                                         READY   STATUS    RESTARTS   AGE
pod/nfs-server-99669d86f-4zcbd               1/1     Running   0          5m
pod/writer-db6768677-m2ztq                   0/1     Pending   0          5m
```

The claim has been `Pending` for five minutes and it will be `Pending` for
five days. Nothing is retrying in any way you can see. Nothing is failing.

`kubectl describe pvc` — the command everyone reaches for first — says this:

```console
$ kubectl -n nfs-lab describe pvc data
...
Status:        Pending
Volume:
Labels:        app.kubernetes.io/part-of=nfs-storage-lab
Annotations:   <none>
Finalizers:    [kubernetes.io/pvc-protection]
Capacity:
Access Modes:  ReadWriteMany
VolumeMode:    Filesystem
Used By:       writer-db6768677-m2ztq
Events:
  Type    Reason                Age               From                         Message
  ----    ------                ----              ----                         -------
  Normal  ExternalProvisioning  1s (x3 over 31s)  persistentvolume-controller  Waiting for a volume to be created either by
                                                                              the external provisioner
                                                                              'k8s-sigs.io/nfs-subdir-external-provisioner'
                                                                              or manually by the system administrator. If
                                                                              volume creation is delayed, please verify that
                                                                              the provisioner is running and correctly registered.
```

Read that event proportionally. It says **`Normal`** — so it is not an error,
and most people skim straight past it looking for the `Warning` that must be
hiding somewhere.

There is no `Warning`. That is not "no information" — it is the information:

- **Nothing refused this claim.** A refusal — an unsupported access mode, a
  missing StorageClass, a quota breach — always arrives as a `Warning` with a
  reason. A claim with zero `Warning` events has not been rejected.
- **Kubernetes is telling you exactly who it is waiting for**, by name:
  `k8s-sigs.io/nfs-subdir-external-provisioner`. The event even tells you what
  to do with that name: *"please verify that the provisioner is running and
  correctly registered"*.

So the diagnosis is not hidden. It is written down, in the only event there is,
and it is easy to dismiss because it is `Normal`.

## 2. What is actually happening

A PersistentVolumeClaim does not provision anything. It is a **request**, and
something else has to answer it. There are only two things that can:

1. **A human**, by creating a matching PersistentVolume by hand — *static
   provisioning*.
2. **An external provisioner** — a program running somewhere in the cluster
   that watches for claims, creates a PersistentVolume, and mounts the storage
   so that a Pod can use it — *dynamic provisioning*.

The StorageClass names which provisioner is responsible:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
```

That `provisioner` string is not decoration. It is a **name that a program has
to claim**. The volume controller reads it, addresses the request to that name,
and then reports that it is waiting:

> `Normal ExternalProvisioning … Waiting for a volume to be created either by
> the external provisioner 'k8s-sigs.io/nfs-subdir-external-provisioner' …`

That is the state you are looking at. The request is queued and addressed; the
addressee does not exist. Nothing has failed, so nothing produces a `Warning`;
the controller simply keeps announcing who it is waiting for.

This is the difference between *"I asked and was refused"* and *"I asked and
there is nobody there"*. Kubernetes tells you which one it is — and only the
first kind looks like an error, which is exactly why the second kind wastes an
afternoon.

In this scenario the NFS server is running. The StorageClass is valid. The
claim is valid. The one thing missing is the program that would have answered.

## 3. Reproduce

```bash
make doctor    # make sure the host can do NFS at all, otherwise this gets confusing
make up
```

`make up` deploys the namespace, the in-cluster NFS server, the StorageClass,
the claim and the writing workload. It deliberately does **not** deploy the
provisioner. That is the bug.

```console
$ make up
...
persistentvolumeclaim/data created
deployment.apps/writer created

the claim should now be Pending, with no provisioner to satisfy it:
NAME                         STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/data   Pending                                      nfs-client
```

## 4. Diagnosis

`make diagnose` runs all of this in one go. Walk through it manually the first
time — the order matters and so does the reasoning at each step.

### Step 1 — confirm the symptom, and read the events properly

```console
$ kubectl -n nfs-lab get pvc data
NAME   STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data   Pending                                      nfs-client     3m

$ kubectl -n nfs-lab get events --field-selector involvedObject.kind=PersistentVolumeClaim \
    -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message
TYPE     REASON                 MESSAGE
Normal   ExternalProvisioning   Waiting for a volume to be created either by the external provisioner 'k8s-sigs.io/nfs-subdir-external-provisioner' or manually by the system administrator. ...

$ kubectl -n nfs-lab get events --field-selector 'involvedObject.kind=PersistentVolumeClaim,type=Warning' --no-headers | wc -l
0
```

**What it tells you:** there are **no `Warning` events**, so nothing refused
this claim. The one event there is is `Normal`, and it names the provisioner
Kubernetes is waiting for. That message is a pointer, not a failure — it is
telling you who should have answered.

### Step 2 — confirm a Pod actually wants the volume

```console
$ kubectl -n nfs-lab describe pvc data | grep 'Used By'
Used By:       writer-db6768677-m2ztq
```

If nothing references the claim, `Pending` may be entirely expected. Always
check that something is waiting on it before you go hunting for a bug.

### Step 3 — find out who is supposed to answer

```console
$ kubectl get sc nfs-client -o jsonpath='{.provisioner}{"\n"}'
k8s-sigs.io/nfs-subdir-external-provisioner
```

**This is the name of the program you are looking for.** Everything from here
is about finding it, or proving it does not exist.

### Step 4 — is a consumer waiting on a different condition?

```console
$ kubectl get sc nfs-client -o jsonpath='{.volumeBindingMode}{"\n"}'
Immediate
```

If this said `WaitForFirstConsumer`, the claim would be *supposed* to sit
`Pending` until a Pod is scheduled, and nothing would be broken. That is the
single most common false positive in this whole area, so check it before you
change anything. See
[docs/pvc-pending-playbook.md](../../docs/pvc-pending-playbook.md#b3-volumebindingmode-waitforfirstconsumer).

### Step 5 — the decisive question: does that program exist?

```console
$ kubectl -n nfs-lab get pods
NAME                             READY   STATUS    RESTARTS   AGE
nfs-server-99669d86f-4zcbd       1/1     Running   0          6m
writer-db6768677-m2ztq           0/1     Pending   0          6m
```

There is an NFS server and a waiting application. There is **no provisioner**.
Search cluster-wide before concluding, because provisioners are often
installed in their own namespace, not next to the workloads:

```console
$ kubectl get pods -A | grep -i nfs
nfs-lab      nfs-server-99669d86f-4zcbd   1/1   Running   0   6m
```

Two pods, and neither of them is `nfs-client-provisioner`.

### Step 6 — close the loop

```console
$ kubectl get pv
No resources found.
```

The claim is `Pending`, no PersistentVolume exists, the StorageClass names a
provisioner, and no Pod implements it. The chain is broken at exactly one link,
and it is a link that was never installed.

## 5. Root cause

**The external provisioner for `k8s-sigs.io/nfs-subdir-external-provisioner`
was never deployed.**

Kubernetes has no built-in NFS provisioner. Unlike AWS EBS, GCE PD or Cinder,
NFS is not a first-class volume type that the cloud controller can create on
demand. Dynamic NFS provisioning means *somebody has to run a program that does
it*, and in this lab that program is
[`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner).

Because the StorageClass exists and is valid, Kubernetes is behaving exactly as
designed: it addresses the request to that provisioner name and periodically
announces that it is waiting. The `Pending` is not an error. It is a request
that is still unanswered, and Kubernetes has already told you who it expects to
answer it.

## 6. The fix

Deploy the provisioner:

```bash
make fix
# equivalent to:
kubectl apply -f scenarios/01-pvc-pending/manifests/provisioner.yaml
```

The manifest contains three things, and all three are necessary:

```yaml
# 1. identity: the name must match the StorageClass, byte for byte
args:
  - --provisioner=k8s-sigs.io/nfs-subdir-external-provisioner

# 2. where the share lives
env:
  - name: NFS_SERVER
    value: nfs-server.nfs-lab.svc.cluster.local
  - name: NFS_PATH
    value: /

# 3. permission to mount
securityContext:
  privileged: true
```

Plus the RBAC without which it can watch but never create: `get/list/watch/
create/delete` on `persistentvolumes`, `update` on `persistentvolumeclaims`,
and `create/update/patch` on `events`.

### Two details that are easy to get wrong

**`NFS_PATH` is `/`, not `/nfsshare`.** The server's `/etc/exports` is generated
with `fsid=0`:

```
/nfsshare *(rw,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)
```

`fsid=0` designates that export as the **root of the NFSv4 pseudo-filesystem**.
A v4 client therefore mounts `<server>:/` and sees the contents of
`/nfsshare`. Writing `NFS_PATH=/nfsshare` looks sensible and fails, because
from the client's point of view there is no such export.

**`mountOptions: nfsvers=4.1` is required.** The server is started with
`rpc.nfsd --no-nfs-version 2 --no-nfs-version 3`, so it speaks NFSv4 only. If
the client tries to negotiate v3 it will be refused, and the error will be
about the server, not about the version, which sends you looking in the wrong
place.

### If the provisioner starts but never becomes Ready

That is the second half of this scenario, and it is a different bug. See
[section 8](#8-when-the-provisioner-exists-but-still-fails).

## 7. Verification

```bash
make verify
```

`verify.sh` asserts the whole chain, not just the claim:

```console
$ make verify
== expecting the fixed state ==
  ok   PVC phase (Bound)
  ok   a PV exists with an nfs source (1)
  ok   the PV points at the in-cluster server (1)
  ok   provisioner pod Running (Running)
  ok   writer pod Running (Running)
  ok   writer has appended 4 line(s) to the shared volume

passed: 6   failed: 0
```

Manually, the interesting parts are:

```console
$ kubectl -n nfs-lab get pvc
NAME   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data   Bound    pvc-3b1f8e2a-...                            1Gi        RWX            nfs-client

$ kubectl get pv -o custom-columns=NAME:.metadata.name,SERVER:.spec.nfs.server,PATH:.spec.nfs.path
NAME                                       SERVER                                    PATH
pvc-3b1f8e2a-...                           nfs-server.nfs-lab.svc.cluster.local      /
```

A PersistentVolume now exists and its source is `nfs` — that is the provisioner
having done its job.

Finally, prove the data is really on the share:

```console
$ kubectl -n nfs-lab exec deploy/writer -- cat /data/heartbeat
Fri Oct  9 11:41:02 UTC 2026
Fri Oct  9 11:41:12 UTC 2026
```

Because the volume is `ReadWriteMany`, this works from several Pods at once —
which is the reason to choose NFS in the first place. Add a second replica and
watch both writers append to the same file:

```bash
kubectl -n nfs-lab scale deploy/writer --replicas=3
kubectl -n nfs-lab exec deploy/writer -- tail -n 5 /data/heartbeat
```

## 8. When the provisioner exists but still fails

Deploying the provisioner is not always enough. It has its own NFS volume, and
if the kubelet cannot mount *that*, the provisioner pod never starts — so from
the outside the symptom is unchanged: the claim is still `Pending`.

```console
$ kubectl -n nfs-lab get pods
NAME                                          READY   STATUS              RESTARTS   AGE
nfs-client-provisioner-6b6b86dc4-bl96s        0/1     ContainerCreating   0          4m

$ kubectl -n nfs-lab describe pod -l app=nfs-client-provisioner | sed -n '/Events:/,$p'
  Warning  FailedMount  25s (x2 over 2m26s)  kubelet
  MountVolume.SetUp failed for volume "nfs-client-root" : mount failed: exit status 32
  Mounting command: mount
  Mounting arguments:  -t nfs nfs-server.nfs-lab.svc.cluster.local:/ /var/lib/kubelet/pods/.../volumes/kubernetes.io~nfs/nfs-client-root
  Output: mount.nfs: Resource temporarily unavailable
```

### Reading that error

`MountVolume.SetUp failed` comes from the **kubelet**, which is the component
that actually performs mounts. The application never saw anything. This is the
signature of a kernel-level problem, and the `Output:` line is the real message.

| `Output:` | Means | Fix |
|---|---|---|
| `mount.nfs: Resource temporarily unavailable` | the node cannot mount NFS — either the kernel has no NFS client support, or the node's `nfs-utils` cannot talk to its kernel | see the note below; start with `sudo modprobe nfs nfsv3 nfsv4 nfsd` on the host |
| `mount.nfs: failed to apply fstab options` | the node's `mount.nfs` failed before reaching any server — the userspace/kernel mismatch, seen when running the mount by hand on the node | fix the node image; no manifest change helps |
| `mount.nfs: Connection timed out` | the server is unreachable: wrong name, wrong port, NetworkPolicy, or the server pod is not listening | check the Service, `kubectl -n nfs-lab get endpoints nfs-server`, and the server's own logs |
| `mount.nfs: access denied by server while mounting` | the server refused this client: `/etc/exports` does not permit it | fix the export's client list (`PERMITTED`) |
| `mount.nfs: No such file or directory` | the export path does not exist on the server (very common with `fsid=0`, where the path must be `/`) | use `/` for a v4 export with `fsid=0` |

### The trap inside that first row

`Resource temporarily unavailable` has two causes, and the obvious way to test
for it gives the wrong answer.

A privileged Pod can mount NFS while the kubelet still cannot — the Pod ships
its own `mount.nfs` inside its image, and the kubelet uses the node's. So this
looks like a working cluster:

```console
$ kubectl run p --rm -i --restart=never --image=itsthenetwork/nfs-server-alpine:12 \
    --overrides='...privileged...' -- sh -c 'mount -t nfs nfs-server.nfs-lab.svc.cluster.local:/ /m && echo MOUNT OK'
MOUNT OK                       # <- proves nothing
```

while every NFS volume in the cluster stays unmounted. **Validate the kubelet's
path, not a Pod's:**

```bash
make doctor
```

If it reports that the kubelet cannot mount NFS while the kernel is fine, the
node's userspace is the problem, and no manifest you write will fix it.

To reproduce the unreachable-server variant deliberately:

```bash
make fix-wrong     # applies provisioner-wrong-server.yaml
kubectl -n nfs-lab describe pod -l app=nfs-client-provisioner | sed -n '/Events:/,$p'
```

`make clean && make up && make fix` restores the good path.

## 9. Why it is designed this way

It is fair to ask why Kubernetes does not just do this itself.

- **NFS is not a cloud API.** There is nothing to call. A directory appears on
  a server once somebody creates it. Kubernetes cannot invent that, so it
  delegates: anything that can be scripted can be a provisioner, which is why
  the same interface covers Ceph, ZFS, GlusterFS, Longhorn, S3 gateways and a
  thousand in-house systems.
- **`Pending` is not `Error`.** A claim is a long-lived request that may be
  satisfied minutes or hours later — when the provisioner is installed, when
  nodes free up, when a human binds a PV. Marking it Failed would be wrong. The
  cost of that correctness is the silence you just debugged.
- **The provisioner is a workload like any other.** It can be deleted, evicted,
  OOM-killed or scheduled onto a broken node, and when it is, storage stops
  working without any other symptom. **This is worth an alert in production.**
  You are one `kubectl delete` away from every new PVC in the cluster hanging.

## 10. Lessons

1. **A `Normal` event is still information.** The `ExternalProvisioning`
   message names the exact component Kubernetes is waiting for. Reading
   "Normal" as "nothing to see" is what turns a two-minute fix into an
   afternoon.
2. **The absence of `Warning` events is a positive signal.** It means the
   request was never refused — a different problem from one that failed, and a
   much narrower place to look.
3. **A StorageClass is a contract, not an implementation.** It points at a
   provisioner by name; the name has meaning only if something registers it.
4. **Check `volumeBindingMode` before you debug anything.** `WaitForFirstConsumer`
   makes `Pending` correct behaviour.
5. **Provisioners live outside the namespace you are looking at.** Always
   `kubectl get pods -A` before declaring something missing.
6. **Storage failures surface as kubelet events**, because mounting is the
   kubelet's job. Look at the *Pod's* events even when the problem is with a
   *PVC*.
7. **The kernel is part of your cluster.** A correct manifest can still fail
   because a module is not loaded on the host.

---

**Read next:** [docs/pvc-pending-playbook.md](../../docs/pvc-pending-playbook.md)
for every other reason a claim can stay `Pending`.
