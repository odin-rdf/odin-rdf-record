# Odin source collections. The parser is a sibling checkout rather than a
# vendored copy, so it is reached through a collection instead of a relative
# path -- `import "rdf:rdf"` for the data model and the format packages.
# ols.json declares the same collection so the language server resolves what
# the compiler does.
COLL := -collection:rdf=../odin-rdf-parser

# Every package with tests. Grows with the implementation; tests/readme joins
# it when the README carries its first example. tests/tool drives the built
# binary, so the test target depends on tool; tests/proof runs the Python
# verifier (tests/verify/rdflog_verify.py) against the fault corpus, so the
# test target requires python3 and says so rather than failing cryptically.
# tests/scale is separate below: it is the measurement suite, gating the
# vision's sub-second boot criterion, and runs optimized — a debug harness
# would measure the harness, not the store.
PKGS := record tests/tool tests/proof

# There is no Term_ID width matrix here, deliberately. The family's dual-width
# convention exists because odin-rdf-store makes ID width a build-time choice
# (STORE-A-0001). This store fixes both of its widths by design -- u64 term IDs
# on disk (doc/design/api.md par. 3.5), u32 resident with an inline range
# (par. 3) -- because the inline encoding is frozen at first write (par. 3.3)
# and a build knob would put that freeze at the mercy of a flag.

.PHONY: all help test check tool clean

all: test

# The description of a target is the `##` on its own recipe line, which is what
# help greps for -- prose above a target is for a reader of this file, not the
# listing. A target with no `##` is internal and stays out of it.
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# The test runner tracks allocations per test but only warns about leaks and bad
# frees by default, which a passing build hides. Promote them to failures.
TEST_FLAGS := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(COLL)

test: tool ## Run the test suite
	@command -v python3 >/dev/null 2>&1 || \
		{ echo "error: python3 is required — the cross-implementation suite runs tests/verify/rdflog_verify.py"; exit 1; }
	@for pkg in $(PKGS); do \
		echo "-- $$pkg --"; \
		odin test $$pkg $(TEST_FLAGS) || exit 1; \
	done
	@echo "-- tests/scale (optimized) --"
	@odin test tests/scale $(TEST_FLAGS) -o:speed

check: ## Vet every package
	@for pkg in $(PKGS) tests/scale; do \
		echo "-- $$pkg --"; \
		odin check $$pkg -no-entry-point -vet -strict-style $(COLL) || exit 1; \
	done
	@echo "-- tool --"
	@odin check tool -vet -strict-style $(COLL)

# The CLI (log.md par. 12 q6): verify, dump, head — the auditor's read
# surface, a consumer of the record package like any other.
tool: ## Build the record CLI into build/record
	@mkdir -p build
	odin build tool -out:build/record -vet -strict-style $(COLL)

clean: ## Remove build/
	rm -rf build
