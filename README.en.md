# jejeje.el

[🇯🇵 日本語](README.md)

Emacs interface for the [jejeje](https://github.com/wakamenod/jejeje) competitive programming CLI tool (`je`), supporting AtCoder, Codeforces, yukicoder, and AOJ.

## Features

- **`jejeje-prepare`**: Select a judge and contest interactively, then fetch problem samples.
- **`jejeje-test`**: Run test cases against your solution with syntax-highlighted results. The run command is derived automatically via [quickrun](https://github.com/emacsorphanage/quickrun). Use `C-u` to override the command or display method for a single invocation.
- **`jejeje-submit`**: Inject language and source code into the submit form of a live `xwidget-webkit` session. Press the submit button manually to finalize.
- **`jejeje-info`**: Display contest metadata from `.je-meta.json`.
- **`jejeje-browse-problem`**: Open the current problem's web page inside Emacs.
- **`jejeje-menu`**: [Transient](https://github.com/magit/transient) popup menu for all commands.

## Prerequisites

- **Emacs** 28.1+
- **`je` CLI**: Managed automatically — downloaded on first use, updated silently in the background each startup. No manual installation needed.
- **transient** 0.4.0+ (auto-resolved)
- **quickrun** 2.3+ (auto-resolved)
- **posframe** *(optional)*: Floating child-frame display for `jejeje-test`.
- **xwidgets** *(optional, required for `jejeje-submit`)*: Emacs must be built with `--with-xwidgets`. On macOS, [emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus) supports this out of the box.

## Installation

### Emacs 29+ (`package-vc`)

```elisp
(use-package jejeje
  :vc (:url "https://github.com/wakamenod/jejeje.el")
  :bind (("C-c j" . jejeje-menu)))
```

### With `straight.el`

```elisp
(use-package jejeje
  :straight (jejeje :type git :host github :repo "wakamenod/jejeje.el")
  :bind (("C-c j" . jejeje-menu)))
```

## Configuration

```elisp
(setq jejeje-executable "/usr/local/bin/je")  ; override managed binary
(setq jejeje-test-command nil)                ; nil = auto-detect via quickrun
(setq jejeje-test-tle 2.0)                    ; time-limit in seconds
(setq jejeje-buffer-name "*jejeje*")          ; output buffer name
(setq jejeje-test-display-method 'posframe)   ; 'posframe (default) or 'buffer
```

Per-project override via `.dir-locals.el`:

```elisp
((nil . ((jejeje-test-command . "./a.out"))))
```

## Usage

`M-x jejeje-menu` (recommended) or bind the prefix map:

```elisp
(global-set-key (kbd "C-c j") jejeje-map)
```

Default key bindings:

| Key | Command                 |
|-----|-------------------------|
| `p` | `jejeje-prepare`        |
| `t` | `jejeje-test`           |
| `s` | `jejeje-submit-problem` |
| `i` | `jejeje-info`           |
| `w` | `jejeje-browse-problem` |
| `T` | `jejeje-template`       |
| `V` | `jejeje-version`        |
| `m` | `jejeje-menu`           |

## Development

```sh
just lint && just test && just package
```

## License

GPL-3.0-or-later
