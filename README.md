# Kubernetes NFS Storage Lab

A hands-on lab for the failure everybody hits once and then never forgets:
**a PersistentVolumeClaim that stays `Pending` and nobody can tell you why.**

This lab gives you a real NFS server inside the cluster, a StorageClass that
depends on an external provisioner, and a claim that does not bind. You will
learn to tell apart four very different situations that all look identical on
the surface:

- the provisioner does not exist
- the provisioner exists but cannot reach the NFS server
- the node kernel cannot mount NFS at all
- nothing is actually broken — the claim is waiting for a consumer Pod

Each one produces `Pending`. Each one needs a different fix. The point of this
lab is that `Pending` is a symptom, not a diagnosis.

> Read-only first. Every diagnostic script here only reads from the cluster.

---

## What you will learn

- What a StorageClass `provisioner` field really means and who satisfies it
- The difference between static PersistentVolumes and dynamic provisioning
- Why a `Pending` claim carries **no error at all** — only a `Normal` event
  naming the component that was supposed to answer it, which is easy to read
  past and is the whole diagnosis
- What `volumeBindingMode: Immediate` vs `WaitForFirstConsumer` changes
- Where NFS mounts actually happen (the kernel, not Kubernetes) and why that
  produces kubelet errors instead of application errors
- How to read a provisioner's own mount failure from kubelet events
- Why NFS is the one storage type that gives you real `ReadWriteMany`
- How `fsid=0` turns an export into the root of the NFSv4 pseudo-filesystem,
  and why that makes the mount path look "wrong"

## Prerequisites

| Requirement | Why |
|---|---|
| A Kubernetes cluster (1 node is enough) | [minikube](https://minikube.sigs.k8s.io/), [kind](https://kind.sigs.k8s.io/), k3s, anything |
| `kubectl`, `make` | driving the lab |
| **NFS client + server modules in the host kernel** | see below — this is the one that bites |

NFS is not implemented inside Kubernetes. It is a kernel filesystem. The
kubelet asks the kernel to mount a share, and if the node cannot, the mount
fails and you get a **kubelet** error, not an application error. That is the
single most confusing thing about this scenario, so the lab starts by checking
it:

```bash
make doctor
```

Two separate things have to work, and **`make doctor` checks the second one**:

1. the **kernel** must support NFS;
2. the **node's userspace** (`mount.nfs`, from `nfs-utils`) must be able to talk
   to that kernel.

A privileged Pod can mount NFS while the kubelet cannot — the Pod brings its
own `mount.nfs` from its image, the kubelet uses the node's. So a successful
mount in a debug Pod proves nothing. The check above mounts the way the kubelet
does, because that is the only path that matters.

If the check fails, load the modules **on the host** (not in Kubernetes):

```bash
sudo modprobe nfs nfsv3 nfsv4 nfsd

# make it survive a reboot
echo -e 'nfs\nnfsv3\nnfsv4\nnfsd' | sudo tee /etc/modules-load.d/nfs.conf
```

Notes for the common local setups:

- **minikube, docker driver** — the node container shares the host kernel, so
  loading the module on the host is enough. No cluster restart needed.
- **minikube, other drivers** — same idea: load the module inside the VM
  (`minikube ssh -- sudo modprobe nfs nfsd`).
- **kind** — the node containers share the host kernel, so the host module
  matters. `nfsd` is usually auto-loaded when the server pod starts.
- **WSL2** — the kernel Microsoft ships does include NFS, but Docker Desktop's
  VM is what really needs it. If mounts fail there, use a Linux host or a VM.

If the kernel is fine and mounts still fail, the node's `nfs-utils` is the
suspect. Recreate the node (`minikube delete && minikube start`) or run the lab
somewhere with a matching kernel and userspace. See
[docs/nfs-in-kubernetes.md](docs/nfs-in-kubernetes.md#it-is-not-only-the-kernel-the-kubelets-userspace-matters-too).

## Quick start

```bash
make doctor        # can this machine mount NFS at all?
make up            # deploy the broken state: a claim that never binds
make diagnose      # collect the evidence, print a verdict
make verify-broken # assert the broken state
make fix           # deploy the provisioner
make verify        # assert the recovered state
make clean         # remove everything
```

## Scenarios

| # | Scenario | Teaches |
|---|---|---|
| [01](scenarios/01-pvc-pending/) | PVC stuck in `Pending` | missing external provisioner, and every other reason a claim never binds |

## Guides

| Document | Contents |
|---|---|
| [docs/pvc-pending-playbook.md](docs/pvc-pending-playbook.md) | every reason a PVC stays `Pending`, and how to tell them apart |
| [docs/nfs-in-kubernetes.md](docs/nfs-in-kubernetes.md) | how NFS actually works under Kubernetes: static vs dynamic, NFSv4, `fsid=0`, `ReadWriteMany` |
| [docs/command-reference.md](docs/command-reference.md) | the commands to run, and what each one tells you |
| [docs/error-reference.md](docs/error-reference.md) | the error strings you will see, and what each one means |

## Repository layout

```
.
├── Makefile
├── scripts/
│   └── doctor.sh                  # host prerequisite check
├── docs/                          # the reasoning, not tied to one scenario
└── scenarios/
    └── 01-pvc-pending/
        ├── README.md              # the walkthrough
        ├── diagnose.sh            # read-only evidence collection
        ├── verify.sh              # asserts broken / fixed
        └── manifests/
            ├── namespace.yaml
            ├── nfs-server.yaml            # NFSv4 server, in-cluster
            ├── storageclass.yaml          # the class that needs a provisioner
            ├── pvc.yaml                   # the claim that never binds
            ├── app.yaml                   # proof that it eventually works
            ├── provisioner.yaml           # the missing piece
            └── provisioner-wrong-server.yaml
```

## Cleanup

```bash
make clean
```

This deletes the `nfs-lab` namespace, the `nfs-client` StorageClass and the two
cluster-scoped RBAC objects the provisioner needs.

## What is verified

The scenario is tested rather than asserted. On every push, against a real
cluster:

- **the broken state is asserted** — the claim is `Pending`, it has **zero
  `Warning` events**, and the `ExternalProvisioning` event names a provisioner
  that no Pod implements;
- **every manifest is validated** against the Kubernetes schemas and accepted
  by a real API server;
- **the diagnosis script** runs cleanly and prints the correct verdict.

The **recovery path** — deploy the provisioner, the claim binds, the writer
reads and writes the share — additionally requires the node's kubelet to be
able to mount NFS. That is a property of the environment, not of this
repository, which is why `make doctor` checks it up front and explains what to
do when it fails.

Some node images cannot mount NFS at all (kind's ships no `nfs-utils`; some
minikube images ship one that does not match the host kernel). A VM-backed node
or a managed cluster can. The lab is worth reading either way — the diagnosis
is the point, and it is verified everywhere.

## License

[Apache-2.0](LICENSE)
