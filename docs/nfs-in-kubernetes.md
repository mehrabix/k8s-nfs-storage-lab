# NFS in Kubernetes

How NFS really works under Kubernetes: what mounts it, what can go wrong, and
why the errors show up in places you would not expect.

---

## Why NFS is still here

Almost every managed block storage product gives you `ReadWriteOnce`: one node
attaches the volume, one Pod writes to it. That is fine until two Pods need the
same files at the same time.

NFS gives you `ReadWriteMany` from the start. No attach/detach, no zone
affinity, no waiting for a volume to detach from a dead node. That property —
and the fact that a shared directory is often exactly what a legacy or
stateful application wants — is why NFS survives every attempt to replace it.

The cost is that NFS is a **network filesystem**, and everything interesting
about it happens outside Kubernetes.

## Who actually performs a mount

This is the part that confuses people, and it explains the error messages.

```
PVC            → a request, handled by the persistent volume controller
Provisioner    → a program that creates a PV; it does not mount anything for you
Pod            → declares a volume
Kubelet        → ON THE NODE, performs the mount   ← errors are born here
Kernel         → must support the filesystem; otherwise nothing mounts
```

When a mount fails, the failure is reported as a **kubelet event on the Pod**,
and the application logs contain nothing at all. The application never started.
So: when storage breaks, read the *Pod's* events even when the problem is with
a *PVC*, and remember that the mount syscall is the kernel's job.

### The kernel requirement, with evidence

NFS is a kernel filesystem. If the module is not available on the host that
runs your nodes, a perfectly valid manifest produces this:

```console
$ kubectl -n nfs-lab describe pod -l app=nfs-client-provisioner | sed -n '/Events:/,$p'
  Warning  FailedMount  ...  MountVolume.SetUp failed for volume "nfs-client-root" : mount failed: exit status 32
  Mounting command: mount
  Mounting arguments:  -t nfs nfs-server.nfs-lab.svc.cluster.local:/ /var/lib/kubelet/pods/.../volumes/kubernetes.io~nfs/nfs-client-root
  Output: mount.nfs: Resource temporarily unavailable
```

`mount.nfs: Resource temporarily unavailable` is the shape of "the kernel has
no NFS filesystem to hand this request to". The fix is on the host, not in
Kubernetes:

```bash
sudo modprobe nfs nfsv3 nfsv4 nfsd
echo -e 'nfs\nnfsv3\nnfsv4\nnfsd' | sudo tee /etc/modules-load.d/nfs.conf
```

`make doctor` checks this for you before you waste time debugging YAML.

Two asymmetries worth knowing:

- The **`nfsd`** module (server side) is often auto-loaded when a privileged
  container starts `rpc.nfsd`. The **`nfs`** module (client side) is not, until
  something tries to mount. So a cluster can successfully *serve* NFS while
  being unable to *mount* it.
- On minikube with the docker driver, and on kind, the node containers share
  the host kernel. Loading the module on the host is enough; there is nothing
  to do inside Kubernetes.

## Static vs dynamic provisioning

### Static — you make the PersistentVolume yourself

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-data
spec:
  capacity:
    storage: 5Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-manual
  mountOptions:
    - nfsvers=4.1
  nfs:
    server: nfs-server.nfs-lab.svc.cluster.local
    path: /
```

The claim must match on class, access modes, capacity and volume mode. If it
does not, the binder simply has no pair for it, and reports that as a `Normal`
event rather than a failure:

```console
$ kubectl -n pvtest2 describe pvc wants-rwx | sed -n '/^Events:/,$p'
  Type    Reason         Age   From                         Message
  ----    ------         ----  ----                         -------
  Normal  FailedBinding  7s    persistentvolume-controller  no persistent volumes available for this claim and no storage class is set

$ kubectl get pv pvtest2-rwo
NAME           CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM
pvtest2-rwo    1Gi        RWO            Retain           Available
```

Note that the PV is still `Available` and the claim is still `Pending`: nothing
was refused, the two were just never introduced. See
[the playbook](pvc-pending-playbook.md#b5-static-provisioning-with-a-pv-that-does-not-match).

Useful for a single fixed share. Painful past about three of them.

### Dynamic — a provisioner creates the PV

The StorageClass points at a provisioner by name, and the provisioner creates
one PersistentVolume per claim, usually as a subdirectory of one big export:

```
/nfsshare/
├── nfs-lab-data/          ← created because a claim appeared
└── app-uploads/           ← and another
```

Subdirectories are the whole idea behind `nfs-subdir-external-provisioner`: one
NFS share, many claims, each in its own directory, with `archiveOnDelete`
deciding whether that directory is renamed on delete or left alone.

**The provisioner is a workload.** It can be deleted, evicted or OOM-killed,
and when it is, storage stops working with no other symptom. Treat it as
infrastructure, not as a helper: two replicas, a PodDisruptionBudget, and an
alert.

## NFS versions and ports

| Version | Ports needed | Notes |
|---|---|---|
| v3 | 2049 **plus** rpcbind/111 **plus** mountd/20048 | helper protocols make it firewall-hostile and fragile through Services |
| v4 | **2049 only** | modern, stateless, no rpcbind or mountd needed for the data path |

This lab's server runs NFSv4 only:

```
/usr/sbin/rpc.nfsd --no-udp --no-nfs-version 2 --no-nfs-version 3
```

If the client tries to negotiate v3 it will be refused, so the StorageClass
pins the version:

```yaml
mountOptions:
  - nfsvers=4.1
