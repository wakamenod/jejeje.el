# Justfile for jejeje.el
# -----------------------------------------------------------------------
# Key issue: the system `emacs` shim provided by Homebrew's eask formula
# does NOT resolve to a real Emacs binary — only the versioned cellar
# path works.  We detect the binary at run-time and prepend its directory
# to PATH for every eask invocation.
# -----------------------------------------------------------------------

el_src     := "jejeje.el"
elc_src    := "jejeje.elc"
test_files := "test/jejeje-test.el"
dist_dir   := "dist"

[doc("List all recipes")]
default:
    @just --list

[doc("Verify the Emacs binary is usable")]
check-emacs:
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    if [ -n "$EMACS_CELLAR" ]; then
      EMACS_BIN="$EMACS_CELLAR"
      export PATH="$(dirname "$EMACS_BIN"):$PATH"
    else
      EMACS_BIN=$(command -v emacs 2>/dev/null || true)
    fi
    if [ -z "$EMACS_BIN" ]; then
      echo "ERROR: Emacs binary not found."
      echo "  Install emacs-plus via Homebrew:  brew install emacs-plus@31"
      exit 1
    fi
    echo "Emacs : $EMACS_BIN"
    "$EMACS_BIN" --version | head -1

[doc("Show detected Emacs version")]
version: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    if [ -n "$EMACS_CELLAR" ]; then
      export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    fi
    emacs --version

[doc("Install package dependencies via eask")]
install: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    eask install-deps

# Always remove stale .elc before compiling so eask never loads outdated
# byte-code — the root cause of the "void-function" test failures.
[doc("Byte-compile jejeje.el")]
compile: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    rm -f {{elc_src}}
    eask compile

# 1. Wipe all .elc files so that eask loads source, not stale byte-code.
# 2. Compile fresh (catches syntax / reference errors early).
# 3. Run the ERT suite.
[doc("Compile then run the ERT test suite")]
test: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    echo "── Removing stale byte-compiled files ──"
    find . -name "*.elc" -delete
    echo "── Compiling {{el_src}} ──"
    eask compile
    echo "── Running ERT tests ──"
    eask test ert {{test_files}}

[doc("Run checkdoc linter only")]
lint-checkdoc: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    eask lint checkdoc

[doc("Run package-lint only")]
lint-package: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    eask lint package

[doc("Run all linters (checkdoc + package-lint)")]
lint: lint-checkdoc lint-package

[doc("Build a distributable .tar in dist/")]
package: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    eask package

[doc("Show package metadata")]
info: check-emacs
    #!/usr/bin/env bash
    set -euo pipefail
    EMACS_CELLAR=$(ls /opt/homebrew/Cellar/emacs-plus@*/*/bin/emacs 2>/dev/null | sort | tail -1 || true)
    [ -n "$EMACS_CELLAR" ] && export PATH="$(dirname "$EMACS_CELLAR"):$PATH"
    eask info

[doc("Remove byte-compiled files and dist/")]
clean:
    @echo "── Removing byte-compiled files ──"
    find . -name "*.elc" -delete
    @echo "── Removing {{dist_dir}}/ ──"
    rm -rf {{dist_dir}}
    @echo "Done."
