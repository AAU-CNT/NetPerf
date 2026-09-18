# NetPerf25 labs — task runner
# `make help` for the list.
# Network:     TOPO (the *.clab.yml to deploy)
# Experiment:  CC (algo) TASK LOSS DUR

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---- tunables -------------------------------------------------------------
# CC is a built-in Make variable (defaults to the C compiler) and is often
# exported in the environment (CC=gcc). Force our default unless it was given
# on the command line, so `make run CC=reno` still wins but a stray env CC=gcc
# does not leak into --cc.
ifneq ($(origin CC),command line)
CC := cubic         # congestion control: reno | vegas | cubic | bbr
endif
TASK  ?= 3          # which task's experiment to run
LOSS  ?= 0          # results-dir label only (shape loss in the *.clab.yml vars)
DUR   ?= 60         # experiment duration, seconds

ROOT       := $(shell cd $(dir $(lastword $(MAKEFILE_LIST))) && pwd)
VENV       := $(ROOT)/.venv
PY         := $(VENV)/bin/python
# TOPO is the student-authored *.clab.yml. Default: the reference dumbbell.
TOPO       ?= $(ROOT)/topology/dumbbell.clab.yml
DEPLOY     := $(ROOT)/topology/.deploy.clab.yml
SHAPE      := $(ROOT)/topology/.deploy.shape.json
RESULTS    := $(ROOT)/results

# ---- meta -----------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@echo "NetPerf25 labs — available targets:"
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Parameters (override on the command line):"
	@echo "  TOPO=$(notdir $(TOPO))   CC=$(CC) TASK=$(TASK) LOSS=$(LOSS) DUR=$(DUR)"

# ---- setup (shipped scripts) ---------------------------------------------
.PHONY: bootstrap
bootstrap: ## Install Docker, containerlab, Python venv, and kernel modules (fresh Ubuntu)
	@bash $(ROOT)/bootstrap/install.sh

.PHONY: check
check: ## Verify the environment is ready (safe to run anytime)
	@bash $(ROOT)/bootstrap/preflight.sh

# ---- lab lifecycle ------------------------------------------------------- #
.PHONY: build
build: ## Build the multi-arch labhost container image
	@$(call require,$(ROOT)/images/labhost/Dockerfile,images/labhost/)
	docker build -t netperf25/labhost:latest $(ROOT)/images/labhost

.PHONY: prepare
prepare: ## Compile TOPO → deploy file + shaping plan (no deploy)
	@$(call require,$(TOPO),author a *.clab.yml or copy topology/dumbbell.clab.yml)
	$(PY) $(ROOT)/topology/prepare_topology.py $(TOPO) --out $(DEPLOY)

.PHONY: deploy
deploy: prepare ## Compile TOPO, bring up bridges, deploy, apply shaping
	@bash $(ROOT)/topology/bridges.sh up --shape $(SHAPE)
	sudo clab deploy -t $(DEPLOY)
	@bash $(ROOT)/topology/impair.sh apply --shape $(SHAPE)

.PHONY: destroy
destroy: ## Tear down the deployed lab and its bridges
	@$(call require,$(DEPLOY),run `make deploy` first)
	-sudo clab destroy -t $(DEPLOY) --cleanup
	@bash $(ROOT)/topology/bridges.sh down --shape $(SHAPE) || true

.PHONY: run
run: ## Run a task experiment: make run TASK=3 CC=cubic [LOSS=..] [DUR=..]
	@$(call require,$(ROOT)/analysis/run_experiment.py,analysis/)
	@$(call require,$(SHAPE),run `make deploy` first)
	@mkdir -p $(RESULTS)
	$(PY) $(ROOT)/analysis/run_experiment.py \
		--task $(TASK) --cc $(CC) --loss $(LOSS) \
		--shape $(SHAPE) --duration $(DUR) --out $(RESULTS)

.PHONY: sample
sample: ## Ad-hoc: sample ss + qdisc of the running lab for DUR seconds into results/
	@$(call require,$(SHAPE),run `make deploy` first)
	@mkdir -p $(RESULTS)
	@bash $(ROOT)/analysis/sample_qdisc.sh --shape $(SHAPE) --duration $(DUR) --out $(RESULTS)/qdisc.csv & \
	 bash $(ROOT)/analysis/sample_cwnd.sh --shape $(SHAPE) --duration $(DUR) --out $(RESULTS)/ss.csv ; \
	 wait

.PHONY: clean
clean: ## Tear down the lab and remove generated deploy files + results
	-@[ -f "$(DEPLOY)" ] && sudo clab destroy -t $(DEPLOY) --cleanup 2>/dev/null || true
	-@[ -f "$(SHAPE)" ] && bash $(ROOT)/topology/bridges.sh down --shape $(SHAPE) 2>/dev/null || true
	rm -f $(DEPLOY) $(SHAPE)
	rm -rf $(RESULTS)

# helper: fail with a clear pointer if a required file is missing
define require
	@if [ ! -e "$(1)" ]; then \
		echo "✗ missing: $(1)"; \
		echo "  → $(2)"; \
		exit 1; \
	fi
endef

