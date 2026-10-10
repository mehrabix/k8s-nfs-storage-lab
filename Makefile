SCENARIO  ?= scenarios/01-pvc-pending
MANIFESTS := $(SCENARIO)/manifests
NAMESPACE ?= nfs-lab
KUBECTL   ?= kubectl

.PHONY: help
help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: doctor
doctor: ## check the host prerequisites (NFS client + nfsd)
	NS=$(NAMESPACE) ./scripts/doctor.sh

.PHONY: up
up: ## deploy the broken state (claim that never binds)
	$(KUBECTL) apply -f $(MANIFESTS)/namespace.yaml
	$(KUBECTL) apply -f $(MANIFESTS)/nfs-server.yaml
	@echo "waiting for the nfs server (this needs the host nfsd module)..."
	-$(KUBECTL) -n $(NAMESPACE) rollout status deploy/nfs-server --timeout=90s
	$(KUBECTL) apply -f $(MANIFESTS)/storageclass.yaml
	$(KUBECTL) apply -f $(MANIFESTS)/pvc.yaml
	$(KUBECTL) apply -f $(MANIFESTS)/app.yaml
	@echo
	@echo "the claim should now be Pending, with no provisioner to satisfy it:"
	-@$(KUBECTL) -n $(NAMESPACE) get pvc,po

.PHONY: fix
fix: ## deploy the provisioner: the claim binds
	$(KUBECTL) apply -f $(MANIFESTS)/provisioner.yaml
	@echo "waiting for the provisioner to start..."
	-$(KUBECTL) -n $(NAMESPACE) rollout status deploy/nfs-client-provisioner --timeout=120s

.PHONY: fix-wrong
fix-wrong: ## part 2: a provisioner pointed at a server that never answers
	$(KUBECTL) -n $(NAMESPACE) delete deploy nfs-client-provisioner --ignore-not-found
	$(KUBECTL) apply -f $(MANIFESTS)/provisioner-wrong-server.yaml

.PHONY: diagnose
diagnose: ## collect the evidence and print a verdict
	NS=$(NAMESPACE) ./$(SCENARIO)/diagnose.sh

.PHONY: verify
verify: ## assert the recovered state
	NS=$(NAMESPACE) ./$(SCENARIO)/verify.sh fixed

.PHONY: verify-broken
verify-broken: ## assert the broken state
	NS=$(NAMESPACE) ./$(SCENARIO)/verify.sh broken

.PHONY: status
status: ## one-line-ish status of the whole scenario
	-@$(KUBECTL) -n $(NAMESPACE) get pvc,pv,po,sc 2>&1

.PHONY: logs
logs: ## provisioner logs
	-$(KUBECTL) -n $(NAMESPACE) logs -l app=nfs-client-provisioner --tail=50

.PHONY: shell
shell: ## a shell inside the writer pod
	$(KUBECTL) -n $(NAMESPACE) exec -it deploy/writer -- sh

.PHONY: clean
clean: ## delete everything this lab created
	-$(KUBECTL) delete namespace $(NAMESPACE) --wait=false
	-$(KUBECTL) delete storageclass nfs-client --ignore-not-found
	-$(KUBECTL) delete clusterrole nfs-client-provisioner-runner --ignore-not-found
	-$(KUBECTL) delete clusterrolebinding run-nfs-client-provisioner --ignore-not-found
	@echo "deleted"
