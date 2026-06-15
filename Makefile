# gmx-md-agent — build + convenience targets.
# GROMACS 2024.2 (CUDA) is installed from conda-forge; no registry login needed.
IMAGE ?= gmx-md-agent

.PHONY: help build poc dryrun poc-full shell clean

help:
	@echo "gmx-md-agent targets:"
	@echo "  make build      build the Docker image ($(IMAGE)) — no login required"
	@echo "  make dryrun     \$$0 cloud-path proof (sky check + render + --dryrun)"
	@echo "  make poc        same as dryrun (cheap, safe)"
	@echo "  make poc-full   ~\$$1-3 end-to-end proof on a real GPU (happy+resume+extend)"
	@echo "  make shell      open a shell in the image for poking around"
	@echo "  make clean      remove the built image"
	@echo ""
	@echo "Run the agent on a folder with the ./mda wrapper, e.g.:"
	@echo "  ./mda local  --prod-mdp prod.mdp --total-ns 500"
	@echo "  ./mda cloud  --prod-mdp prod.mdp --gpu-names RTX_4090"
	@echo "  ./mda extend --from md_0_250ns --to-ns 750 --where cloud"

build:
	docker build -t $(IMAGE) .

# Cheap, safe proof of the cloud path (no GPU rented). Needs a Vast key.
dryrun poc:
	MDAGENT_IMAGE=$(IMAGE) ./mda poc dryrun

# Full end-to-end proof (rents a small GPU briefly).
poc-full:
	MDAGENT_IMAGE=$(IMAGE) ./mda poc all

shell:
	docker run --rm -it --entrypoint bash -v "$$PWD":/work $(IMAGE)

clean:
	-docker image rm $(IMAGE)
