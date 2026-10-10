# Error reference

Look up the string you are actually seeing. Errors are grouped by **where they
appear**, because that alone narrows the cause more than the text does.

| Where it appears | What it means the problem is |
|---|---|
| PVC `Events:` | the request was refused, or the provisioner failed |
| Pod `Events:` | the mount failed — a kubelet/kernel/network problem |
| Provisioner logs | the provisioner ran and something in its logic or the API failed |
| Server logs | the NFS server itself refused or errored |

---

## PVC events

### `storageclass.storage.k8s.io "x" not found`
The claim names a StorageClass that does not exist.
**Fix:** create it, or correct `spec.storageClassName` (immutable — recreate
the claim). → [playbook A1](pvc-pending-playbook.md#a1-storageclass-not-found)

### `no default StorageClass found for this claim`
The claim has no `storageClassName` and no class is marked default.
**Fix:** set the class explicitly, or annotate one with
`storageclass.kubernetes.io/is-default-class=true`. → [A2](pvc-pending-playbook.md#a2-no-default-storageclass)

### `unsupported access mode "ReadWriteMany"`
The provisioner cannot create a volume with that access mode — typical for
block storage.
**Fix:** ask for `ReadWriteOnce`, or use a provisioner that supports `RWX`
(NFS, CephFS, Longhorn, Azure Files). → [A3](pvc-pending-playbook.md#a3-unsupported-access-mode)

### `exceeded quota: <name>, requested: requests.storage=…`
A ResourceQuota caps storage in the namespace.
**Fix:** raise the quota or request less. → [A4](pvc-pending-playbook.md#a4-quota-or-capacity-refusal)

### `requested capacity is greater than the maximum allowed`
A per-volume size cap, often set by the platform.
**Fix:** request within the cap.

### `failed to provision volume with StorageClass "x": …`
Generic wrapper. **The real cause is in the provisioner's logs.** Always read
them before acting. → [A5](pvc-pending-playbook.md#a5-provisioning-failed-inside-the-provisioner)

### `Normal ExternalProvisioning` — `Waiting for a volume to be created either by the external provisioner "x" or manually by the system administrator`
**Not an error. This is the pointer.** The claim is queued and addressed to the
provisioner named `x`, and Kubernetes is announcing that it is waiting.
Expected for a few seconds; a permanent state if `x` does not exist.
**Fix:** `kubectl get pods -A | grep <x-fragment>`. If nothing implements that
name, deploy it. → [B1](pvc-pending-playbook.md#b1-no-provisioner-implements-the-storageclass)

### `Normal FailedBinding` — `no persistent volumes available for this claim and no storage class is set`
Static provisioning with no matching PV. The claim asks for something (usually
`ReadWriteMany`) that no existing `Available` PersistentVolume offers, and
because `storageClassName` is empty there is no provisioner to fall back on.
**Also `Normal`, also not a refusal** — the binder just has no pair for it.
**Fix:** create a PV that satisfies the claim, or correct the claim's access
modes / capacity / `storageClassName`. → [B5](pvc-pending-playbook.md#b5-static-provisioning-with-a-pv-that-does-not-match)

### `Events:` listing only `Normal` entries, zero `Warning`
Nothing refused this claim. That is a *positive, narrowing* statement: the
problem is a missing or unhealthy provisioner, not a rejected request. Almost
always B1 (no provisioner) or B3 (`WaitForFirstConsumer`). Do not read
`Normal` as "nothing to see" — the message names the component you are looking
for.

---

## Pod events (mount failures)

### `MountVolume.SetUp failed for volume "x" : mount failed: exit status 32`
The kubelet ran `mount` and it failed. `exit status 32` is the generic mount
failure code; **the `Output:` line below it is the actual reason.** Without the
`Output:` line you know nothing yet.

### `Output: mount.nfs: Resource temporarily unavailable`
The **node** could not mount NFS. Two very different causes produce this same
string, so test before you change any YAML:

1. the kernel has no NFS client support — fix with
   `sudo modprobe nfs nfsv3 nfsv4 nfsd` on the host, or
2. the node's userspace NFS stack is incompatible with its kernel: the module
   is loaded, `grep -w nfs /proc/filesystems` succeeds, and `mount.nfs` still
   fails.

**How to tell them apart** — mount from the node and from a privileged Pod
separately, because they use different userspace:

```bash
# the path the kubelet actually uses
minikube ssh -p <profile> -- 'sudo mount -t nfs <server>:/ /mnt'

# a privileged Pod brings its own mount.nfs from its image
kubectl run p --rm -i --restart=Never --image=itsthenetwork/nfs-server-alpine:12 \
  --overrides='{"spec":{"containers":[{"name":"p","securityContext":{"privileged":true},
  "command":["sh","-c","mkdir -p /m && mount -t nfs <server>:/ /m"]}]}}'
```

**If the Pod succeeds and the node fails, that is the diagnosis.** A Pod brings
its own `mount.nfs`; the kubelet uses the node's. **A privileged Pod that can
mount NFS is not proof that your cluster can** — check the kubelet's path with
`make doctor`. Fix the node image, not the manifests.

### `Output: mount.nfs: failed to apply fstab options`
The node's `mount.nfs` failed before it even talked to a server — the same
userspace/kernel mismatch, seen when running the mount by hand on the node. No
manifest change fixes this.

### `Output: mount.nfs: Connection timed out`
The server did not answer. Wrong hostname, wrong port, a Service with no
endpoints, a NetworkPolicy, or the server is down.
**Fix:** check `kubectl -n <ns> get endpoints <svc>` first — if it is `<none>`,
the problem is the server, not the client.

### `Output: mount.nfs: No such file or directory`
The export path does not exist **as the client sees it**.
**Very common with `fsid=0`**, where the correct path is `/`, not the directory
name written in `/etc/exports`. → [nfs-in-kubernetes.md](nfs-in-kubernetes.md#fsid0-and-why-the-path-is-)

### `Output: mount.nfs: access denied by server while mounting`
The server refused this client: `/etc/exports` does not permit the client's IP
or the `PERMITTED` list is wrong.

### `Output: mount.nfs: Protocol not supported`
Version negotiation failed — usually the client offering v3 to a v4-only server.
**Fix:** set `mountOptions: [nfsvers=4.1]` on the StorageClass.

### `FailedMount` / `MountVolume.WaitForAttach failed`
Often a volume still attached to a previous node, or a block volume in the wrong
zone. For NFS this is rare; for `ReadWriteOnce` block storage it is the standard
symptom of a node that did not detach cleanly.

### `Unable to attach or mount volumes: unmounted volumes=[data], unattached volumes=[data]: timed out waiting for the condition`
The generic "something in the volume chain never completed". Read the lines
*above* it — the specific `MountVolume.SetUp failed` entry is there.

---

## Provisioner logs

### `failed to provision volume with StorageClass "x": failed to create subdirectory`
The provisioner mounted the share but could not create the directory — usually
permissions (`root_squash` on the server vs root in the provisioner container).

### `error getting server version` / `dial tcp: i/o timeout`
The provisioner cannot reach the Kubernetes API or the NFS server.
**Fix:** check network policy, DNS, and that the server Service has endpoints.

### `leader election lost`
Another replica took over, or RBAC is missing for the lease/endpoint object.
**Fix:** check the `Role`/`RoleBinding` for `endpoints` (older provisioners)
or `leases` in `coordination.k8s.io` (newer ones).

### The pod is `Running` but the claim never binds
Usually **RBAC**: the provisioner can watch but not create. Check for
`persistentvolumes: create` and `persistentvolumeclaims: update` in its
ClusterRole, then read the logs — a forbidden list/watch shows up there.

---

## NFS server logs

### `export validation failed, exiting`
The generated `/etc/exports` is invalid — typically `SHARED_DIRECTORY` unset.
**Fix:** check the Deployment's `SHARED_DIRECTORY` env var.

### `rpc.nfsd: writing fd to kernel failed`
Usually the container is not `privileged`, so it cannot manage kernel NFS state.
**Fix:** set `securityContext.privileged: true`.

### `mount request from <ip> for <path> is not exported`
The client asked for a path the server does not export — the `fsid=0` / path
mismatch again.

---

## Kubernetes-side, not NFS-specific

| Message | Meaning |
|---|---|
| `pod has unbound immediate PersistentVolumeClaims` | normal while the claim provisions; if permanent, the claim is stuck |
| `volume is already exclusively attached to one node` | RWO volume still attached to another node |
| `ProvisioningFailed` with `context deadline exceeded` | the provisioner did not answer in time — often the provisioner is unhealthy |
| PV `Status: Released` | the claim was deleted and `reclaimPolicy: Retain` keeps the PV unusable until `spec.claimRef` is cleared |

---

## The one-line version

- **`Pending` with a `Warning`** → read it, it names the cause.
- **`Pending` with only `Normal` events** → nothing was refused. The
  `ExternalProvisioning` message names the provisioner you have to find.
- **`Pending` + `WaitForFirstConsumer` + no consumer Pod** → working as designed.
- **Mount errors** → the kernel, the network, or the export. Never the YAML.
- **`exit status 32`** → keep reading; the `Output:` line is the answer.
