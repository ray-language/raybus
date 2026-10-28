# raybus — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt run crash bench clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./raybus
	rm -f raybus
	ray build --native --release -o raybus src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

run: build ## Serve with ./raybus.toml (copy raybus.example.toml first)
	./raybus serve

crash: build ## kill -9 mid-produce, three rounds: every acknowledged record must survive
	scripts/crash.sh 3

bench: build ## Produce (acknowledged after fsync) and read back, by clients and batch size
	scripts/bench.sh

clean: ## Remove the binary
	rm -f raybus
