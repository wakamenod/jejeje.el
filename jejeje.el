;;; jejeje.el --- Emacs interface for the jejeje competitive programming CLI tool  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  jun

;; Author: jun
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4.0"))
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

(require 'transient)


;;; ─── Customisation ────────────────────────────────────────────────────────────

(defgroup jejeje nil
  "Emacs interface for the jejeje competitive programming CLI tool."
  :group 'tools
  :prefix "jejeje-")

(defcustom jejeje-executable "je"
  "Path to (or name of) the `je' executable.
When set to a bare name such as \"je\", the executable is looked up via
`exec-path'.  Set to an absolute path when the binary is not on PATH."
  :type 'string
  :group 'jejeje)

(defcustom jejeje-test-command "./a.out"
  "Default shell command passed to `je test -c'.
Override this per-project via directory-local variables."
  :type 'string
  :group 'jejeje)

(defcustom jejeje-test-tle 2.0
  "Default time-limit in seconds passed to `je test --tle'."
  :type 'float
  :group 'jejeje)

(defcustom jejeje-buffer-name "*jejeje*"
  "Name of the buffer used to display `je' command output."
  :type 'string
  :group 'jejeje)


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

(defun jejeje--ansi-strip (str)
  "Remove ANSI escape sequences from STR.
`je' uses `owo-colors' which emits standard ANSI colour codes."
  (replace-regexp-in-string
   (rx (seq ?\e ?\[ (zero-or-more (any "0-9;")) (any "A-Za-z")))
   ""
   str))

(defun jejeje--fetch-contests (judge &optional limit)
  "Synchronously fetch contest list for JUDGE via `je contests'.
Returns an alist of (DISPLAY-STRING . ID) pairs suitable for `completing-read',
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
                        (name (match-string 2 line)))
                    (push (cons (format "%s  [%s]" name id) id) results))))
              (forward-line 1))
            (nreverse results))
        nil))))

(defun jejeje--run (args output-buffer &optional sentinel)
  "Start `je' asynchronously with ARGS, streaming output into OUTPUT-BUFFER.

ARGS is a list of strings (subcommand + flags).
OUTPUT-BUFFER is the buffer that receives stdout and stderr.
SENTINEL is an optional function called with (process event) when the
process exits; if nil a default sentinel is used."
  (let* ((process-environment
          ;; Disable colour when we are parsing output ourselves (je test).
          ;; Use NO_COLOR convention; owo-colors respects it.
          (cons "NO_COLOR=1" process-environment))
         (proc (make-process
                :name "jejeje"
                :buffer output-buffer
                :command (cons jejeje-executable args)
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
    (message "je: %s" (string-trim event))))

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


;;; ─── Major mode for test results ──────────────────────────────────────────────

(defvar je-test-mode-font-lock-keywords
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
  "Font-lock keywords for `je-test-mode'.")

(define-derived-mode je-test-mode special-mode "je-test"
  "Major mode for displaying `je test' results.
Provides syntax highlighting for AC, WA, TLE, RE, and SKIP verdicts."
  (setq-local font-lock-defaults '(je-test-mode-font-lock-keywords t))
  (font-lock-mode 1)
  (read-only-mode 1))


;;; ─── Interactive commands ─────────────────────────────────────────────────────

;;;###autoload
(defun jejeje-prepare (query)
  "Run `je prepare QUERY' to fetch contest/problem samples.
When called interactively, first select a judge, then pick a contest
from the fetched list.  QUERY becomes the selected contest ID."
  (interactive
   (let* ((judge (completing-read "Judge: "
                                  '("atcoder" "codeforces" "yukicoder" "aoj")
                                  nil t))
          (_ (message "jejeje: fetching %s contests …" judge))
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
               (message "jejeje: failed to fetch contest list — enter ID/URL manually")
               (read-string "je prepare — URL / ID / query: ")))))
     (list query)))
  (let ((buf (jejeje--get-output-buffer)))
    (with-current-buffer buf
      (special-mode))
    (display-buffer buf)
    (message "jejeje: preparing %s …" query)
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
             (message "jejeje: prepare complete for %s" query)
           (message "jejeje: prepare failed — see %s" jejeje-buffer-name)))))))

;;;###autoload
(defun jejeje-test (&optional command)
  "Run `je test' against the solution COMMAND.
COMMAND defaults to `jejeje-test-command'.
Results are shown in a `je-test-mode' buffer; a summary is also
displayed in the minibuffer when the process finishes."
  (interactive
   (list (read-string
          (format "Command (default: %s): " jejeje-test-command)
          nil nil jejeje-test-command)))
  (let* ((cmd (or (and (not (string-empty-p command)) command)
                  jejeje-test-command))
         (buf (jejeje--get-output-buffer)))
    (with-current-buffer buf
      (je-test-mode))
    (display-buffer buf)
    (message "jejeje: running tests with `%s' …" cmd)
    (jejeje--run
     (list "test"
           "--command" cmd
           "--tle" (number-to-string jejeje-test-tle))
     buf
     (lambda (proc event)
       (when (string-match-p "finished\\|exited" event)
         (let* ((test-buf (process-buffer proc))
                (summary (jejeje--parse-test-summary test-buf)))
           (with-current-buffer test-buf
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (unless (bolp) (insert "\n"))
               (insert (propertize (format "[%s]" summary) 'face 'shadow))))
           (message "jejeje: %s" summary)))))))

;;;###autoload
(defun jejeje-info ()
  "Run `je info' and display contest metadata in the output buffer.
Walks up from `default-directory' to find `.je-meta.json'."
  (interactive)
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
             (message "jejeje: info loaded")
           (message "jejeje: `je info' failed — no .je-meta.json found? See %s"
                    jejeje-buffer-name)))))))


;;; ─── Transient menu ───────────────────────────────────────────────────────────

(transient-define-prefix jejeje-menu ()
  "Transient menu for jejeje — competitive programming helper."
  ["jejeje"
   ["Contest"
    ("p" "Prepare samples"  jejeje-prepare)
    ("i" "Contest info"     jejeje-info)]
   ["Test"
    ("t" "Run tests"        jejeje-test)]
   ])


;;; ─── Key map ──────────────────────────────────────────────────────────────────

;;;###autoload
(defvar jejeje-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'jejeje-prepare)
    (define-key map (kbd "t") #'jejeje-test)
    (define-key map (kbd "i") #'jejeje-info)
    (define-key map (kbd "m") #'jejeje-menu)
    map)
  "Prefix key map for jejeje commands.
Bind this to a convenient prefix, e.g.:
  (global-set-key (kbd \"C-c j\") jejeje-map)")


;;; ─── Footer ───────────────────────────────────────────────────────────────────

(provide 'jejeje)
;;; jejeje.el ends here