```

Useful client options:

| Option | Effect |
|---|---|
| `nfsvers=4.1` | pin the protocol version |
| `hard` / `soft` | retry forever vs give up with an error (default `hard`) |
| `timeo=`, `retrans=` | timeouts and retries |
| `nolock` | disable NFS locking — some applications need it when lockd is unreachable |

## `fsid=0` and why the path is `/`

An export line is not just a directory — it is a *tree with a root*. `fsid=0`
marks an export as that root:

```
/nfsshare *(rw,fsid=0,async,no_subtree_check,no_auth_nlm,insecure,no_root_squash)
```

For an NFSv4 client there is one pseudo-filesystem and its root is that export.
So the client mounts:

```yaml
nfs:
  server: nfs-server.nfs-lab.svc.cluster.local
  path: /
```

and lands inside `/nfsshare`. Writing `path: /nfsshare` looks correct, matches
what the server literally exports, and fails with *"No such file or directory"*
— because from the client's point of view there is no `/nfsshare`; there is
only `/`.

**Rule of thumb:** with `fsid=0`, the mount path is `/`. Without it, the path is
the directory as written in `/etc/exports`.

## Export options that decide whether writes work

The second classic NFS failure is not a mount failure at all: the volume mounts
cleanly and the application gets `Permission denied`.

| Option | Meaning | Consequence |
|---|---|---|
| `root_squash` (default) | map UID 0 on the client to `nobody` on the server | a container running as **root** cannot write, because it is not root on the server |
| `no_root_squash` | trust root | root in the container is root on the share — convenient, and a security trade-off |
| `all_squash` | map every UID to `nobody` | nothing can write unless the directory is world-writable |
| `rw` / `ro` | writable / read-only | an export that is `ro` mounts fine and fails on first write |
| `sync` / `async` | flush on every write vs buffered | `async` is faster; `sync` is safer on power loss |

So the same directory behaves completely differently depending on the
container's UID. Two fixes, in order of preference:

1. **Don't run the workload as root.** Set `runAsUser` and, on the volume,
   `fsGroup` — Kubernetes will `chown`/`chmod` the mount to the group, which is
   how you grant write access without weakening the export.
2. **Relax the export** (`no_root_squash`). Simpler, and a real risk: a
   compromised container now has root on a shared filesystem, for everyone.

This lab's server uses `no_root_squash`, which is why the writer Pod works
without extra configuration. In production, prefer option 1.

## What NFS does not give you

`ReadWriteMany` is a guarantee that **many clients can mount the same
filesystem**, not that your application is safe doing so.

- **No POSIX locking guarantees across every client.** Locking needs `lockd`;
  if it cannot reach the server, applications break in ways that look like
  application bugs. `nolock` is a workaround, not a fix.
- **No fencing.** A node that loses the network may keep writing after another
  node takes over. Nothing stops it. This is why databases do not live on NFS
  without a coordinator (Patroni, etc.).
- **No atomic rename guarantees across all server implementations.** Some
  applications — anything that writes a temp file and renames it — rely on this.
- **Latency is in the write path.** Every write is a network call. A slow or
  saturated server slows your application directly.
- **Everything shares one export's availability.** The server is a single point
  of failure for every claim pointing at it.

Use NFS for shared reads, uploads, configuration, build caches, and legacy
applications that expect a shared directory. Do not use it as the primary
storage for a database unless something above it handles coordination.

## How this lab's server is built, and its caveats

```yaml
containers:
  - name: nfs-server
    image: itsthenetwork/nfs-server-alpine:12
    env:
      - name: SHARED_DIRECTORY
        value: /nfsshare
    securityContext:
      privileged: true
```

- **`privileged: true` is required.** Running `rpc.nfsd` means managing kernel
  NFS state, which an unprivileged container cannot do. This is acceptable for
  a lab and for controlled in-cluster file sharing; it is not something to
  hand to tenants.
- **The export is an `emptyDir`.** It lives as long as the server Pod, so
  restarting the server loses the data. Swap it for a `hostPath` or a real
  volume if you care.
- **One replica.** NFS is stateless enough for a single server to be fine here,
  but there is no failover.

For real workloads use a managed NFS service (EFS, Filestore, Azure Files) or a
storage system whose own CSI driver manages this properly (CephFS, Longhorn,
NetApp Trident).
