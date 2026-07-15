;;; jejeje.el --- Emacs interface for the jejeje CLI tool  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  jun

;; Author: jun
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4.0") (quickrun "2.3"))
;; Keywords: competitive-programming, tools, processes
;; URL: https://github.com/jun/jejeje.el

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; jejeje.el provides an Emacs interface for the `je' command-line tool,
;; a competitive programming helper written in Rust.
;;
;; The `je' tool supports the following online judges:
;;   - AtCoder
;;   - Codeforces
;;   - yukicoder
;;   - AOJ (Aizu Online Judge)
;;
;; Features provided by this package:
;;   - `jejeje-prepare'   : Select a judge/contest interactively, then fetch samples
;;   - `jejeje-test'      : Run test cases against your solution
;;   - `jejeje-info'      : Display contest metadata
;;   - `jejeje-menu'      : Transient menu for all commands
;;
;; Quick start:
;;   (require 'jejeje)
;;   (global-set-key (kbd "C-c j") #'jejeje-menu)

;;; Code:

(require 'ansi-color)
(require 'json)
(require 'transient)
(require 'quickrun)
(require 'url)


;;; ─── Customisation ────────────────────────────────────────────────────────────

(defgroup jejeje nil
  "Emacs interface for the jejeje competitive programming CLI tool."
  :group 'tools
  :prefix "jejeje-")

(defcustom jejeje-executable "je"
  "Path to (or name of) the `je' executable.
When set to a bare name such as \"je\", the executable is looked up via
variable `exec-path'.  Set to an absolute path when the binary is not on PATH."
  :type 'string
  :group 'jejeje)

(defcustom jejeje-test-command nil
  "Shell command passed to `je test -c', or nil for automatic detection.
When nil (default), `jejeje-test' uses `jejeje--auto-command' to derive
the run command from the current buffer's file extension via `quickrun'.
Set to a non-nil string to pin a specific command for the current project
\(e.g. via directory-local variables in `.dir-locals.el')."
  :type '(choice (const :tag "Auto-detect via quickrun" nil)
                 (string :tag "Fixed command"))
  :group 'jejeje)

(defcustom jejeje-test-tle 2.0
  "Default time-limit in seconds passed to `je test --tle'."
  :type 'float
  :group 'jejeje)

(defcustom jejeje-buffer-name "*jejeje*"
  "Name of the buffer used to display `je' command output."
  :type 'string
  :group 'jejeje)

(defcustom jejeje-test-display-method 'posframe
  "Default method used to display `je test' results.
`posframe' opens a floating child-frame (requires the posframe package).
`buffer'   uses the standard `display-buffer' mechanism.
If posframe is not installed at runtime, `buffer' is used regardless."
  :type '(choice (const :tag "Floating frame (posframe)" posframe)
                 (const :tag "Standard buffer window" buffer))
  :group 'jejeje)

(defcustom jejeje-language-alist
  '(("cpp"  . "C++ (GCC")
    ("cc"   . "C++ (GCC")
    ("c"    . "C (GCC")
    ("py"   . "Python (CPython")
    ("rb"   . "Ruby")
    ("rs"   . "Rust")
    ("hs"   . "Haskell")
    ("java" . "Java")
    ("go"   . "Go")
    ("js"   . "JavaScript")
    ("ts"   . "TypeScript")
    ("kt"   . "Kotlin")
    ("cs"   . "C#")
    ("d"    . "D (DMD"))
  "Mapping from file extension to AtCoder language name prefix.
Used as a hint for `jejeje-submit-problem' to pre-filter the language list
in `completing-read'.  The value is matched as a prefix/substring of the
language option text shown on the AtCoder submit page.
Customise this when the default guesses do not match your preferred dialect."
  :type '(alist :key-type  (string :tag "File extension (without dot)")
                :value-type (string :tag "Language name substring"))
  :group 'jejeje)

(defvar jejeje--posframe-buffer " *jejeje-posframe*"
  "Name of the hidden posframe buffer used to host test-result frames.")


;;; ─── Auto-install: `je' binary management ────────────────────────────────────

(defvar jejeje--executable-dir
  (locate-user-emacs-file "jejeje/")
  "Directory under `user-emacs-directory' where the downloaded `je' binary lives.
The default resolves to the \"jejeje/\" subdirectory of `user-emacs-directory'.")

(defconst jejeje--github-api-latest
  "https://api.github.com/repos/wakamenod/jejeje/releases/latest"
  "GitHub API endpoint that returns the latest jejeje release metadata.")

(defun jejeje--executable-path ()
  "Return the absolute path to the managed `je' binary.
On Windows the binary is named `je.exe'; elsewhere `je'."
  (expand-file-name
   (if (eq system-type 'windows-nt) "je.exe" "je")
   jejeje--executable-dir))

(defun jejeje--installed-version ()
  "Return the version string reported by the managed `je' binary, or nil.
Runs `je -V' synchronously and returns the trimmed output (e.g. \"je 0.1.0\").
Returns nil when the binary does not exist or the invocation fails.
Used only for display purposes (e.g. `jejeje-version')."
  (let ((path (jejeje--executable-path)))
    (when (file-executable-p path)
      (with-temp-buffer
        (when (= 0 (call-process path nil t nil "-V"))
          (string-trim (buffer-string)))))))


(defun jejeje--release-asset-url (release-data)
  "Return the download URL for this OS from RELEASE-DATA (a parsed JSON object).
RELEASE-DATA must be a hash-table as returned by `json-parse-string'.
Selects the asset whose name matches the current OS:
  darwin      → macos-universal
  gnu/linux   → linux-x86_64
  windows-nt  → windows-x86_64
Signals `user-error' when no matching asset is found."
  (let* ((os-key (pcase system-type
                   ('darwin     "macos-universal")
                   ('gnu/linux  "linux-x86_64")
                   ('windows-nt "windows-x86_64")
                   (_ (user-error "Jejeje: unsupported OS `%s'" system-type))))
         (assets (gethash "assets" release-data))
         (match  (catch 'found
                   (seq-doseq (asset assets)
                     (when (string-match-p os-key (gethash "name" asset ""))
                       (throw 'found (gethash "browser_download_url" asset))))
                   nil)))
    (unless match
      (user-error "Jejeje: no release asset found for OS `%s'" system-type))
    match))

(defun jejeje--fetch-latest-release ()
  "Fetch and return the latest release metadata from GitHub as a hash-table.
Uses `url-retrieve-synchronously'.  Signals `user-error' on HTTP/parse errors."
  (let ((url-request-method "GET")
        (url-request-extra-headers
         '(("Accept" . "application/vnd.github.v3+json"))))
    (with-current-buffer
        (url-retrieve-synchronously jejeje--github-api-latest t t 10)
      (goto-char (point-min))
      ;; Skip HTTP response headers.
      (re-search-forward "^\r?\n" nil t)
      (condition-case err
          (json-parse-string (buffer-substring-no-properties (point) (point-max))
                             :object-type 'hash-table
                             :array-type  'array)
        (error
         (user-error "Jejeje: failed to parse GitHub API response: %s"
                     (error-message-string err)))))))

(defun jejeje--download-and-install (release-data)
  "Download the `je' binary from RELEASE-DATA and install it.
RELEASE-DATA is a hash-table as returned by `jejeje--fetch-latest-release'.
Steps:
  1. Resolve the correct asset URL for this OS.
  2. Download the archive to a temporary file with `url-copy-file'.
  3. Extract the binary with `tar' (Unix) or Expand-Archive (Windows PS).
  4. Copy the binary to `jejeje--executable-path' and make it executable.
Signals `user-error' if any step fails."
  (let* ((version     (gethash "tag_name" release-data))
         (asset-url   (jejeje--release-asset-url release-data))
         (archive-ext (if (string-suffix-p ".zip" asset-url) "zip" "tar.gz"))
         (tmp-archive (make-temp-file "jejeje-download-" nil
                                      (concat "." archive-ext)))
         (tmp-dir     (make-temp-file "jejeje-extract-" t))
         (bin-name    (if (eq system-type 'windows-nt) "je.exe" "je"))
         (dest        (jejeje--executable-path)))
    (message "Jejeje: downloading `je' %s from GitHub…" version)
    (condition-case err
        (url-copy-file asset-url tmp-archive t)
      (error
       (user-error "Jejeje: download failed: %s" (error-message-string err))))
    (message "Jejeje: extracting archive…")
    (let ((exit-code
           (if (eq system-type 'windows-nt)
               (call-process "powershell" nil nil nil
                             "-Command"
                             (format "Expand-Archive -Path '%s' -DestinationPath '%s' -Force"
                                     tmp-archive tmp-dir))
             (call-process "tar" nil nil nil
                           "-xzf" tmp-archive "-C" tmp-dir))))
      (unless (= 0 exit-code)
        (user-error "Jejeje: extraction failed (exit %d)" exit-code)))
    ;; Find the binary inside the extracted tree.
    (let* ((found (car (directory-files-recursively tmp-dir
                                                    (concat "^" (regexp-quote bin-name) "$")))))
      (unless found
        (user-error "Jejeje: binary `%s' not found in extracted archive" bin-name))
      (make-directory jejeje--executable-dir t)
      (copy-file found dest t)
      (unless (eq system-type 'windows-nt)
        (set-file-modes dest #o755)))
    ;; Clean up temp files.
    (ignore-errors (delete-file tmp-archive))
    (ignore-errors (delete-directory tmp-dir t))
    (message "Jejeje: `je' %s installed at %s" version dest)
    dest))

(defun jejeje--ensure-executable ()
  "Ensure the `je' binary is available, downloading it if necessary.
If the binary already exists at `jejeje--executable-path', return its path.
Otherwise fetch the latest release from GitHub, install it, update
`jejeje-executable' to the absolute path, and return that path.
This function blocks until the download completes."
  (let ((path (jejeje--executable-path)))
    (unless (file-executable-p path)
      (let ((release (jejeje--fetch-latest-release)))
        (jejeje--download-and-install release)))
    ;; Always point `jejeje-executable' at the managed binary path.
    (setq jejeje-executable path)
    path))

(defun jejeje--perform-update (release-data)
  "Download and install `je' from RELEASE-DATA outside any `url-retrieve' callback.
Calling `url-copy-file' (used by `jejeje--download-and-install') from within
a `url-retrieve' callback can corrupt the download due to nested use of the
URL library.  This function is therefore always invoked via `run-with-timer'
to ensure it runs in a fresh event-loop iteration."
  (let ((latest (gethash "tag_name" release-data)))
    (condition-case err
        (progn
          (jejeje--download-and-install release-data)
          (setq jejeje-executable (jejeje--executable-path))
          (message "Jejeje: `je' updated to %s" latest))
      (error
       (message "Jejeje: update failed: %s" (error-message-string err))))))

(defun jejeje--check-update-async ()
  "Asynchronously check for a newer `je' release and update in the background.
Compares the version reported by `je -V' with the latest tag from the GitHub
API.  When a newer version is available, downloads and installs it silently.
Scheduled via `run-with-idle-timer' at package load time."
  (let ((installed (jejeje--installed-version)))
    (url-retrieve
     jejeje--github-api-latest
     (lambda (status)
       (if (plist-get status :error)
           (kill-buffer (current-buffer))
         (goto-char (point-min))
         (re-search-forward "^\r?\n" nil t)
         (condition-case err
             (let* ((release (json-parse-string
                              (buffer-substring-no-properties (point) (point-max))
                              :object-type 'hash-table
                              :array-type  'array))
                    (latest  (gethash "tag_name" release)))
               (kill-buffer (current-buffer))
               (when (and latest installed
                          (not (string-match-p (regexp-quote
                                                (string-remove-prefix "v" latest))
                                               installed)))
                 (message "Jejeje: updating `je' (%s → %s)…" installed latest)
                 (run-with-timer 0 nil #'jejeje--perform-update release)))
           (error
            (message "Jejeje: update check failed: %s"
                     (error-message-string err))
            (kill-buffer (current-buffer))))))
     nil t t)))

(run-with-idle-timer 3 nil #'jejeje--check-update-async)


;;; ─── Internal utilities ───────────────────────────────────────────────────────

(defun jejeje--get-output-buffer (&optional name)
  "Return a freshly-cleared output buffer named NAME.
NAME defaults to `jejeje-buffer-name'.
The buffer is created if it does not already exist."
  (let ((buf (get-buffer-create (or name jejeje-buffer-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)))
    buf))

;; Tell the byte-compiler that these posframe functions exist when the
;; optional posframe package is installed.  This suppresses "not known to be
;; defined" warnings while keeping posframe as a soft, optional dependency.
(declare-function posframe-workable-p              "posframe")
(declare-function posframe-hide                    "posframe" (buffer-or-name))
(declare-function posframe-show                    "posframe" (buffer-or-name &rest args))
(declare-function posframe-poshandler-frame-center "posframe" (info))

(defun jejeje--posframe-available-p ()
  "Return non-nil when the posframe package is available.
Attempts a soft `require' so that posframe remains an optional dependency."
  (require 'posframe nil t)
  (featurep 'posframe))

(defun jejeje--buffer-visible-p (buf)
  "Return non-nil when BUF is currently displayed in a visible window."
  (get-buffer-window buf 'visible))

(defun jejeje--show-output-buffer (buf method)
  "Display BUF using METHOD, either \\='posframe or \\='buffer.

For \\='posframe: shows BUF in a centred child-frame.  The frame width
is capped at 100 columns and the height is capped at 30 lines; smaller
content shrinks the frame automatically.  The local \\='q\\=' key in BUF
is bound to hide the posframe.

For \\='buffer: falls back to the standard `display-buffer' function."
  (pcase method
    ('posframe
     ;; Hide any existing frame first so dimensions are recalculated cleanly.
     ;; NOTE: posframe-delete also kills the buffer, so we use posframe-hide
     ;; here to keep the *jejeje* buffer alive for the process output.
     (when (posframe-workable-p)
       (posframe-hide buf))
     (posframe-show
      buf
      :position (point)
      :poshandler #'posframe-poshandler-frame-center
      :width  (min 100 (round (* (frame-width)  0.75)))
      :height (min 30  (round (* (frame-height) 0.60)))
      :border-width 2
      :border-color (face-foreground 'shadow nil t)
      :accept-focus t)
     ;; Bind q locally so the user can dismiss the posframe.
     (with-current-buffer buf
       (local-set-key (kbd "q")
                      (lambda ()
                        (interactive)
                        (posframe-hide buf)))))
    (_
     (display-buffer buf))))

(defun jejeje--ansi-strip (str)
  "Remove ANSI escape sequences from STR.
`je' uses `owo-colors' which emits standard ANSI colour codes."
  (replace-regexp-in-string
   (rx (seq ?\e ?\[ (zero-or-more (any "0-9;")) (any "A-Za-z")))
   ""
   str))

(defun jejeje--fetch-contests (judge &optional limit)
  "Synchronously fetch contest list for JUDGE via `je contests'.
Returns an alist of (DISPLAY-STRING . URL) pairs suitable for `completing-read',
or nil on failure.
LIMIT is an optional integer cap on the number of contests returned."
  (with-temp-buffer
    (let* ((process-environment (cons "NO_COLOR=1" process-environment))
           (args (append (list "contests" judge)
                         (when limit (list "--limit" (number-to-string limit)))))
           (exit-code (apply #'call-process jejeje-executable nil t nil args)))
      (if (= 0 exit-code)
          (let (results)
            (goto-char (point-min))
            (while (not (eobp))
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                ;; Format: "<id> — <name> (<url>)"
                (when (string-match
                       (rx bol
                           (group (one-or-more (not (any " "))))  ; id
                           " \u2014 "
                           (group (one-or-more anychar))           ; name
                           " ("
                           (group "http" (optional "s") "://" (one-or-more (not (any ")"))))  ; url
                           ")")
                       line)
                  (let ((id   (match-string 1 line))
                        (name (match-string 2 line))
                        (url  (match-string 3 line)))
                    (push (cons (format "%s  [%s]" name id) url) results))))
              (forward-line 1))
            (nreverse results))
        nil))))

(defun jejeje--ansi-filter (proc output)
  "Process filter for `jejeje--run' that renders ANSI colour codes.
PROC is the running process; OUTPUT is the raw string chunk received.
Each chunk is appended to the process buffer and ANSI escape sequences
are converted to Emacs text properties via `ansi-color-apply-on-region'."
  (with-current-buffer (process-buffer proc)
    (let ((inhibit-read-only t)
          (start (marker-position (process-mark proc))))
      (goto-char start)
      (insert output)
      (ansi-color-apply-on-region start (point))
      (set-marker (process-mark proc) (point)))))

(defun jejeje--run (args output-buffer &optional sentinel)
  "Start `je' asynchronously with ARGS, streaming output into OUTPUT-BUFFER.

ARGS is a list of strings (subcommand + flags).
OUTPUT-BUFFER is the buffer that receives stdout and stderr.
SENTINEL is an optional function called with (process event) when the
process exits; if nil a default sentinel is used."
  (let* ((proc (make-process
                :name "jejeje"
                :buffer output-buffer
                :command (cons jejeje-executable args)
                :filter #'jejeje--ansi-filter
                :sentinel (or sentinel #'jejeje--default-sentinel)
                :stderr output-buffer)))
    proc))

(defun jejeje--default-sentinel (process event)
  "Default process sentinel for `jejeje--run'.
PROCESS is the finished process; EVENT is a string describing the change."
  (when (string-match-p "finished\\|exited" event)
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (propertize
                 (format "[je exited — %s]" (string-trim event))
                 'face 'shadow))))
    (message "Je: %s" (string-trim event))))

(defun jejeje--parse-test-summary (buf)
  "Parse the output in BUF and return a summary string.
Returns a string such as \"3 / 4 passed\" or \"All 4 tests passed!\"."
  (with-current-buffer buf
    (let ((content (buffer-string)))
      (or
       ;; "All N tests passed!"
       (when (string-match (rx "All " (group (one-or-more digit)) " tests passed") content)
         (format "✓ All %s tests passed!" (match-string 1 content)))
       ;; "N / M passed"
       (when (string-match (rx (group (one-or-more digit))
                               " / "
                               (group (one-or-more digit))
                               " passed")
                           content)
         (format "%s / %s passed" (match-string 1 content) (match-string 2 content)))
       ;; Fallback
       "je test complete"))))


(defun jejeje--auto-command ()
  "Derive the test-run command for the current buffer via `quickrun'.
Returns a cons cell (COMPILE-CMD . RUN-CMD) where COMPILE-CMD is a shell
command string to build the binary first (nil when not needed), and
RUN-CMD is the string passed to `je test --command'.

If quickrun cannot find a mapping for the current file, signals a
`user-error' asking the user to set `jejeje-test-command' manually."
  (unless buffer-file-name
          (user-error "Jejeje: current buffer has no associated file"))
  (let* ((file    buffer-file-name)
         (key     (quickrun--command-key file))
         (_ (unless key
              (user-error "Jejeje: quickrun has no mapping for %s; \
set `jejeje-test-command' manually"
                          (file-name-extension file t))))
         (alist   (quickrun--command-info key))
         (spec    (mapcar (lambda (elm)
                            (cons (string-to-char (substring (car elm) 1))
                                  (cdr elm)))
                          (quickrun--template-argument alist file)))
         (exec    (or (alist-get :exec alist)
                      (alist-get :exec quickrun--default-tmpl-alist))))
    (if (consp exec)
        ;; Multi-step: (compile-step … run-step)  — last element is the runner
        (let* ((steps      (mapcar (lambda (s) (format-spec s spec)) exec))
               (compile-steps (butlast steps))
               (run-cmd       (car (last steps)))
               (compile-cmd   (when compile-steps
                                (mapconcat #'identity compile-steps " && "))))
          (cons compile-cmd run-cmd))
      ;; Single step: interpreter-style
      (cons nil (format-spec exec spec)))))

(defun jejeje--find-meta-json ()
  "Walk up the directory tree from `default-directory' to find `.je-meta.json'.
Returns the absolute path to the file if found, or nil if no such file exists
in any ancestor directory up to the filesystem root."
  (let ((dir (expand-file-name default-directory)))
    (catch 'found
      (while t
        (let ((candidate (expand-file-name ".je-meta.json" dir)))
          (when (file-readable-p candidate)
            (throw 'found candidate)))
        (let ((parent (file-name-directory (directory-file-name dir))))
          (when (string= parent dir)
            ;; Reached the filesystem root without finding the file
            (throw 'found nil))
          (setq dir parent))))))

(defun jejeje--read-meta-json (path)
  "Read and parse the `.je-meta.json' file at PATH.
Returns a hash-table as produced by `json-parse-string' with keys as symbols.
Signals `user-error' if the file cannot be read or parsed."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents path)
        (json-parse-string (buffer-string) :object-type 'hash-table :array-type 'array))
    (error
     (user-error "Jejeje: failed to parse %s: %s" path (error-message-string err)))))

(defun jejeje--current-task-id ()
  "Return the task ID inferred from the current `default-directory'.
The task ID is the name of the innermost directory, lowercased.
For example, a directory path ending in \".../abc001/a/\" returns \"a\"."
  (file-name-nondirectory
   (directory-file-name (expand-file-name default-directory))))

(defun jejeje--js-string (str)
  "Encode STR as a JavaScript string literal with surrounding double quotes.
Uses `json-encode' which handles all necessary escape sequences:
backslashes, double quotes, newlines, and other control characters.
The result is safe to interpolate directly into a JS expression."
  (json-encode str))


;;; ─── Template directory ──────────────────────────────────────────────────────

(defun jejeje--get-template-dir ()
  "Return the template directory configured via `je config template_dir'.
Runs `je config template_dir' synchronously using `jejeje-executable' and
returns the trimmed output string.
Signals `user-error' when the command fails or returns an empty value."
  (let* ((raw
          (with-temp-buffer
            (let ((exit-code
                   (call-process jejeje-executable nil t nil
                                 "config" "template_dir")))
              (if (= 0 exit-code)
                  (string-trim (buffer-string))
                (user-error "Jejeje: `je config template_dir' failed (exit %d)"
                            exit-code)))))
         ;; Output format: "template_dir = /path/to/dir"  — extract the value.
         (result (if (string-match (rx bol (* nonl) "=" (* space)
                                       (group (+ nonl)) eol)
                                   raw)
                     (string-trim (match-string 1 raw))
                   raw)))
    (when (string-empty-p result)
      (user-error "Jejeje: template_dir is not set — run `je config template_dir <path>'"))
    result))


;;; ─── Submit: judge backends ───────────────────────────────────────────────────

(defvar jejeje--submit-backend-alist
  `(("atcoder\\.jp"
     ;; JS evaluated in the page; must return a JSON array of
     ;; [{value:"<option-value>", text:"<display-label>"}, …]
     :get-languages-js
     ,(concat
       "JSON.stringify("
       "Array.from("
       "document.querySelectorAll('#select-lang select option')"
       ").map(function(o){"
       "return{value:o.value,text:o.textContent.trim()};"
       "}))")
     ;; (VALUE) → JS: set the <select> and fire a change event
     :set-language-js
     ,(lambda (value)
        (format
         (concat "(function(){"
                 "var s=document.querySelector('#select-lang select');"
                 "s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));"
                 "})();")
         (jejeje--js-string value)))
     ;; (CODE) → JS: paste CODE into the ACE editor
     :set-code-js
     ,(lambda (code)
        (format
         "(function(){ace.edit('editor').setValue(%s,-1);})();"
         (jejeje--js-string code)))
     ;; JS: scroll to the bottom of the page so the submit button is visible
     :scroll-js
     "window.scrollTo({top:document.body.scrollHeight,behavior:'smooth'});")
    ("codeforces\\.com"
     ;; JS evaluated in the page; must return a JSON array of
     ;; [{value:"<option-value>", text:"<display-label>"}, …]
     :get-languages-js
     ,(concat
       "JSON.stringify("
       "Array.from("
       "document.querySelectorAll('select[name=programTypeId] option')"
       ").map(function(o){"
       "return{value:o.value,text:o.textContent.trim()};"
       "}))")
     ;; (VALUE) → JS: set the <select> and fire a change event
     :set-language-js
     ,(lambda (value)
        (format
         (concat "(function(){"
                 "var s=document.querySelector('select[name=programTypeId]');"
                 "s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));"
                 "})();")
         (jejeje--js-string value)))
     ;; (CODE) → JS: paste CODE into the CodeMirror editor.
     ;; Use the CSS adjacent-sibling selector to find the CodeMirror div that
     ;; immediately follows #sourceCodeTextarea; nextSibling is unreliable
     ;; because it may return a text node (whitespace) instead of an element.
     :set-code-js
     ,(lambda (code)
        (format
         (concat "(function(){"
                 "var cmEl=document.querySelector"
                 "('#sourceCodeTextarea + .CodeMirror');"
                 "var cm=cmEl&&cmEl.CodeMirror;"
                 "if(cm){cm.setValue(%s);cm.refresh();}"
                 "var ta=document.querySelector('#sourceCodeTextarea');"
                 "if(ta){ta.value=%s;"
                 "ta.dispatchEvent(new Event('change',{bubbles:true}));}"
                 "})();")
         (jejeje--js-string code)
         (jejeje--js-string code)))
     ;; (URL) → redirect-URL or nil.  When non-nil, jejeje-submit-problem
     ;; navigates the xwidget to the returned URL before injecting JS.
     :redirect-url-fn
     ,(lambda (url)
        (when (string-match
               "codeforces\\.com/contest/\\([^/]+\\)/problem/"
               url)
          (format "https://codeforces.com/contest/%s/submit"
                  (match-string 1 url))))
     ;; (URL) → problem-index string or nil.  Extracts the problem letter
     ;; (e.g. "A") from a problem page URL so it can be pre-selected in the
     ;; "Choose Problem" dropdown on the submit page.
     :extract-problem-fn
     ,(lambda (url)
        (when (string-match
               "codeforces\\.com/contest/[^/]+/problem/\\([^/?#]+\\)"
               url)
          (match-string 1 url)))
     ;; (INDEX) → JS: set select[name=submittedProblemIndex] and fire change.
     :set-problem-js
     ,(lambda (index)
        (format
         (concat "(function(){"
                 "var s=document.querySelector"
                 "('select[name=submittedProblemIndex]');"
                 "if(s){s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));}"
                 "})();")
         (jejeje--js-string index))))
    ("yukicoder\\.me"
     ;; JS evaluated in the page; must return a JSON array of
     ;; [{value:"<option-value>", text:"<display-label>"}, …]
     :get-languages-js
     ,(concat
       "JSON.stringify("
       "Array.from("
       "document.querySelectorAll('select#lang option')"
       ").map(function(o){"
       "return{value:o.value,text:o.textContent.trim()};"
       "}))")
     ;; (VALUE) → JS: set the <select> and fire a change event
     :set-language-js
     ,(lambda (value)
        (format
         (concat "(function(){"
                 "var s=document.querySelector('select#lang');"
                 "s.value=%s;"
                 "s.dispatchEvent(new Event('change',{bubbles:true}));"
                 "})();")
         (jejeje--js-string value)))
     ;; (CODE) → JS: paste CODE into the ACE editor (rich_source) if present,
     ;; then also write to the raw textarea (#source) as a fallback.
     :set-code-js
     ,(lambda (code)
        (format
         (concat "(function(){"
                 "var el=document.getElementById('rich_source');"
                 "var editor=el&&el.env&&el.env.editor;"
                 "if(editor){editor.setValue(%s,-1);}"
                 "var ta=document.getElementById('source');"
                 "if(ta){ta.value=%s;}"
                 "})();")
         (jejeje--js-string code)
         (jejeje--js-string code)))
     ;; JS: scroll to the bottom of the page so the submit button is visible
     :scroll-js
     "window.scrollTo({top:document.body.scrollHeight,behavior:'smooth'});")
    ("onlinejudge\\.u-aizu\\.ac\\.jp"
     ;; AOJ uses Element UI <el-select> — a custom Vue/element component that
     ;; renders language options as <li class="el-select-dropdown__item">.
     ;; Items hidden with display:none are excluded (unavailable for the problem).
     :get-languages-js
     ,(concat
       "JSON.stringify("
       "Array.from("
       "document.querySelectorAll('.el-select-dropdown__item')"
       ").filter(function(li){"
       "return li.style.display!=='none';"
       "}).map(function(li){"
       "var t=li.textContent.trim();"
       "return{value:t,text:t};"
       "}))")
     ;; (VALUE) → JS: open the Element UI dropdown by clicking its input,
     ;; then after a short delay click the matching <li> item.
     :set-language-js
     ,(lambda (value)
        (format
         (concat "(function(){"
                 "var inp=document.querySelector('.el-select .el-input__inner');"
                 "if(inp){inp.click();}"
                 "setTimeout(function(){"
                 "var items=document.querySelectorAll('.el-select-dropdown__item');"
                 "for(var i=0;i<items.length;i++){"
                 "if(items[i].textContent.trim()===%s){"
                 "items[i].click();break;}}"
                 "},200);"
                 "})();")
         (jejeje--js-string value)))
     ;; (CODE) → JS: paste CODE into the ACE editor (id="editor")
     :set-code-js
     ,(lambda (code)
        (format
         "(function(){ace.edit('editor').setValue(%s,-1);})();"
         (jejeje--js-string code)))
     ;; JS: scroll to the bottom of the page so the submit button is visible
     :scroll-js
     "window.scrollTo({top:document.body.scrollHeight,behavior:'smooth'});"))
  "Alist of (URL-REGEXP . PLIST) entries for judge-specific submit behaviour.

Each entry maps a URL regexp to a property list with keys:

  :get-languages-js  JS string evaluated in the page that must return a
                     JSON array of objects with \"value\" and \"text\" keys,
                     one element per language option in the dropdown.

  :set-language-js   Function (VALUE) → JS string.  Sets the language
                     dropdown to VALUE and fires a DOM change event so that
                     any reactive UI updates.

  :set-code-js       Function (CODE) → JS string.  Pastes CODE into the
                     judge's code editor widget (ACE, CodeMirror, etc.).

  :redirect-url-fn   Optional.  Function (URL) → string or nil.  When
                     non-nil, `jejeje-submit-problem' navigates the xwidget
                     to the returned URL first, then waits briefly before
                     injecting JS.  Useful when the submit form lives on a
                     different page than the problem statement.

  :extract-problem-fn  Optional.  Function (URL) → string or nil.  Called
                     on the original URL (before any redirect) to extract
                     a problem identifier (e.g. \"A\") that is then passed
                     to :set-problem-js to pre-select the problem dropdown.

  :set-problem-js    Optional.  Function (INDEX) → JS string.  Sets the
                     problem-selection dropdown to INDEX and fires a DOM
                     change event.  Called before the language prompt when
                     a problem index is available.

  :scroll-js         Optional.  JS string executed after code and language
                     are set.  Typically scrolls the page so the submit
                     button becomes visible without manual scrolling.

To add support for a new judge, push a new entry at the front of this list
before `jejeje-submit-problem' is called:

  (push \\='(\"example\\\\.com\"
           :get-languages-js \"...\"
           :set-language-js (lambda (v) ...)
           :set-code-js     (lambda (c) ...))
        jejeje--submit-backend-alist)")

(defun jejeje--detect-submit-backend (url)
  "Return the backend plist for URL, or nil if no entry matches.
Iterates `jejeje--submit-backend-alist' and returns the plist of the
first entry whose URL regexp matches URL."
  (cdr (seq-find (lambda (entry)
                   (string-match-p (car entry) url))
                 jejeje--submit-backend-alist)))

(defun jejeje--submit-inject (session backend source-code file-ext
                              &optional problem-index)
  "Inject language choice and SOURCE-CODE into the submit form in SESSION.
BACKEND is the plist from `jejeje--submit-backend-alist'.
FILE-EXT is used to pre-filter the language `completing-read' prompt.
When PROBLEM-INDEX is non-nil and the backend provides `:set-problem-js',
the problem dropdown is set to PROBLEM-INDEX before the language prompt."
  ;; Pre-select the problem in the dropdown when we know it.
  (let ((set-problem-fn (plist-get backend :set-problem-js)))
    (when (and problem-index set-problem-fn)
      (xwidget-webkit-execute-script
       session
       (funcall set-problem-fn problem-index))))
  (xwidget-webkit-execute-script
   session
   (plist-get backend :get-languages-js)
   (lambda (json-str)
     (let* ((raw
             (condition-case _
                 (json-parse-string (or json-str "[]")
                                    :array-type  'list
                                    :object-type 'alist)
               (error nil)))
            (_ (unless raw
                 (user-error
                  (concat "Jejeje: failed to retrieve language list — "
                          "make sure the submit page is open in the xwidget window"))))
            ;; Build (display-text . option-value) alist for completing-read.
            (candidates
             (mapcar (lambda (opt)
                       (cons (cdr (assq 'text  opt))
                             (cdr (assq 'value opt))))
                     raw))
            ;; Look up the hint keyword for this file extension.
            (hint
             (and file-ext
                  (cdr (assoc file-ext jejeje-language-alist))))
            ;; chosen-text is the display label the user picks.
            (chosen-text
             (completing-read "Language: "
                              (mapcar #'car candidates)
                              nil t hint))
            (chosen-value
             (cdr (assoc chosen-text candidates))))
       ;; Set language dropdown and fire a DOM change event.
       (xwidget-webkit-execute-script
        session
        (funcall (plist-get backend :set-language-js) chosen-value))
       ;; Scroll to the bottom so the submit button and editor are visible,
       ;; if supported.  Done before pasting so the editor is in view.
       (when-let* ((scroll-js (plist-get backend :scroll-js)))
         (xwidget-webkit-execute-script session scroll-js))
       ;; Paste source code into the editor widget.
       (xwidget-webkit-execute-script
        session
        (funcall (plist-get backend :set-code-js) source-code))
       (message "Jejeje: code and language set — please press the submit button")))))


;;; ─── Major mode for test results ──────────────────────────────────────────────

(defvar jejeje-test-mode-font-lock-keywords
  `(;; "All N tests passed!" — bold green
    (,(rx bol "All " (one-or-more digit) " tests passed!" eol)
     . 'success)
    ;; "N / M passed" summary line
    (,(rx (one-or-more digit) " / " (one-or-more digit) " passed")
     . 'success)
    ;; Verdict tokens at start of test-case lines
    (,(rx bol (zero-or-more (not (any ":"))) ": " (group "AC") " ")
     (1 '(:foreground "green" :weight bold)))
    (,(rx bol (zero-or-more (not (any ":"))) ": " (group "WA") " ")
     (1 '(:foreground "red" :weight bold)))
    (,(rx bol (zero-or-more (not (any ":"))) ": " (group "TLE") " ")
     (1 '(:foreground "yellow" :weight bold)))
    (,(rx bol (zero-or-more (not (any ":"))) ": " (group "RE") " ")
     (1 '(:foreground "magenta" :weight bold)))
    (,(rx bol (zero-or-more (not (any ":"))) ": " (group "SKIP"))
     (1 'shadow))
    ;; Section headers in WA diff blocks
    (,(rx bol "  " (or "Input" "Expected" "Actual") " :")
     . 'font-lock-comment-face))
  "Font-lock keywords for `jejeje-test-mode'.")

(define-derived-mode jejeje-test-mode special-mode "je-test"
  "Major mode for displaying `je test' results.
Provides syntax highlighting for AC, WA, TLE, RE, and SKIP verdicts."
  (setq-local font-lock-defaults '(jejeje-test-mode-font-lock-keywords t))
  (font-lock-mode 1)
  (read-only-mode 1))


;;; ─── Interactive commands ─────────────────────────────────────────────────────

;;;###autoload
(defun jejeje-prepare (query)
  "Run `je prepare QUERY' to fetch contest/problem samples.
When called interactively, first select a judge, then pick a contest
from the fetched list.  QUERY becomes the selected contest ID."
  (interactive
   (progn
     (jejeje--ensure-executable)
     (let* ((judge (completing-read "Judge: "
                                    '("atcoder" "codeforces" "yukicoder" "aoj")
                                    nil t))
            (_ (message "Jejeje: fetching %s contests …" judge))
            (candidates (jejeje--fetch-contests judge))
            (query
             (if candidates
                 (let* ((choice (completing-read
                                  (format "Contest [%s]: " judge)
                                  candidates nil t))
                        (id (cdr (assoc choice candidates))))
                   (or id choice))
               ;; Fallback: manual entry when fetch fails
               (progn
                 (message "Jejeje: failed to fetch contest list — enter ID/URL manually")
                 (read-string "je prepare — URL / ID / query: ")))))
       (list query))))
  (let ((buf (jejeje--get-output-buffer)))
    (with-current-buffer buf
      (special-mode))
    (message "Jejeje: preparing %s …" query)
    (jejeje--run
     (list "prepare" query)
     buf
     (lambda (proc event)
       (when (string-match-p "finished\\|exited" event)
         (with-current-buffer (process-buffer proc)
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (unless (bolp) (insert "\n"))
             (insert (propertize "[je prepare done]" 'face 'shadow))))
         (if (= 0 (process-exit-status proc))
             (message "Jejeje: prepare complete for %s" query)
           (display-buffer buf)
           (message "Jejeje: prepare failed — see %s" jejeje-buffer-name)))))))

;;;###autoload
(defun jejeje-test (&optional command display-method)
  "Run `je test' against the solution COMMAND.

When called interactively without a prefix argument and `jejeje-test-command'
is nil (the default), the run command is derived automatically from the
current buffer's file type via `quickrun' — no prompt is shown.

With a prefix argument (\\[universal-argument]), a prompt lets you choose
the display method (posframe or buffer window) and override the run command
for this invocation.

How the result buffer is displayed (in order of precedence):
1. If DISPLAY-METHOD is given explicitly, use it.
2. If the output buffer is already visible in a window, keep using it.
3. If `posframe' is installed and `jejeje-test-display-method' is \\='posframe,
   show a floating child-frame.
4. Otherwise fall back to the standard `display-buffer' mechanism.

Results are shown in a `jejeje-test-mode' buffer; a summary is also
displayed in the minibuffer when the process finishes."
  (interactive
   (if current-prefix-arg
       ;; C-u: let the user choose display method AND override the command.
       (let* ((method (completing-read
                       "Display method: "
                       '("posframe" "buffer")
                       nil t nil nil
                       (symbol-name jejeje-test-display-method)))
              (default-cmd (or jejeje-test-command
                               (cdr (jejeje--auto-command))))
              (cmd (read-string
                    (format "Command (default: %s): " default-cmd)
                    nil nil default-cmd)))
         (list cmd (intern method)))
     ;; No prefix: auto-detect command; display method resolved at runtime.
     (list (when jejeje-test-command jejeje-test-command) nil)))
  (jejeje--ensure-executable)
  (let* ((auto        (unless command (jejeje--auto-command)))
         (cmd         (or (and (stringp command) (not (string-empty-p command)) command)
                          (cdr auto)
                          jejeje-test-command))
         (compile-cmd (car auto))
         (buf         (jejeje--get-output-buffer)))
    (unless cmd
      (user-error "Jejeje: could not determine run command; \
set `jejeje-test-command' or install quickrun"))
    ;; Run compile step synchronously when needed (e.g. C++, Java, Rust)
    (when compile-cmd
      (message "Jejeje: compiling with `%s' …" compile-cmd)
      (let ((exit (shell-command compile-cmd)))
        (unless (= 0 exit)
          (user-error "Jejeje: compilation failed (exit %d) — check *Shell Command Output*"
                      exit))))
    (with-current-buffer buf
      (jejeje-test-mode))
    ;; ── Display logic ───────────────────────────────────────────────────────
    ;; Priority:
    ;;  1. Explicitly supplied DISPLAY-METHOD (from C-u prompt).
    ;;  2. Buffer is already visible  → reuse existing window, do nothing.
    ;;  3. posframe available + configured → posframe.
    ;;  4. Fallback → display-buffer.
    (let ((effective-method
           (cond
            (display-method display-method)
            ((jejeje--buffer-visible-p buf) 'existing)
            ((and (eq jejeje-test-display-method 'posframe)
                  (jejeje--posframe-available-p))
             'posframe)
            (t 'buffer))))
      (unless (eq effective-method 'existing)
        (jejeje--show-output-buffer buf effective-method)))
    ;; ────────────────────────────────────────────────────────────────────────
    (message "Jejeje: running tests with `%s' …" cmd)
    (jejeje--run
     (list "test"
           "--command" cmd
           "--tle" (number-to-string jejeje-test-tle))
     buf
     (lambda (proc event)
       (when (string-match-p "finished\\|exited" event)
         (let* ((test-buf (process-buffer proc))
                (summary  (jejeje--parse-test-summary test-buf)))
           (with-current-buffer test-buf
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (unless (bolp) (insert "\n"))
               (insert (propertize (format "[%s]" summary) 'face 'shadow))))
           (message "Jejeje: %s" summary)))))))

;;;###autoload
(defun jejeje-info ()
  "Run `je info' and display contest metadata in the output buffer.
Walks up from `default-directory' to find `.je-meta.json'."
  (interactive)
  (jejeje--ensure-executable)
  (let ((buf (jejeje--get-output-buffer)))
    (with-current-buffer buf
      (special-mode))
    (display-buffer buf)
    (jejeje--run
     (list "info")
     buf
     (lambda (proc event)
       (when (string-match-p "finished\\|exited" event)
         (if (= 0 (process-exit-status proc))
             (message "Jejeje: info loaded")
           (message "Jejeje: `je info' failed — no .je-meta.json found? See %s"
                    jejeje-buffer-name)))))))


(defun jejeje--get-xwidget-session ()
  "Return the xwidget-webkit session from a visible xwidget window.
Searches all windows on the current frame for one whose buffer is in
`xwidget-webkit-mode'.  Signals `user-error' if none is found or if
xwidgets are not compiled into this Emacs."
  (unless (fboundp 'xwidget-webkit-current-session)
    (user-error "Jejeje: xwidgets not available (Emacs must be built with --with-xwidgets)"))
  (let ((win (seq-find (lambda (w)
                         (with-current-buffer (window-buffer w)
                           (derived-mode-p 'xwidget-webkit-mode)))
                       (window-list))))
    (unless win
      (user-error "Jejeje: no xwidget window found — run M-x jejeje-browse-problem first"))
    (with-current-buffer (window-buffer win)
      (xwidget-webkit-current-session))))

;;;###autoload
(defun jejeje-browse-problem ()
  "Open the current problem's web page inside Emacs.

Reads `.je-meta.json' by walking up from `default-directory', then
looks up the task whose `id' matches the innermost directory name
\(e.g. \"a\", \"b\", \"ITP1_1_A\").  Opens the matching task URL with
`xwidget-webkit-browse-url' when available, or `browse-url' otherwise.

If no matching task is found the contest top-level URL is opened and a
notice is shown in the minibuffer."
  (interactive)
  (let* ((meta-path (or (jejeje--find-meta-json)
                        (user-error "Jejeje: no .je-meta.json found in %s or any parent directory"
                                    default-directory)))
         (meta      (jejeje--read-meta-json meta-path))
         (tasks     (gethash "tasks" meta))
         (task-id   (downcase (jejeje--current-task-id)))
         ;; Search tasks vector for a matching id (case-insensitive)
         (matched-url
          (catch 'found
            (when (arrayp tasks)
              (seq-doseq (task tasks)
                (when (string= (downcase (gethash "id" task "")) task-id)
                  (throw 'found (gethash "url" task)))))
            nil))
         (contest-url (gethash "url" meta))
         (url (or matched-url
                  (progn
                    (message "Jejeje: task id %S not found in contest — opening contest page"
                             task-id)
                    contest-url))))
    (if (fboundp 'xwidget-webkit-browse-url)
        ;; xwidget available: reuse an existing xwidget window,
        ;; or split the frame to the right and open a new one
        (let* ((existing-win
                (seq-find (lambda (w)
                            (with-current-buffer (window-buffer w)
                              (derived-mode-p 'xwidget-webkit-mode)))
                          (window-list)))
               (target-win (or existing-win
                               (split-window-right))))
          (select-window target-win)
          (xwidget-webkit-browse-url url))
      ;; xwidget not available: fall back to external browser
      (browse-url url))))

;;;###autoload
(defun jejeje-submit-problem ()
  "Fill the submit form in the xwidget browser with the current buffer's code.

Steps performed automatically:
  1. Detect the judge from the URL shown in the xwidget window.
  2. Fetch all language options from the page's dropdown via JS.
  3. Prompt for language selection with `completing-read'.
     The list is pre-filtered using `jejeje-language-alist' when the
     current buffer has a recognised file extension.
  4. Set the chosen language in the dropdown.
  5. Paste the current buffer's content into the code editor widget.

The submit button is intentionally left for the user to press manually,
allowing review and Cloudflare Turnstile verification when required.

Requires a visible xwidget window opened by `jejeje-browse-problem'.
For AtCoder, navigate to the contest submit page first.
For Codeforces, this command may be run from either the problem page
\(/contest/NNN/problem/X\) or the submit page \(/contest/NNN/submit\);
if on a problem page, the xwidget is automatically redirected to the
corresponding submit page and this command re-runs after a short delay.

To add support for another judge, push a new entry onto
`jejeje--submit-backend-alist' before calling this command."
  (interactive)
  (unless (fboundp 'xwidget-webkit-execute-script)
    (user-error "Jejeje: xwidgets not available (Emacs must be built with --with-xwidgets)"))
  (let* ((source-code (buffer-string))
         (file-ext    (when buffer-file-name
                        (file-name-extension buffer-file-name)))
         (session     (jejeje--get-xwidget-session))
         (url         (xwidget-webkit-uri session))
         (backend     (jejeje--detect-submit-backend url)))
    (unless backend
      (user-error
       "Jejeje: no submit backend for current page (%s) — supported judges: %s"
       url
       (mapconcat #'car jejeje--submit-backend-alist ", ")))
    ;; If the backend defines a redirect, navigate to the submit page first
    ;; and re-invoke this command after a short delay for the page to load.
    (let* ((redirect-fn    (plist-get backend :redirect-url-fn))
           (redirect-url   (and redirect-fn (funcall redirect-fn url)))
           (problem-fn     (plist-get backend :extract-problem-fn))
           ;; Extract the problem index now, before navigating away.
           (problem-index  (and redirect-url problem-fn
                                (funcall problem-fn url))))
      (if redirect-url
          (progn
            ;; Navigate using JS so we can target the specific session object.
            ;; (xwidget-webkit-browse-url takes a URL, not a session, so it
            ;; cannot be used to drive an existing session reliably.)
            (xwidget-webkit-execute-script
             session
             (format "window.location.href=%s;"
                     (jejeje--js-string redirect-url)))
            ;; After the page loads, inject with the values captured right now.
            ;; Using a closure avoids re-reading the wrong current buffer.
            (run-with-timer
             2 nil
             (lambda ()
               (jejeje--submit-inject
                (jejeje--get-xwidget-session)
                (jejeje--detect-submit-backend redirect-url)
                source-code
                file-ext
                problem-index)))
            (message "Jejeje: navigating to Codeforces submit page…"))
        ;; Already on the submit page — inject directly.
        (jejeje--submit-inject session backend source-code file-ext)))))


;;;###autoload
(defun jejeje-template ()
  "Open the template directory configured via `je config template_dir'.

If the current buffer is visiting a file and a file with the same base name
exists in the template directory, open that file directly with `find-file'.
Otherwise open the template directory itself with `dired'."
  (interactive)
  (jejeje--ensure-executable)
  (let* ((template-dir (jejeje--get-template-dir))
         (base-name    (and buffer-file-name
                            (file-name-nondirectory buffer-file-name)))
         (candidate    (and base-name
                            (expand-file-name base-name template-dir))))
    (if (and candidate (file-regular-p candidate))
        (find-file candidate)
      (dired template-dir))))


;;;###autoload
(defun jejeje-version ()
  "Display the version of the managed `je' binary in the minibuffer.
Runs `je -V' and shows the output via `message'.
Shows a notice instead when the binary has not been downloaded yet."
  (interactive)
  (let ((version (jejeje--installed-version)))
    (if version
        (message "%s" version)
      (message "Jejeje: `je' binary not found — invoke any jejeje command to download it"))))


;;; ─── Transient menu ───────────────────────────────────────────────────────────

(transient-define-prefix jejeje-menu ()
  "Transient menu for jejeje — competitive programming helper."
  ["jejeje"
   ["Contest"
    ("p" "Prepare samples"  jejeje-prepare)
    ("i" "Contest info"     jejeje-info)
    ("w" "Browse problem"   jejeje-browse-problem)
    ("s" "Submit problem"   jejeje-submit-problem)
    ("T" "Open template"    jejeje-template)]
   ["Test"
    ("t" "Run tests"        jejeje-test)]
   ["Misc"
    ("V" "Show je version"  jejeje-version)]
   ])


;;; ─── Key map ──────────────────────────────────────────────────────────────────

;;;###autoload
(defvar jejeje-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'jejeje-prepare)
    (define-key map (kbd "t") #'jejeje-test)
    (define-key map (kbd "i") #'jejeje-info)
    (define-key map (kbd "w") #'jejeje-browse-problem)
    (define-key map (kbd "s") #'jejeje-submit-problem)
    (define-key map (kbd "T") #'jejeje-template)
    (define-key map (kbd "V") #'jejeje-version)
    (define-key map (kbd "m") #'jejeje-menu)
    map)
  "Prefix key map for jejeje commands.
Bind this to a convenient prefix, e.g.:
  (global-set-key (kbd \"C-c j\") jejeje-map)")


;;; ─── Footer ───────────────────────────────────────────────────────────────────

(provide 'jejeje)
;;; jejeje.el ends here
