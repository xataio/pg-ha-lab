KIND_NAME    ?= pg-ha-lab
NS           ?= pglab
CNPG_VERSION ?= 1.30.0
CLIENT_IMAGE ?= pg-ha-lab-client:dev
SCENARIO     ?= s01-async-baseline

export KIND_NAME NS CNPG_VERSION CLIENT_IMAGE

.PHONY: cluster-up cluster-down cnpg-install client-image run check heal status

cluster-up:
	kind get clusters | grep -qx $(KIND_NAME) || kind create cluster --config kind/kind-config.yaml
	kubectl get ns $(NS) >/dev/null 2>&1 || kubectl create ns $(NS)

cluster-down:
	kind delete cluster --name $(KIND_NAME)

cnpg-install:
	./stacks/cnpg/install.sh

client-image:
	docker build -t $(CLIENT_IMAGE) harness/client
	kind load docker-image $(CLIENT_IMAGE) --name $(KIND_NAME)

run:
	./scenarios/$(SCENARIO).sh

check:
	@test -n "$(RUN)" || (echo "usage: make check RUN=results/<run-id>" && exit 1)
	python3 checker/check.py $(RUN)

# emergency: remove all lab iptables rules from every node
heal:
	./nemesis/partition.sh heal

status:
	kubectl -n $(NS) get cluster,pods -o wide
