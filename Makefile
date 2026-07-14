# Makefile for jejeje.el
# -----------------------------------------------------------------------
# Key issue: the system `emacs` shim provided by Homebrew's eask formula
# does NOT resolve to a real Emacs binary — only the versioned cellar
# path works.  We detect the binary at make-time and expose it through
# PATH for every eask invocation.
# -----------------------------------------------------------------------

# ── Emacs binary detection ──────────────────────────────────────────────
# Prefer the versioned cellar path; fall back to whatever is on PATH.
EMACS_CELLAR := $(wildcard /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs)
ifneq ($(EMACS_CELLAR),)
  # If there are multiple installations take the last (newest) one.
  EMACS_BIN    := $(lastword $(sort $(EMACS_CELLAR)))
  EMACS_BINDIR := $(dir $(EMACS_BIN))
  # Prepend the bin-dir so eask (and any sub-processes) find the binary.
  export PATH  := $(EMACS_BINDIR):$(PATH)
else
  EMACS_BIN := $(shell command -v emacs 2>/dev/null)
endif

EMACS   := $(EMACS_BIN)
EASK    := eask

# ── Source / artefact paths ─────────────────────────────────────────────
EL_SRC       := jejeje.el
ELC_SRC      := $(EL_SRC:.el=.elc)
TEST_FILES   := test/jejeje-test.el
DIST_DIR     := dist

# ── Phony targets ───────────────────────────────────────────────────────
.PHONY: all help install clean test compile lint lint-checkdoc lint-package \
        package info version check-emacs

# ── Default ─────────────────────────────────────────────────────────────
all: help

# ── Help ────────────────────────────────────────────────────────────────
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  install          Install package dependencies via eask"
	@echo "  compile          Byte-compile $(EL_SRC)"
	@echo "  test             Compile then run the ERT test suite"
	@echo "  lint             Run all linters (checkdoc + package-lint)"
	@echo "  lint-checkdoc    Run checkdoc only"
	@echo "  lint-package     Run package-lint only"
	@echo "  package          Build a distributable .tar in $(DIST_DIR)/"
	@echo "  clean            Remove byte-compiled files and $(DIST_DIR)/"
	@echo "  info             Show package metadata"
	@echo "  version          Show detected Emacs version"
	@echo "  check-emacs      Verify the Emacs binary is usable"

# ── Emacs sanity check ──────────────────────────────────────────────────
check-emacs:
	@if [ -z "$(EMACS)" ]; then \
	  echo "ERROR: Emacs binary not found."; \
	  echo "  Install emacs-plus via Homebrew:  brew install emacs-plus@31"; \
	  exit 1; \
	fi
	@echo "Emacs : $(EMACS)"
	@$(EMACS) --version | head -1

# ── Version shortcut ────────────────────────────────────────────────────
version: check-emacs
	@$(EMACS) --version

# ── Install dependencies ─────────────────────────────────────────────────
install: check-emacs
	$(EASK) install-deps

# ── Byte-compile ─────────────────────────────────────────────────────────
# Always remove stale .elc before compiling so eask never loads outdated
# byte-code — the root cause of the "void-function" test failures.
compile: check-emacs
	@rm -f $(ELC_SRC)
	$(EASK) compile

# ── Test ─────────────────────────────────────────────────────────────────
# 1. Wipe all .elc files so that eask loads source, not stale byte-code.
# 2. Compile fresh (catches syntax / reference errors early).
# 3. Run the ERT suite.
test: check-emacs
	@echo "── Removing stale byte-compiled files ──"
	@find . -name "*.elc" -delete
	@echo "── Compiling $(EL_SRC) ──"
	$(EASK) compile
	@echo "── Running ERT tests ──"
	$(EASK) test ert $(TEST_FILES)

# ── Lint ─────────────────────────────────────────────────────────────────
lint-checkdoc: check-emacs
	$(EASK) lint checkdoc

lint-package: check-emacs
	$(EASK) lint package

lint: lint-checkdoc lint-package

# ── Package ──────────────────────────────────────────────────────────────
package: check-emacs
	$(EASK) package

# ── Package metadata ─────────────────────────────────────────────────────
info: check-emacs
	$(EASK) info

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	@echo "── Removing byte-compiled files ──"
	@find . -name "*.elc" -delete
	@echo "── Removing $(DIST_DIR)/ ──"
	@rm -rf $(DIST_DIR)
	@echo "Done."
