# jejeje.el — Agent Instructions

## After any implementation, run in order (no confirmation needed):

```
just lint && just test && just package
```

All three must exit 0. Fix failures before finishing.

> Always use `just`, never `eask` directly — the Emacs binary is not on
> PATH unless `just` exports it from `/opt/homebrew/Cellar/emacs-plus@*/`.

## Traps to avoid

- **`fboundp` mocking**: never mock `fboundp` via `cl-letf` — causes
  infinite recursion. Use `fmakunbound` + `unwind-protect` instead.
- **JS string escaping**: always use `jejeje--js-string` (wraps
  `json-encode`). Never escape manually.
- **New judges**: push to `jejeje--submit-backend-alist`; don't touch
  `jejeje-submit-problem` itself.
- **Stale `.elc`**: `just test` cleans them; if running eask manually,
  `find . -name "*.elc" -delete` first.

## Conventions

- Messages and docstrings: English only.
- New commands: add to both `jejeje-map` and `jejeje-menu`.
- `should` on strings with `+`/`(`/`)`: use `regexp-quote`.
