.PHONY: all build deps generate help integration test version publish

CHECK_FILES ?= $$(go list ./... | grep -v /vendor/)

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {sub("\\\\n",sprintf("\n%22c"," "), $$2);printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

all: deps generate build test integration ## Run all steps

build: ## Build all
	go build ./...

deps: ## Download dependencies.
	go mod download

generate: ## Run code generation
	go generate ./...

test: ## Run Go tests
	go test -v $(CHECK_FILES)

integration: ## Run action integration tests
	./test/integration.sh

version: ## Run goversion. Usage: make version bump="patch" [files="-file=README.md"]
	@if [ -z "$(bump)" ]; then \
		echo "Error: You must provide a bump argument, e.g. bump=\"patch\"" >&2; \
		exit 1; \
	fi
	go tool github.com/bcomnes/goversion/v2 $(files) $(bump)

publish: ## Publish the prepared goversion release
	go tool github.com/bcomnes/goversion/v2 publish
