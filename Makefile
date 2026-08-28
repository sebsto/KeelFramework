# Keel — see docs/ARCHITECTURE.md
#
# Requires: Swift 6.2+ (Xcode 26+), Node 20+, and for `lambda` Apple's
# container CLI (https://github.com/apple/container).

SHELL := /bin/bash
.DEFAULT_GOAL := help

SWIFT ?= swift
CDK_DIR := cdk
SERVER_DIR := server
LOCAL_PORT ?= 7000

.PHONY: help
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# MARK: - Build

.PHONY: build
build: build-client build-server build-cdk ## Build everything (host arch)

.PHONY: build-client
build-client: ## Build the client package
	$(SWIFT) build --package-path .

.PHONY: build-server
build-server: ## Build the server package for the host
	$(SWIFT) build --package-path $(SERVER_DIR)

.PHONY: build-cdk
build-cdk: $(CDK_DIR)/node_modules ## Compile the CDK construct library
	cd $(CDK_DIR) && npx tsc --noEmit

.PHONY: lambda
lambda: ## Cross-compile + package the Lambda zips (container, arm64)
	$(SWIFT) package --disable-sandbox --package-path $(SERVER_DIR) \
		--allow-network-connections docker \
		lambda-build \
		--cross-compile container \
		--architecture arm64 \
		--products KeelLambda \
		--products KeelAuthorizerLambda

# MARK: - Test

.PHONY: test
test: test-client test-server test-cdk ## Run every test suite

.PHONY: test-client
test-client: ## swift test, client package
	$(SWIFT) test --package-path .

.PHONY: test-server
test-server: ## swift test, server package
	$(SWIFT) test --package-path $(SERVER_DIR)

.PHONY: test-cdk
test-cdk: $(CDK_DIR)/node_modules ## jest, CDK assertions on the synthesized template
	cd $(CDK_DIR) && npm test

.PHONY: synth
synth: $(CDK_DIR)/node_modules ## cdk synth the sample stack in every auth mode
	cd $(CDK_DIR) && for mode in none sharedSecret iam jwt; do \
		echo "── $$mode"; \
		npx cdk synth --quiet --app "npx tsx test/synth-app.ts" -c auth=$$mode || exit 1; \
	done

# MARK: - Run locally (no AWS)
#
# The Lambda runtime, outside a real Lambda environment, serves a local endpoint on
# :7000 that takes API Gateway *event JSON* at POST /invoke — not plain HTTP. The
# event files under server/events/ are those payloads.

.PHONY: local
local: ## Run KeelLambda locally with an in-memory store (POST events to :$(LOCAL_PORT)/invoke)
	TABLE_NAME=local KEEL_MEMORY_STORE=true LOG_LEVEL=debug \
		$(SWIFT) run --package-path $(SERVER_DIR) KeelLambda

.PHONY: smoke
smoke: ## Invoke bootstrap, ping, and stats against a running `make local`
	@set -e; invoke=http://127.0.0.1:$(LOCAL_PORT)/invoke; \
	curl -fsS --data @$(SERVER_DIR)/events/bootstrap.json $$invoke | grep -q schemaVersion; \
	curl -fsS --data @$(SERVER_DIR)/events/ping.json $$invoke | grep -q '\\"ok\\":true'; \
	curl -fsS --data @$(SERVER_DIR)/events/stats.json $$invoke | grep -q generatedAt; \
	echo "smoke OK"

# MARK: - Quality

.PHONY: lint
lint: lint-swift lint-cdk ## Lint Swift and TypeScript

# The generated Soto client (server/Sources/Soto) is deliberately excluded: it is
# machine-written, builds with relaxed settings, and is not ours to reformat.
SERVER_LINT_DIRS := $(addprefix $(SERVER_DIR)/Sources/,KeelServer KeelServerTesting \
	KeelServerDynamoDB KeelRouter KeelLambda KeelAuthorizerLambda keel-cli \
	KeelIAP KeelIAPDynamoDB KeelIAPRouter)

.PHONY: lint-swift
lint-swift: ## swift-format in lint mode (warnings are errors in the build anyway)
	$(SWIFT) format lint --recursive --strict Sources Tests $(SERVER_LINT_DIRS) $(SERVER_DIR)/Tests

.PHONY: format
format: ## swift-format in place
	$(SWIFT) format --recursive --in-place Sources Tests $(SERVER_LINT_DIRS) $(SERVER_DIR)/Tests

.PHONY: lint-cdk
lint-cdk: $(CDK_DIR)/node_modules ## eslint the construct library
	cd $(CDK_DIR) && npm run lint

.PHONY: docs
docs: ## Check every mermaid diagram in docs/ parses (skipped if mmdc is absent)
	@if npx --no-install mmdc --version >/dev/null 2>&1; then \
		for f in docs/*.md; do npx --no-install mmdc -i "$$f" -o /dev/null && echo "ok $$f"; done; \
	else \
		echo "mermaid-cli not installed — skipping (npm i -g @mermaid-js/mermaid-cli)"; \
	fi

# MARK: - Housekeeping

$(CDK_DIR)/node_modules: $(CDK_DIR)/package.json
	cd $(CDK_DIR) && npm install
	@touch $@

.PHONY: soto
soto: ## Regenerate the minimal DynamoDB client (see docs/adr/0006-codegen-soto.md)
	./scripts/generate-soto.sh

.PHONY: clean
clean: ## Remove build products
	rm -rf .build $(SERVER_DIR)/.build $(CDK_DIR)/cdk.out $(CDK_DIR)/lib/*.js $(CDK_DIR)/lib/*.d.ts
