# Odin source collections. The parser is a sibling checkout rather than a
# vendored copy, so it is reached through a collection instead of a relative
# path -- `import "rdf:rdf"` for the data model and the format packages.
# ols.json declares the same collection so the language server resolves what
# the compiler does.
COLL := -collection:rdf=../odin-rdf-parser

# Every package with tests. record/ingest is the opt-in subpackage that
# turns parsed documents into ops (RECORD-I-0003 decision 7); tests/ingest
# sweeps it over the parser repo's vendored W3C suites, reached through the
# sibling checkout, and drives the dump round trip, so it needs the built
# binary and the test target depends on tool. tests/readme compiles the
# README's example. tests/ingest runs the Python verifier
# (tests/verify/rdflog_verify.py), so the test target requires python3 and
# says so rather than failing cryptically.
#
# The proof, tool and scale suites used to live here as separate packages.
# They are `record/{proof,tool,scale}_test.odin` now, IN the package
# (RECORD-T-0034): Odin scopes @(private) to the package, so a suite outside
# it forced 43 internal names to stay exported and put them in every
# consumer's completion list. tests/ingest and tests/readme cannot follow --
# they import record/ingest, which imports record, and in-package that is a
# cycle -- but neither holds an internal name.
#
# The scale measurement keeps its own pass below. Its @(test) procedures are
# behind `when #config(RECORD_SCALE, false)` so the ordinary run does not
# execute a wall-clock budget in a debug build; only the tests are guarded,
# not the helpers, because an unused import is an error in Odin and an unused
# procedure is not.
PKGS := record record/ingest tests/ingest tests/readme

# There is no Term_ID width matrix here, deliberately. The family's dual-width
# convention exists because odin-rdf-store makes ID width a build-time choice
# (STORE-A-0001). This store fixes both of its widths by design -- u64 term IDs
# on disk (doc/design/api.md par. 3.5), u32 resident with an inline range
# (par. 3) -- because the inline encoding is frozen at first write (par. 3.3)
# and a build knob would put that freeze at the mercy of a flag.

.PHONY: all help test check api tool clean

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
	@echo "-- record scale measurement (optimized) --"
	@odin test record $(TEST_FLAGS) -define:RECORD_SCALE=true -o:speed

check: ## Vet every package, then check the public surface
	@for pkg in $(PKGS); do \
		echo "-- $$pkg --"; \
		odin check $$pkg -no-entry-point -vet -strict-style $(COLL) || exit 1; \
	done
	@echo "-- record (RECORD_SCALE) --"
	@odin check record -no-entry-point -vet -strict-style $(COLL) -define:RECORD_SCALE=true
	@echo "-- tool --"
	@odin check tool -vet -strict-style $(COLL)
	@$(MAKE) --no-print-directory api

# What this package exports is a decision, not a residue (RECORD-I-0005).
# doc/api-surface.txt states it; this target holds it. `odin doc` is the input
# because it is the compiler's own view of what is reachable -- a name that
# stops being @(private) shows up here whether or not anything uses it yet.
# Runs as part of `check`, so CI carries it on every runner.
api: ## Check the exported surface against doc/api-surface.txt
	@echo "-- api surface --"
	@command -v python3 >/dev/null 2>&1 || \
		{ echo "error: python3 is required — the surface check runs tests/api/api_surface.py"; exit 1; }
	@python3 tests/api/api_surface.py check

# The CLI (log.md par. 12 q6): verify, dump, head — the auditor's read
# surface, a consumer of the record package like any other.
tool: ## Build the record CLI into build/record
	@mkdir -p build
	odin build tool -out:build/record -vet -strict-style $(COLL)

clean: ## Remove build/
	rm -rf build
