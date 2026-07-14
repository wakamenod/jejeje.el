;;; jejeje-test.el --- ERT tests for jejeje.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  jun

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT test suite for jejeje.el.
;; Run with: eask ert test/*.el
;;   or interactively: M-x ert RET t RET

;;; Code:

(require 'ert)
(require 'jejeje)


;;; ─── jejeje--ansi-strip ───────────────────────────────────────────────────────

(ert-deftest jejeje-ansi-strip/removes-color-codes ()
  "ANSI colour escape sequences are removed."
  (should (equal "AC" (jejeje--ansi-strip "\e[32mAC\e[0m")))
  (should (equal "WA" (jejeje--ansi-strip "\e[31mWA\e[0m")))
  (should (equal "TLE" (jejeje--ansi-strip "\e[33mTLE\e[0m"))))

(ert-deftest jejeje-ansi-strip/removes-bold-and-reset ()
  "Bold and reset sequences are stripped."
  (should (equal "hello" (jejeje--ansi-strip "\e[1mhello\e[0m"))))

(ert-deftest jejeje-ansi-strip/no-escape-passthrough ()
  "Strings without ANSI codes are returned unchanged."
  (should (equal "plain text" (jejeje--ansi-strip "plain text")))
  (should (equal "" (jejeje--ansi-strip ""))))

(ert-deftest jejeje-ansi-strip/mixed-content ()
  "Mixed ANSI and plain text is handled correctly."
  (should (equal "foo: AC  (1.23s)"
                 (jejeje--ansi-strip "foo: \e[32mAC\e[0m  (1.23s)"))))


;;; ─── jejeje--parse-test-summary ──────────────────────────────────────────────

(defmacro jejeje-test--with-buffer-content (content &rest body)
  "Evaluate BODY inside a temp buffer pre-filled with CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     ,@body))

(ert-deftest jejeje-parse-test-summary/all-passed ()
  "\"All N tests passed\" yields the success string."
  (jejeje-test--with-buffer-content
      "sample_00: AC  (0.05s)\nAll 3 tests passed!\n"
    (should (equal "✓ All 3 tests passed!"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/all-passed-singular ()
  "Works when N = 1."
  (jejeje-test--with-buffer-content
      "sample_00: AC  (0.01s)\nAll 1 tests passed!\n"
    (should (equal "✓ All 1 tests passed!"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/partial-passed ()
  "\"N / M passed\" yields the partial string."
  (jejeje-test--with-buffer-content
      "sample_00: AC\nsample_01: WA\n2 / 3 passed\n"
    (should (equal "2 / 3 passed"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/zero-passed ()
  "\"0 / M passed\" is handled."
  (jejeje-test--with-buffer-content
      "sample_00: WA\n0 / 1 passed\n"
    (should (equal "0 / 1 passed"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/no-match-fallback ()
  "Buffer without a recognisable summary returns the fallback string."
  (jejeje-test--with-buffer-content
      "Something went wrong.\n"
    (should (equal "je test complete"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/empty-buffer-fallback ()
  "Empty buffer returns the fallback string."
  (jejeje-test--with-buffer-content
      ""
    (should (equal "je test complete"
                   (jejeje--parse-test-summary (current-buffer))))))

(ert-deftest jejeje-parse-test-summary/all-passed-takes-priority ()
  "\"All N tests passed\" is preferred over \"N / M passed\" when both appear."
  (jejeje-test--with-buffer-content
      "3 / 3 passed\nAll 3 tests passed!\n"
    (should (string-prefix-p "✓ All"
                             (jejeje--parse-test-summary (current-buffer))))))


;;; ─── jejeje--get-output-buffer ───────────────────────────────────────────────

(ert-deftest jejeje-get-output-buffer/creates-buffer ()
  "A buffer with the default name is returned."
  (let ((buf (jejeje--get-output-buffer)))
    (unwind-protect
        (should (buffer-live-p buf))
      (kill-buffer buf))))

(ert-deftest jejeje-get-output-buffer/uses-default-name ()
  "The returned buffer is named after `jejeje-buffer-name'."
  (let ((buf (jejeje--get-output-buffer)))
    (unwind-protect
        (should (equal jejeje-buffer-name (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest jejeje-get-output-buffer/accepts-custom-name ()
  "A custom NAME is used when supplied."
  (let* ((name "*jejeje-test-tmp*")
         (buf (jejeje--get-output-buffer name)))
    (unwind-protect
        (should (equal name (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest jejeje-get-output-buffer/clears-existing-content ()
  "Calling the function twice erases previous content."
  (let ((buf (jejeje--get-output-buffer "*jejeje-clear-test*")))
    (unwind-protect
        (progn
          ;; Write something into the buffer.
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert "stale content")))
          ;; A second call must clear it.
          (jejeje--get-output-buffer "*jejeje-clear-test*")
          (with-current-buffer buf
            (should (equal "" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest jejeje-get-output-buffer/clears-readonly-buffer ()
  "Content is erased even when the buffer is read-only beforehand."
  (let ((buf (jejeje--get-output-buffer "*jejeje-ro-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (insert "old data"))
            (read-only-mode 1))
          (jejeje--get-output-buffer "*jejeje-ro-test*")
          (with-current-buffer buf
            (should (equal "" (buffer-string)))))
      (kill-buffer buf))))


;;; ─── jejeje--default-sentinel ────────────────────────────────────────────────

(defun jejeje-test--make-dummy-process (buf)
  "Return a pipe process whose `process-buffer' is BUF.
Uses `make-pipe-process' so no external command is spawned — safe in
batch/ERT mode."
  (make-pipe-process :name "jejeje-test-dummy"
                     :buffer buf
                     :noquery t))

(ert-deftest jejeje-default-sentinel/finished-footer ()
  "\"finished\" event inserts the expected footer."
  (let* ((buf (generate-new-buffer "*jejeje-sentinel-test*"))
         (proc (jejeje-test--make-dummy-process buf)))
    (unwind-protect
        (progn
          (jejeje--default-sentinel proc "finished\n")
          (with-current-buffer buf
            (should (string-match-p "\\[je exited — finished\\]"
                                    (buffer-string)))))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest jejeje-default-sentinel/exited-footer ()
  "\"exited\" event inserts the expected footer."
  (let* ((buf (generate-new-buffer "*jejeje-sentinel-test-2*"))
         (proc (jejeje-test--make-dummy-process buf)))
    (unwind-protect
        (progn
          (jejeje--default-sentinel proc "exited abnormally with code 1\n")
          (with-current-buffer buf
            (should (string-match-p "\\[je exited — exited abnormally with code 1\\]"
                                    (buffer-string)))))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest jejeje-default-sentinel/ignores-unrelated-events ()
  "Events that are neither \"finished\" nor \"exited\" are ignored."
  (let* ((buf (generate-new-buffer "*jejeje-sentinel-test-3*"))
         (proc (jejeje-test--make-dummy-process buf)))
    (unwind-protect
        (progn
          (jejeje--default-sentinel proc "run\n")
          (with-current-buffer buf
            (should (equal "" (buffer-string)))))
      (delete-process proc)
      (kill-buffer buf))))


;;; ─── jejeje--auto-command ────────────────────────────────────────────────────

;; Helpers ─────────────────────────────────────────────────────────────────────

(defmacro jejeje-test--with-mocked-quickrun (key exec &rest body)
  "Evaluate BODY with quickrun internals mocked for a single-step language.

KEY     - value returned by `quickrun--command-key'
EXEC    - value of :exec in the command info alist (string or list of strings)

`quickrun--template-argument' is stubbed to return a minimal spec list that
maps %s → the buffer-file-name and %o → a fixed output path, mirroring the
real quickrun behaviour closely enough for `jejeje--auto-command' to exercise
the format-spec expansion path."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'quickrun--command-key)
               (lambda (_file) ,key))
              ((symbol-function 'quickrun--command-info)
               (lambda (_key) `((:exec . ,,exec))))
              ((symbol-function 'quickrun--template-argument)
               (lambda (_alist file)
                 ;; Return the same (%s . FILE) (%o . OUTFILE) pairs that
                 ;; quickrun itself would build.
                 (list (cons "%s" file)
                       (cons "%o" (concat (file-name-sans-extension file)
                                          ".out"))))))
     ,@body))

(defmacro jejeje-test--with-file-buffer (filename &rest body)
  "Evaluate BODY in a temporary buffer whose `buffer-file-name' is FILENAME."
  (declare (indent 1))
  `(with-temp-buffer
     (setq buffer-file-name ,filename)
     ,@body))

;; Tests — interpreter / single-step exec ─────────────────────────────────────

(ert-deftest jejeje-auto-command/python-no-compile ()
  "Python (single-step exec) → compile-cmd is nil, run-cmd contains python."
  (jejeje-test--with-file-buffer "/tmp/sol.py"
    (jejeje-test--with-mocked-quickrun "python" "python %s"
      (let ((result (jejeje--auto-command)))
        (should (null (car result)))
        (should (string-match-p "python" (cdr result)))
        (should (string-match-p "sol\\.py" (cdr result)))))))

(ert-deftest jejeje-auto-command/ruby-no-compile ()
  "Ruby (single-step exec) → compile-cmd is nil, run-cmd contains ruby."
  (jejeje-test--with-file-buffer "/tmp/sol.rb"
    (jejeje-test--with-mocked-quickrun "ruby" "ruby %s"
      (let ((result (jejeje--auto-command)))
        (should (null (car result)))
        (should (string-match-p "ruby" (cdr result)))))))

(ert-deftest jejeje-auto-command/run-cmd-expands-source-file ()
  "The %s placeholder in exec is expanded to the actual file path."
  (jejeje-test--with-file-buffer "/tmp/foo.py"
    (jejeje-test--with-mocked-quickrun "python" "python %s"
      (let ((result (jejeje--auto-command)))
        (should (equal "python /tmp/foo.py" (cdr result)))))))

;; Tests — compiler / multi-step exec ─────────────────────────────────────────

(ert-deftest jejeje-auto-command/c++-has-compile-step ()
  "C++ (multi-step exec) → compile-cmd is a non-empty string."
  (jejeje-test--with-file-buffer "/tmp/sol.cpp"
    (jejeje-test--with-mocked-quickrun "c++" '("g++ -o %o %s" "%o")
      (let ((result (jejeje--auto-command)))
        (should (stringp (car result)))
        (should (not (string-empty-p (car result))))))))

(ert-deftest jejeje-auto-command/c++-run-cmd-is-binary ()
  "C++ run-cmd is the expanded output binary path, not the source file."
  (jejeje-test--with-file-buffer "/tmp/sol.cpp"
    (jejeje-test--with-mocked-quickrun "c++" '("g++ -o %o %s" "%o")
      (let* ((result  (jejeje--auto-command))
             (run-cmd (cdr result)))
        ;; run-cmd must be the %o expansion, NOT the .cpp file
        (should (string-match-p "\\.out$" run-cmd))
        (should (not (string-match-p "\\.cpp" run-cmd)))))))

(ert-deftest jejeje-auto-command/c++-compile-cmd-contains-source ()
  "C++ compile-cmd includes the source file path."
  (jejeje-test--with-file-buffer "/tmp/sol.cpp"
    (jejeje-test--with-mocked-quickrun "c++" '("g++ -o %o %s" "%o")
      (let ((compile-cmd (car (jejeje--auto-command))))
        (should (string-match-p "sol\\.cpp" compile-cmd))))))

(ert-deftest jejeje-auto-command/three-step-exec-last-is-runner ()
  "When exec has three steps the last one becomes run-cmd."
  ;; E.g. javac → jar → java  (hypothetical)
  (jejeje-test--with-file-buffer "/tmp/sol.java"
    (jejeje-test--with-mocked-quickrun "java" '("javac %s" "jar cf %o.jar %o" "java %o")
      (let* ((result  (jejeje--auto-command))
             (run-cmd (cdr result))
             (compile (car result)))
        (should (string-match-p "java " run-cmd))
        ;; compile-cmd must include both first two steps joined by " && "
        (should (string-match-p "&&" compile))
        (should (string-match-p "javac" compile))
        (should (string-match-p "jar" compile))))))

;; Tests — error conditions ────────────────────────────────────────────────────

(ert-deftest jejeje-auto-command/no-file-errors ()
  "Signals `user-error' when the current buffer has no associated file."
  (with-temp-buffer
    ;; buffer-file-name is nil by default in temp buffers
    (should-error (jejeje--auto-command) :type 'user-error)))

(ert-deftest jejeje-auto-command/unknown-extension-errors ()
  "Signals `user-error' when quickrun has no mapping for the file."
  (jejeje-test--with-file-buffer "/tmp/sol.unknownlang"
    (cl-letf (((symbol-function 'quickrun--command-key)
               (lambda (_file) nil)))  ; nil = no mapping
      (should-error (jejeje--auto-command) :type 'user-error))))


;;; ─── Helpers for filesystem-based tests ──────────────────────────────────────

(defmacro jejeje-test--with-temp-dir (&rest body)
  "Evaluate BODY with `default-directory' set to a fresh temporary directory.
The directory and its contents are deleted with `delete-directory' after BODY
exits (normally or via a non-local exit)."
  (declare (indent 0))
  (let ((dir-sym (gensym "jejeje-test-dir")))
    `(let ((,dir-sym (make-temp-file "jejeje-test-" t)))
       (unwind-protect
           (let ((default-directory (file-name-as-directory ,dir-sym)))
             ,@body)
         (delete-directory ,dir-sym t)))))

(defun jejeje-test--write-file (path content)
  "Write string CONTENT to PATH, creating parent directories as needed."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert content)))

(defconst jejeje-test--sample-meta-json
  (json-encode
   `((judge        . "atcoder")
     (contest_id   . "abc001")
     (contest_name . "AtCoder Beginner Contest 001")
     (url          . "https://atcoder.jp/contests/abc001")
     (tasks        . [((id  . "a")
                       (name . "Two Sum")
                       (url  . "https://atcoder.jp/contests/abc001/tasks/abc001_a"))
                      ((id  . "b")
                       (name . "Difference")
                       (url  . "https://atcoder.jp/contests/abc001/tasks/abc001_b"))])))
  "Canonical sample `.je-meta.json' content used across multiple tests.")


;;; ─── jejeje--find-meta-json ───────────────────────────────────────────────────

(ert-deftest jejeje-find-meta-json/found-in-current-dir ()
  "Returns the path when `.je-meta.json' exists in `default-directory'."
  (jejeje-test--with-temp-dir
    (let ((meta (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file meta "{}")
      (should (equal meta (jejeje--find-meta-json))))))

(ert-deftest jejeje-find-meta-json/found-in-parent-dir ()
  "Returns the path when `.je-meta.json' lives one level up."
  (jejeje-test--with-temp-dir
    (let* ((meta (expand-file-name ".je-meta.json" default-directory))
           (sub  (file-name-as-directory (expand-file-name "a" default-directory))))
      (jejeje-test--write-file meta "{}")
      (make-directory sub t)
      (let ((default-directory sub))
        (should (equal meta (jejeje--find-meta-json)))))))

(ert-deftest jejeje-find-meta-json/found-two-levels-up ()
  "Returns the path when `.je-meta.json' is two directories above."
  (jejeje-test--with-temp-dir
    (let* ((meta   (expand-file-name ".je-meta.json" default-directory))
           (nested (file-name-as-directory
                    (expand-file-name "abc001/a" default-directory))))
      (jejeje-test--write-file meta "{}")
      (make-directory nested t)
      (let ((default-directory nested))
        (should (equal meta (jejeje--find-meta-json)))))))

(ert-deftest jejeje-find-meta-json/returns-nil-when-absent ()
  "Returns nil when `.je-meta.json' cannot be found in any ancestor."
  (jejeje-test--with-temp-dir
    ;; No .je-meta.json written — should return nil without signalling.
    (should (null (jejeje--find-meta-json)))))


;;; ─── jejeje--read-meta-json ───────────────────────────────────────────────────

(ert-deftest jejeje-read-meta-json/returns-hash-table ()
  "Parses valid JSON and returns a hash-table."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file path jejeje-test--sample-meta-json)
      (let ((result (jejeje--read-meta-json path)))
        (should (hash-table-p result))))))

(ert-deftest jejeje-read-meta-json/top-level-fields ()
  "Top-level fields (judge, contest_id, url) are accessible by string keys."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file path jejeje-test--sample-meta-json)
      (let ((result (jejeje--read-meta-json path)))
        (should (equal "atcoder"  (gethash "judge"      result)))
        (should (equal "abc001"   (gethash "contest_id" result)))
        (should (equal "https://atcoder.jp/contests/abc001"
                       (gethash "url" result)))))))

(ert-deftest jejeje-read-meta-json/tasks-is-array ()
  "The `tasks' field is parsed as an array (vector)."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file path jejeje-test--sample-meta-json)
      (let ((result (jejeje--read-meta-json path)))
        (should (arrayp (gethash "tasks" result)))))))

(ert-deftest jejeje-read-meta-json/task-fields ()
  "Each task element exposes `id', `name', and `url' as string keys."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file path jejeje-test--sample-meta-json)
      (let* ((result (jejeje--read-meta-json path))
             (task-a (aref (gethash "tasks" result) 0)))
        (should (equal "a"        (gethash "id"   task-a)))
        (should (equal "Two Sum"  (gethash "name" task-a)))
        (should (equal "https://atcoder.jp/contests/abc001/tasks/abc001_a"
                       (gethash "url" task-a)))))))

(ert-deftest jejeje-read-meta-json/invalid-json-signals-user-error ()
  "Signals `user-error' for malformed JSON."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name ".je-meta.json" default-directory)))
      (jejeje-test--write-file path "{ not valid json }")
      (should-error (jejeje--read-meta-json path) :type 'user-error))))

(ert-deftest jejeje-read-meta-json/missing-file-signals-user-error ()
  "Signals `user-error' when the file does not exist."
  (jejeje-test--with-temp-dir
    (let ((path (expand-file-name "nonexistent.json" default-directory)))
      (should-error (jejeje--read-meta-json path) :type 'user-error))))


;;; ─── jejeje--current-task-id ─────────────────────────────────────────────────

(ert-deftest jejeje-current-task-id/returns-innermost-dir-name ()
  "Returns the name of the innermost directory."
  (jejeje-test--with-temp-dir
    (let* ((sub (file-name-as-directory (expand-file-name "a" default-directory))))
      (make-directory sub t)
      (let ((default-directory sub))
        (should (equal "a" (jejeje--current-task-id)))))))

(ert-deftest jejeje-current-task-id/trailing-slash-stripped ()
  "A trailing slash in `default-directory' does not affect the result."
  (jejeje-test--with-temp-dir
    (let* ((sub (expand-file-name "b/" default-directory)))
      (make-directory sub t)
      (let ((default-directory sub))
        (should (equal "b" (jejeje--current-task-id)))))))

(ert-deftest jejeje-current-task-id/preserves-case ()
  "The function does not alter the case of the directory name."
  (jejeje-test--with-temp-dir
    (let* ((sub (file-name-as-directory
                 (expand-file-name "ITP1_1_A" default-directory))))
      (make-directory sub t)
      (let ((default-directory sub))
        (should (equal "ITP1_1_A" (jejeje--current-task-id)))))))

(ert-deftest jejeje-current-task-id/nested-path ()
  "Only the leaf directory name is returned, not the full path."
  (jejeje-test--with-temp-dir
    (let* ((sub (file-name-as-directory
                 (expand-file-name "abc001/c" default-directory))))
      (make-directory sub t)
      (let ((default-directory sub))
        (should (equal "c" (jejeje--current-task-id)))))))


;;; ─── jejeje-browse-problem ────────────────────────────────────────────────────

(defmacro jejeje-test--with-browse-spy (open-fn-sym &rest body)
  "Evaluate BODY with a spy capturing calls to OPEN-FN-SYM.
After BODY, the variable `jejeje-test--browse-calls' holds a list of URLs
that were passed to OPEN-FN-SYM."
  (declare (indent 1))
  `(let (jejeje-test--browse-calls)
     (cl-letf (((symbol-function ,open-fn-sym)
                (lambda (url)
                  (push url jejeje-test--browse-calls))))
       ,@body)))

(defmacro jejeje-test--with-browse-problem-env (task-id &rest body)
  "Set up a temp dir with `.je-meta.json' and `default-directory' as TASK-ID sub-dir.
Evaluates BODY inside that sub-directory."
  (declare (indent 1))
  `(jejeje-test--with-temp-dir
     (jejeje-test--write-file
      (expand-file-name ".je-meta.json" default-directory)
      jejeje-test--sample-meta-json)
     (let* ((sub (file-name-as-directory
                  (expand-file-name ,task-id default-directory))))
       (make-directory sub t)
       (let ((default-directory sub))
         ,@body))))

(ert-deftest jejeje-browse-problem/opens-matching-task-url ()
  "Opens the task URL whose `id' matches the current directory name."
  (jejeje-test--with-browse-problem-env "a"
    (jejeje-test--with-browse-spy 'browse-url
      (cl-letf (((symbol-function 'xwidget-webkit-browse-url) nil))
        (jejeje-browse-problem))
      (should (equal '("https://atcoder.jp/contests/abc001/tasks/abc001_a")
                     jejeje-test--browse-calls)))))

(ert-deftest jejeje-browse-problem/second-task ()
  "Opens the correct task URL for the second problem."
  (jejeje-test--with-browse-problem-env "b"
    (jejeje-test--with-browse-spy 'browse-url
      (cl-letf (((symbol-function 'xwidget-webkit-browse-url) nil))
        (jejeje-browse-problem))
      (should (equal '("https://atcoder.jp/contests/abc001/tasks/abc001_b")
                     jejeje-test--browse-calls)))))

(ert-deftest jejeje-browse-problem/fallback-to-contest-url-when-no-task-match ()
  "Falls back to the contest URL when the directory name matches no task id."
  (jejeje-test--with-browse-problem-env "z"   ; "z" is not in the tasks list
    (jejeje-test--with-browse-spy 'browse-url
      (cl-letf (((symbol-function 'xwidget-webkit-browse-url) nil))
        (jejeje-browse-problem))
      (should (equal '("https://atcoder.jp/contests/abc001")
                     jejeje-test--browse-calls)))))

(ert-deftest jejeje-browse-problem/case-insensitive-task-match ()
  "Task id matching is case-insensitive (directory \"A\" matches task id \"a\")."
  (jejeje-test--with-browse-problem-env "A"
    (jejeje-test--with-browse-spy 'browse-url
      (cl-letf (((symbol-function 'xwidget-webkit-browse-url) nil))
        (jejeje-browse-problem))
      (should (equal '("https://atcoder.jp/contests/abc001/tasks/abc001_a")
                     jejeje-test--browse-calls)))))

(ert-deftest jejeje-browse-problem/prefers-xwidget-when-available ()
  "Uses `xwidget-webkit-browse-url' when the function is bound."
  (jejeje-test--with-browse-problem-env "a"
    (jejeje-test--with-browse-spy 'xwidget-webkit-browse-url
      ;; Make xwidget-webkit-browse-url appear to be defined.
      (cl-letf (((symbol-function 'xwidget-webkit-browse-url)
                 (lambda (url) (push url jejeje-test--browse-calls))))
        (jejeje-browse-problem))
      (should (equal '("https://atcoder.jp/contests/abc001/tasks/abc001_a")
                     jejeje-test--browse-calls)))))

(ert-deftest jejeje-browse-problem/falls-back-to-browse-url-without-xwidget ()
  "Falls back to `browse-url' when `xwidget-webkit-browse-url' is unbound."
  (jejeje-test--with-browse-problem-env "a"
    (let (called-url)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (setq called-url url))))
        ;; Temporarily unbind xwidget-webkit-browse-url if it exists.
        (if (fboundp 'xwidget-webkit-browse-url)
            (cl-letf (((symbol-function 'xwidget-webkit-browse-url) nil))
              (jejeje-browse-problem))
          (jejeje-browse-problem)))
      (should (equal "https://atcoder.jp/contests/abc001/tasks/abc001_a"
                     called-url)))))

(ert-deftest jejeje-browse-problem/signals-error-when-no-meta-json ()
  "Signals `user-error' when no `.je-meta.json' can be found."
  (jejeje-test--with-temp-dir
    ;; No .je-meta.json written.
    (should-error (jejeje-browse-problem) :type 'user-error)))


;;; ─── jejeje--posframe-available-p ────────────────────────────────────────────

(ert-deftest jejeje-posframe-available-p/returns-nil-when-not-installed ()
  "Returns nil when posframe is not available as a feature."
  (cl-letf (((symbol-function 'require)
             ;; Soft-load always silently fails for posframe
             (lambda (feature &optional _file noerror)
               (unless noerror
                 (signal 'file-error (list "Cannot open load file" feature)))))
            ((symbol-function 'featurep)
             (lambda (feature &optional _sub)
               (if (eq feature 'posframe) nil t))))
    (should-not (jejeje--posframe-available-p))))

(ert-deftest jejeje-posframe-available-p/returns-non-nil-when-installed ()
  "Returns non-nil when posframe is registered as a feature."
  (cl-letf (((symbol-function 'require)
             (lambda (_feature &rest _) nil))
            ((symbol-function 'featurep)
             (lambda (feature &optional _sub)
               (if (eq feature 'posframe) t nil))))
    (should (jejeje--posframe-available-p))))


;;; ─── jejeje--buffer-visible-p ────────────────────────────────────────────────

(ert-deftest jejeje-buffer-visible-p/returns-nil-when-not-displayed ()
  "Returns nil when the buffer has no visible window."
  (let ((buf (generate-new-buffer "*jejeje-vis-nil-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (_buf _frame) nil)))
          (should-not (jejeje--buffer-visible-p buf)))
      (kill-buffer buf))))

(ert-deftest jejeje-buffer-visible-p/returns-non-nil-when-displayed ()
  "Returns non-nil when the buffer has a visible window."
  (let ((buf (generate-new-buffer "*jejeje-vis-t-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   ;; Return any non-nil value to simulate a live window
                   (lambda (_buf _frame) (selected-window))))
          (should (jejeje--buffer-visible-p buf)))
      (kill-buffer buf))))

(ert-deftest jejeje-buffer-visible-p/passes-visible-selector ()
  "Calls `get-buffer-window' with the \\='visible frame selector."
  (let ((buf (generate-new-buffer "*jejeje-vis-sel-test*"))
        captured-frame)
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (_buf frame)
                     (setq captured-frame frame)
                     nil)))
          (jejeje--buffer-visible-p buf)
          (should (eq 'visible captured-frame)))
      (kill-buffer buf))))


;;; ─── jejeje--show-output-buffer ──────────────────────────────────────────────

(ert-deftest jejeje-show-output-buffer/buffer-method-calls-display-buffer ()
  "With method \\='buffer, calls `display-buffer' with the target buffer."
  (let ((buf (generate-new-buffer "*jejeje-show-buf-test*"))
        displayed)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (b &rest _) (setq displayed b))))
          (jejeje--show-output-buffer buf 'buffer)
          (should (eq buf displayed)))
      (kill-buffer buf))))

(ert-deftest jejeje-show-output-buffer/unknown-method-falls-back-to-display-buffer ()
  "An unrecognised method falls through to `display-buffer'."
  (let ((buf (generate-new-buffer "*jejeje-show-unk-test*"))
        called)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (_b &rest _) (setq called t))))
          (jejeje--show-output-buffer buf 'something-unknown)
          (should called))
      (kill-buffer buf))))

(ert-deftest jejeje-show-output-buffer/posframe-method-calls-posframe-show ()
  "With method \\='posframe, calls `posframe-show' with the target buffer."
  (let ((buf (generate-new-buffer "*jejeje-show-pf-test*"))
        shown-buf)
    (unwind-protect
        (cl-letf (((symbol-function 'posframe-workable-p)   (lambda ()       nil))
                  ((symbol-function 'posframe-hide)          #'ignore)
                  ((symbol-function 'posframe-poshandler-frame-center) (lambda (_) nil))
                  ((symbol-function 'posframe-show)
                   (lambda (b &rest _) (setq shown-buf b))))
          (jejeje--show-output-buffer buf 'posframe)
          (should (eq buf shown-buf)))
      (kill-buffer buf))))

(ert-deftest jejeje-show-output-buffer/posframe-hides-stale-frame-when-workable ()
  "With method \\='posframe and `posframe-workable-p' returning t, the old
frame is hidden before showing a new one."
  (let ((buf (generate-new-buffer "*jejeje-show-pf-hide-test*"))
        hide-called)
    (unwind-protect
        (cl-letf (((symbol-function 'posframe-workable-p)   (lambda ()       t))
                  ((symbol-function 'posframe-hide)
                   (lambda (_b) (setq hide-called t)))
                  ((symbol-function 'posframe-poshandler-frame-center) (lambda (_) nil))
                  ((symbol-function 'posframe-show)          #'ignore))
          (jejeje--show-output-buffer buf 'posframe)
          (should hide-called))
      (kill-buffer buf))))

(ert-deftest jejeje-show-output-buffer/posframe-skips-hide-when-not-workable ()
  "With method \\='posframe and `posframe-workable-p' returning nil,
`posframe-hide' is NOT called."
  (let ((buf (generate-new-buffer "*jejeje-show-pf-nohide-test*"))
        hide-called)
    (unwind-protect
        (cl-letf (((symbol-function 'posframe-workable-p)   (lambda ()       nil))
                  ((symbol-function 'posframe-hide)
                   (lambda (_b) (setq hide-called t)))
                  ((symbol-function 'posframe-poshandler-frame-center) (lambda (_) nil))
                  ((symbol-function 'posframe-show)          #'ignore))
          (jejeje--show-output-buffer buf 'posframe)
          (should-not hide-called))
      (kill-buffer buf))))

(ert-deftest jejeje-show-output-buffer/posframe-method-binds-q-to-hide ()
  "With method \\='posframe, the \\='q\\=' key in the buffer hides the frame
without killing the buffer."
  (let ((buf (generate-new-buffer "*jejeje-show-pf-q-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'posframe-workable-p)   (lambda ()       nil))
                  ((symbol-function 'posframe-hide)          #'ignore)
                  ((symbol-function 'posframe-poshandler-frame-center) (lambda (_) nil))
                  ((symbol-function 'posframe-show)          #'ignore))
          (jejeje--show-output-buffer buf 'posframe)
          (with-current-buffer buf
            (should (commandp (lookup-key (current-local-map) (kbd "q"))))))
      (kill-buffer buf))))


;;; ─── jejeje-test — display method selection ──────────────────────────────────

;; All tests in this section mock out `jejeje--auto-command' (so no real file
;; or quickrun look-up is needed) and `jejeje--run' (so no process is spawned).
;; This lets us focus purely on the display-method selection logic.

(defmacro jejeje-test--with-mocked-run (&rest body)
  "Evaluate BODY with the process-spawning internals stubbed out.
`jejeje--auto-command' returns a no-compile Python invocation;
`jejeje--run' is a no-op."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'jejeje--auto-command)
              (lambda () (cons nil "python /tmp/sol.py")))
             ((symbol-function 'jejeje--run)
              (lambda (_args _buf &optional _sentinel) nil)))
     ,@body))

(ert-deftest jejeje-test/skips-show-when-buffer-already-visible ()
  "Does not call `jejeje--show-output-buffer' when the output buffer is
already displayed in a window."
  (let (show-called)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)
                 (lambda (_buf) t))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf _method) (setq show-called t))))
        (jejeje-test)
        (should-not show-called)))))

(ert-deftest jejeje-test/uses-posframe-when-available-and-configured ()
  "Calls `jejeje--show-output-buffer' with \\='posframe when posframe is
installed and `jejeje-test-display-method' is \\='posframe."
  (let (effective-method)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)   (lambda (_) nil))
                ((symbol-function 'jejeje--posframe-available-p) (lambda ()  t))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf method) (setq effective-method method))))
        (let ((jejeje-test-display-method 'posframe))
          (jejeje-test)
          (should (eq 'posframe effective-method)))))))

(ert-deftest jejeje-test/falls-back-to-buffer-when-posframe-unavailable ()
  "Falls back to \\='buffer when `jejeje-test-display-method' is \\='posframe
but posframe is not installed."
  (let (effective-method)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)   (lambda (_) nil))
                ((symbol-function 'jejeje--posframe-available-p) (lambda () nil))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf method) (setq effective-method method))))
        (let ((jejeje-test-display-method 'posframe))
          (jejeje-test)
          (should (eq 'buffer effective-method)))))))

(ert-deftest jejeje-test/uses-buffer-when-display-method-is-buffer ()
  "Uses \\='buffer when `jejeje-test-display-method' is set to \\='buffer,
even if posframe is installed."
  (let (effective-method)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)   (lambda (_) nil))
                ((symbol-function 'jejeje--posframe-available-p) (lambda ()  t))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf method) (setq effective-method method))))
        (let ((jejeje-test-display-method 'buffer))
          (jejeje-test)
          (should (eq 'buffer effective-method)))))))

(ert-deftest jejeje-test/explicit-display-method-takes-priority ()
  "An explicit DISPLAY-METHOD argument overrides all automatic logic,
including an already-visible buffer."
  (let (effective-method)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)   (lambda (_) t))
                ((symbol-function 'jejeje--posframe-available-p) (lambda () nil))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf method) (setq effective-method method))))
        ;; Pass 'posframe explicitly even though the buffer appears visible
        ;; and posframe is "unavailable" — explicit arg wins.
        (jejeje-test nil 'posframe)
        (should (eq 'posframe effective-method))))))

(ert-deftest jejeje-test/explicit-buffer-method-overrides-posframe-config ()
  "Passing \\='buffer explicitly forces buffer display even when posframe
is installed and `jejeje-test-display-method' is \\='posframe."
  (let (effective-method)
    (jejeje-test--with-mocked-run
      (cl-letf (((symbol-function 'jejeje--buffer-visible-p)   (lambda (_) nil))
                ((symbol-function 'jejeje--posframe-available-p) (lambda ()  t))
                ((symbol-function 'jejeje--show-output-buffer)
                 (lambda (_buf method) (setq effective-method method))))
        (let ((jejeje-test-display-method 'posframe))
          (jejeje-test nil 'buffer)
          (should (eq 'buffer effective-method)))))))


;;; ─── jejeje--js-string ───────────────────────────────────────────────────────

(ert-deftest jejeje-js-string/plain-string ()
  "Plain ASCII string is wrapped in double quotes."
  (should (equal "\"hello\"" (jejeje--js-string "hello"))))

(ert-deftest jejeje-js-string/empty-string ()
  "Empty string produces an empty JS string literal."
  (should (equal "\"\"" (jejeje--js-string ""))))

(ert-deftest jejeje-js-string/escapes-double-quotes ()
  "Double quotes inside the string are escaped."
  (should (equal "\"say \\\"hi\\\"\"" (jejeje--js-string "say \"hi\""))))

(ert-deftest jejeje-js-string/escapes-backslashes ()
  "Backslashes are doubled."
  (should (equal "\"a\\\\b\"" (jejeje--js-string "a\\b"))))

(ert-deftest jejeje-js-string/escapes-newlines ()
  "Newlines are encoded as \\n."
  (should (equal "\"line1\\nline2\"" (jejeje--js-string "line1\nline2"))))

(ert-deftest jejeje-js-string/escapes-tabs ()
  "Tabs are encoded as \\t."
  (should (equal "\"a\\tb\"" (jejeje--js-string "a\tb"))))

(ert-deftest jejeje-js-string/handles-unicode ()
  "Unicode characters are preserved or escaped without error."
  ;; json-encode either keeps printable Unicode as-is or \uXXXX-escapes it;
  ;; either way the result must be a non-empty string starting with a quote.
  (let ((result (jejeje--js-string "日本語")))
    (should (stringp result))
    (should (string-prefix-p "\"" result))
    (should (string-suffix-p "\"" result))))

(ert-deftest jejeje-js-string/result-is-valid-for-interpolation ()
  "The output starts and ends with a double-quote (safe to embed in JS)."
  (dolist (s '("" "abc" "a\"b" "a\nb" "a\\b"))
    (let ((result (jejeje--js-string s)))
      (should (string-prefix-p "\"" result))
      (should (string-suffix-p "\"" result)))))


;;; ─── jejeje--detect-submit-backend ──────────────────────────────────────────

(ert-deftest jejeje-detect-submit-backend/atcoder-matches ()
  "AtCoder URLs are matched by the built-in backend."
  (should (jejeje--detect-submit-backend
           "https://atcoder.jp/contests/abc001/submit")))

(ert-deftest jejeje-detect-submit-backend/atcoder-with-query-string ()
  "AtCoder submit URL with taskScreenName query param is matched."
  (should (jejeje--detect-submit-backend
           "https://atcoder.jp/contests/abc001/submit?taskScreenName=abc001_a")))

(ert-deftest jejeje-detect-submit-backend/unknown-judge-returns-nil ()
  "An unrecognised URL returns nil."
  (should (null (jejeje--detect-submit-backend
                 "https://example.com/submit"))))

(ert-deftest jejeje-detect-submit-backend/empty-url-returns-nil ()
  "An empty URL string returns nil."
  (should (null (jejeje--detect-submit-backend ""))))

(ert-deftest jejeje-detect-submit-backend/returns-plist-with-required-keys ()
  "The returned plist contains all three required keys."
  (let ((plist (jejeje--detect-submit-backend
                "https://atcoder.jp/contests/abc001/submit")))
    (should plist)
    (should (plist-get plist :get-languages-js))
    (should (functionp (plist-get plist :set-language-js)))
    (should (functionp (plist-get plist :set-code-js)))))

(ert-deftest jejeje-detect-submit-backend/custom-backend-is-matched ()
  "A custom entry pushed onto `jejeje--submit-backend-alist' is detected."
  (let ((jejeje--submit-backend-alist
         (cons '("example\\.com"
                 :get-languages-js "[]"
                 :set-language-js  (lambda (_v) "")
                 :set-code-js      (lambda (_c) ""))
               jejeje--submit-backend-alist)))
    (should (jejeje--detect-submit-backend "https://example.com/submit"))))

(ert-deftest jejeje-detect-submit-backend/first-matching-entry-wins ()
  "When two entries match, the first one in the list is returned."
  (let* ((plist-a '(:get-languages-js "A" :set-language-js ignore :set-code-js ignore))
         (plist-b '(:get-languages-js "B" :set-language-js ignore :set-code-js ignore))
         (jejeje--submit-backend-alist
          `(("example\\.com" . ,plist-a)
            ("example"       . ,plist-b))))
    (let ((result (jejeje--detect-submit-backend "https://example.com/submit")))
      (should (equal "A" (plist-get result :get-languages-js))))))


;;; ─── AtCoder backend — :set-language-js ──────────────────────────────────────

(defun jejeje-test--atcoder-backend ()
  "Return the AtCoder submit backend plist from `jejeje--submit-backend-alist'."
  (jejeje--detect-submit-backend "https://atcoder.jp/contests/abc001/submit"))

(ert-deftest jejeje-atcoder-backend/set-language-js-is-function ()
  ":set-language-js value is callable."
  (should (functionp (plist-get (jejeje-test--atcoder-backend) :set-language-js))))

(ert-deftest jejeje-atcoder-backend/set-language-js-returns-string ()
  ":set-language-js called with a value returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-language-js))
         (result (funcall fn "5001")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-atcoder-backend/set-language-js-contains-selector ()
  ":set-language-js output references the AtCoder language select element."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-language-js))
         (result (funcall fn "5001")))
    (should (string-match-p "#select-lang" result))))

(ert-deftest jejeje-atcoder-backend/set-language-js-contains-value ()
  ":set-language-js output embeds the supplied language value."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-language-js))
         (result (funcall fn "5001")))
    (should (string-match-p "5001" result))))

(ert-deftest jejeje-atcoder-backend/set-language-js-dispatches-change-event ()
  ":set-language-js output fires a DOM change event."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-language-js))
         (result (funcall fn "5001")))
    (should (string-match-p "change" result))))

(ert-deftest jejeje-atcoder-backend/set-language-js-escapes-special-chars ()
  ":set-language-js embeds a value containing special chars without breaking JS."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-language-js))
         (result (funcall fn "C++ (GCC 9.2.1)")))
    (should (stringp result))
    ;; The language string must appear (JSON-encoded) somewhere in the output.
    ;; Use regexp-quote so +, (, ) are treated as literals.
    (should (string-match-p (regexp-quote "C++ (GCC 9.2.1)") result))))


;;; ─── AtCoder backend — :set-code-js ─────────────────────────────────────────

(ert-deftest jejeje-atcoder-backend/set-code-js-is-function ()
  ":set-code-js value is callable."
  (should (functionp (plist-get (jejeje-test--atcoder-backend) :set-code-js))))

(ert-deftest jejeje-atcoder-backend/set-code-js-returns-string ()
  ":set-code-js called with source code returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (result (funcall fn "print('hello')")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-atcoder-backend/set-code-js-references-ace-editor ()
  ":set-code-js output targets the ACE editor instance."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (result (funcall fn "print('hello')")))
    (should (string-match-p "ace\\.edit" result))))

(ert-deftest jejeje-atcoder-backend/set-code-js-calls-set-value ()
  ":set-code-js output calls ACE's setValue method."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (result (funcall fn "print('hello')")))
    (should (string-match-p "setValue" result))))

(ert-deftest jejeje-atcoder-backend/set-code-js-escapes-newlines-in-code ()
  "Source code containing newlines is safely embedded in the JS output."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (code "line1\nline2\nline3")
         (result (funcall fn code)))
    ;; The literal newline must not appear unescaped inside the JS string
    (should (not (string-match-p "\n" result)))))

(ert-deftest jejeje-atcoder-backend/set-code-js-escapes-backslashes ()
  "Source code containing backslashes is safely embedded in the JS output."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (result (funcall fn "path\\to\\file")))
    ;; Backslashes must be doubled: one backslash becomes \\
    (should (string-match-p "\\\\\\\\" result))))

(ert-deftest jejeje-atcoder-backend/set-code-js-escapes-double-quotes ()
  "Source code containing double quotes is safely embedded in the JS output."
  (let* ((fn (plist-get (jejeje-test--atcoder-backend) :set-code-js))
         (result (funcall fn "cout << \"hello\" << endl;")))
    (should (string-match-p "\\\\\"" result))))

;;; ─── AtCoder backend — :scroll-js ───────────────────────────────────────────

(ert-deftest jejeje-atcoder-backend/scroll-js-is-string ()
  ":scroll-js value is a non-empty string."
  (let ((js (plist-get (jejeje-test--atcoder-backend) :scroll-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-atcoder-backend/scroll-js-calls-scroll-to ()
  ":scroll-js invokes window.scrollTo."
  (let ((js (plist-get (jejeje-test--atcoder-backend) :scroll-js)))
    (should (string-match-p "scrollTo" js))))

(ert-deftest jejeje-atcoder-backend/scroll-js-scrolls-to-bottom ()
  ":scroll-js targets document.body.scrollHeight."
  (let ((js (plist-get (jejeje-test--atcoder-backend) :scroll-js)))
    (should (string-match-p "document\\.body\\.scrollHeight" js))))

(ert-deftest jejeje-codeforces-backend/no-scroll-js ()
  "Codeforces backend does not define :scroll-js (redirect handles navigation)."
  (should (null (plist-get (jejeje-test--codeforces-backend) :scroll-js))))


;;; ─── jejeje--get-xwidget-session ─────────────────────────────────────────────

(ert-deftest jejeje-get-xwidget-session/errors-when-xwidgets-unavailable ()
  "Signals `user-error' when `xwidget-webkit-current-session' is not bound."
  ;; Temporarily fmakunbound the symbol so fboundp returns nil naturally,
  ;; avoiding the infinite-recursion problem of mocking fboundp itself.
  (let ((was-bound (fboundp 'xwidget-webkit-current-session))
        (saved-fn  (and (fboundp 'xwidget-webkit-current-session)
                        (symbol-function 'xwidget-webkit-current-session))))
    (unwind-protect
        (progn
          (fmakunbound 'xwidget-webkit-current-session)
          (should-error (jejeje--get-xwidget-session) :type 'user-error))
      ;; Restore the original binding if it existed.
      (when was-bound
        (fset 'xwidget-webkit-current-session saved-fn)))))

(ert-deftest jejeje-get-xwidget-session/errors-when-no-xwidget-window ()
  "Signals `user-error' when no window is in `xwidget-webkit-mode'."
  ;; xwidget-webkit-current-session is considered available; but window-list
  ;; returns only a window whose buffer is NOT in xwidget-webkit-mode.
  (cl-letf (((symbol-function 'xwidget-webkit-current-session)
             (lambda () (error "should not be called")))
            ((symbol-function 'window-list)
             (lambda () (list (selected-window))))
            ((symbol-function 'derived-mode-p)
             (lambda (&rest _modes) nil)))
    ;; Ensure xwidget-webkit-current-session appears bound.
    (should-error (jejeje--get-xwidget-session) :type 'user-error)))

(ert-deftest jejeje-get-xwidget-session/returns-session-from-xwidget-window ()
  "Returns the session object when an xwidget-webkit-mode window exists."
  (let* ((fake-session (list 'fake-xwidget-session))
         (fake-buf     (generate-new-buffer "*jejeje-xw-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'window-list)
                   (lambda () (list (selected-window))))
                  ((symbol-function 'window-buffer)
                   (lambda (_w) fake-buf))
                  ((symbol-function 'derived-mode-p)
                   (lambda (&rest _modes) t))
                  ((symbol-function 'xwidget-webkit-current-session)
                   (lambda () fake-session)))
          (with-current-buffer fake-buf
            (should (eq fake-session (jejeje--get-xwidget-session)))))
      (kill-buffer fake-buf))))


;;; ─── jejeje-submit-problem ───────────────────────────────────────────────────

;; Helper macro — mocks every xwidget and interactive dependency so that
;; jejeje-submit-problem can run synchronously in batch/ERT mode.

(defmacro jejeje-test--with-submit-mocks
    (url source-code chosen-language &rest body)
  "Evaluate BODY with all xwidget and interactive deps mocked for submit.

URL             - the fake URL returned by `xwidget-webkit-uri'
SOURCE-CODE     - the string that represents the current buffer content
CHOSEN-LANGUAGE - the display label the fake `completing-read' returns

Inside BODY the following dynamic variables are available:
  `jejeje-test--js-calls'   list of JS strings passed to execute-script
  `jejeje-test--lang-calls' list of :set-language-js outputs produced"
  (declare (indent 3))
  `(let ((jejeje-test--js-calls   nil)
         (jejeje-test--lang-calls nil)
         (fake-session (list 'fake-session)))
     (cl-letf
         (;; Mock session retrieval so we skip the real xwidget window search.
          ((symbol-function 'jejeje--get-xwidget-session)
           (lambda () fake-session))
          ;; current URL
          ((symbol-function 'xwidget-webkit-uri)
           (lambda (_s) ,url))
          ;; Intercept all JS injections; synchronously invoke callbacks so
          ;; the async language-list path runs inline during tests.
          ((symbol-function 'xwidget-webkit-execute-script)
           (lambda (_session js &optional callback)
             (push js jejeje-test--js-calls)
             (when callback
               (funcall callback
                        (json-encode
                         '(((value . "5001") (text . "C++ (GCC 9.2.1)"))
                           ((value . "5002") (text . "Python (CPython 3.8)"))))))))
          ;; user picks a language
          ((symbol-function 'completing-read)
           (lambda (_prompt _coll &rest _) ,chosen-language))
          ;; suppress message output in tests
          ((symbol-function 'message) #'ignore))
       ;; Ensure xwidget-webkit-execute-script appears bound so the guard
       ;; in jejeje-submit-problem passes without mocking fboundp itself.
       (cl-flet ((xwidget-webkit-execute-script
                  (session js &optional cb)
                  (push js jejeje-test--js-calls)
                  (when cb
                    (funcall cb
                             (json-encode
                              '(((value . "5001") (text . "C++ (GCC 9.2.1)"))
                                ((value . "5002") (text . "Python (CPython 3.8)"))))))))
         (with-temp-buffer
           (insert ,source-code)
           ,@body)))))

(ert-deftest jejeje-submit-problem/errors-without-xwidgets ()
  "Signals `user-error' when xwidgets are not compiled in."
  (let ((was-bound (fboundp 'xwidget-webkit-execute-script))
        (saved-fn  (and (fboundp 'xwidget-webkit-execute-script)
                        (symbol-function 'xwidget-webkit-execute-script))))
    (unwind-protect
        (progn
          (fmakunbound 'xwidget-webkit-execute-script)
          (should-error (jejeje-submit-problem) :type 'user-error))
      (when was-bound
        (fset 'xwidget-webkit-execute-script saved-fn)))))

(ert-deftest jejeje-submit-problem/errors-for-unsupported-judge ()
  "Signals `user-error' when the current page URL matches no backend."
  (let ((fake-session (list 'fake-session)))
    (cl-letf (((symbol-function 'jejeje--get-xwidget-session)
               (lambda () fake-session))
              ((symbol-function 'xwidget-webkit-uri)
               (lambda (_s) "https://unsupported-judge.example.com/submit"))
              ((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_session _js &optional _cb) nil))
              ((symbol-function 'message) #'ignore))
      (should-error (jejeje-submit-problem) :type 'user-error))))

(ert-deftest jejeje-submit-problem/calls-get-languages-js ()
  "Executes the backend's :get-languages-js script in the xwidget."
  (jejeje-test--with-submit-mocks
      "https://atcoder.jp/contests/abc001/submit"
      "print('hello')"
      "Python (CPython 3.8)"
    (jejeje-submit-problem)
    ;; The first JS call must be the language-list query
    (should (cl-some (lambda (js)
                       (string-match-p "select-lang" js))
                     jejeje-test--js-calls))))

(ert-deftest jejeje-submit-problem/calls-set-language-js ()
  "Executes a JS snippet that references the language select element."
  (jejeje-test--with-submit-mocks
      "https://atcoder.jp/contests/abc001/submit"
      "print('hello')"
      "Python (CPython 3.8)"
    (jejeje-submit-problem)
    (should (cl-some (lambda (js)
                       (string-match-p "select-lang" js))
                     jejeje-test--js-calls))))

(ert-deftest jejeje-submit-problem/calls-set-code-js ()
  "Executes a JS snippet that calls the ACE editor setValue."
  (jejeje-test--with-submit-mocks
      "https://atcoder.jp/contests/abc001/submit"
      "print('hello')"
      "Python (CPython 3.8)"
    (jejeje-submit-problem)
    (should (cl-some (lambda (js)
                       (string-match-p "setValue" js))
                     jejeje-test--js-calls))))

(ert-deftest jejeje-submit-problem/embeds-source-code-in-js ()
  "The source code content appears (escaped) in the setValue JS call."
  (jejeje-test--with-submit-mocks
      "https://atcoder.jp/contests/abc001/submit"
      "my_unique_code_string_42"
      "Python (CPython 3.8)"
    (jejeje-submit-problem)
    (should (cl-some (lambda (js)
                       (string-match-p "my_unique_code_string_42" js))
                     jejeje-test--js-calls))))

(ert-deftest jejeje-submit-problem/executes-four-js-calls-total ()
  "Exactly four JS calls are made: get-languages, set-language, set-code, scroll."
  (jejeje-test--with-submit-mocks
      "https://atcoder.jp/contests/abc001/submit"
      "print('hello')"
      "Python (CPython 3.8)"
    (jejeje-submit-problem)
    (should (= 4 (length jejeje-test--js-calls)))))

(ert-deftest jejeje-submit-inject/with-problem-index-makes-four-js-calls ()
  "When problem-index is supplied, four JS calls are made (set-problem added)."
  (let ((fake-session (list 'fake-session))
        js-calls)
    (cl-letf (((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_s js &optional cb)
                 (push js js-calls)
                 (when cb
                   (funcall cb
                            (json-encode
                             '(((value . "54") (text . "GNU G++17 7.3.0"))))))))
              ((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _) "GNU G++17 7.3.0"))
              ((symbol-function 'message) #'ignore))
      (let ((backend (jejeje--detect-submit-backend
                      "https://codeforces.com/contest/1352/submit")))
        (with-temp-buffer
          (insert "int main(){}")
          (jejeje--submit-inject fake-session backend (buffer-string) nil "A")))
      ;; 4 calls: set-problem, get-languages, set-language, set-code
      (should (= 4 (length js-calls)))
      (should (cl-some (lambda (js) (string-match-p "submittedProblemIndex" js))
                       js-calls)))))


;;; ─── jejeje-language-alist default values ────────────────────────────────────

(ert-deftest jejeje-language-alist/cpp-hint ()
  "\"cpp\" maps to a C++ hint string."
  (let ((hint (cdr (assoc "cpp" jejeje-language-alist))))
    (should (stringp hint))
    (should (string-match-p "C++" hint))))

(ert-deftest jejeje-language-alist/py-hint ()
  "\"py\" maps to a Python hint string."
  (let ((hint (cdr (assoc "py" jejeje-language-alist))))
    (should (stringp hint))
    (should (string-match-p "Python" hint))))

(ert-deftest jejeje-language-alist/rs-hint ()
  "\"rs\" maps to a Rust hint string."
  (let ((hint (cdr (assoc "rs" jejeje-language-alist))))
    (should (stringp hint))
    (should (string-match-p "Rust" hint))))

(ert-deftest jejeje-language-alist/all-values-are-strings ()
  "Every value in the default alist is a non-empty string."
  (dolist (entry jejeje-language-alist)
    (should (stringp (cdr entry)))
    (should (not (string-empty-p (cdr entry))))))

(ert-deftest jejeje-language-alist/all-keys-are-strings-without-dot ()
  "Every key is a string and does not start with a dot."
  (dolist (entry jejeje-language-alist)
    (should (stringp (car entry)))
    (should (not (string-prefix-p "." (car entry))))))


;;; ─── jejeje-template ─────────────────────────────────────────────────────────

;; Helper: mock `jejeje--get-template-dir' to return a fixed path.
(defmacro jejeje-test--with-template-dir (dir &rest body)
  "Evaluate BODY with `jejeje--get-template-dir' stubbed to return DIR."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'jejeje--get-template-dir)
              (lambda () ,dir)))
     ,@body))

(ert-deftest jejeje-template/signals-error-when-template-dir-empty ()
  "Signals `user-error' when `je config template_dir' is not configured."
  (cl-letf (((symbol-function 'jejeje--get-template-dir)
             (lambda ()
               (user-error "jejeje: template_dir is not set — run `je config template_dir <path>'"))))
    (should-error (jejeje-template) :type 'user-error)))

(ert-deftest jejeje-template/opens-file-when-same-name-exists ()
  "Calls `find-file' with the template file when a same-named file exists."
  (jejeje-test--with-temp-dir
    (let* ((tpl-file (expand-file-name "sol.cpp" default-directory)))
      (jejeje-test--write-file tpl-file "// template")
      (jejeje-test--with-template-dir default-directory
        (let (opened-path)
          (cl-letf (((symbol-function 'find-file)
                     (lambda (path) (setq opened-path path))))
            (jejeje-test--with-file-buffer "/contest/abc001/a/sol.cpp"
              (jejeje-template)))
          (should (equal tpl-file opened-path)))))))

(ert-deftest jejeje-template/opens-dired-when-no-same-name-file ()
  "Calls `dired' on the template directory when no same-named file exists."
  (jejeje-test--with-temp-dir
    (let ((tpl-dir default-directory))
      ;; No sol.py in tpl-dir
      (jejeje-test--with-template-dir tpl-dir
        (let (dired-path)
          (cl-letf (((symbol-function 'dired)
                     (lambda (path) (setq dired-path path))))
            (jejeje-test--with-file-buffer "/contest/abc001/a/sol.py"
              (jejeje-template)))
          (should (equal tpl-dir dired-path)))))))

(ert-deftest jejeje-template/opens-dired-when-buffer-has-no-file ()
  "Calls `dired' when the current buffer is not visiting a file."
  (jejeje-test--with-temp-dir
    (let ((tpl-dir default-directory))
      (jejeje-test--with-template-dir tpl-dir
        (let (dired-path)
          (cl-letf (((symbol-function 'dired)
                     (lambda (path) (setq dired-path path))))
            ;; with-temp-buffer leaves buffer-file-name as nil
            (with-temp-buffer
              (jejeje-template)))
          (should (equal tpl-dir dired-path)))))))


;;; ─── Codeforces backend — helpers ────────────────────────────────────────────

(defun jejeje-test--codeforces-backend ()
  "Return the Codeforces submit backend plist from `jejeje--submit-backend-alist'."
  (jejeje--detect-submit-backend
   "https://codeforces.com/contest/1352/submit"))


;;; ─── Codeforces backend — :get-languages-js ─────────────────────────────────

(ert-deftest jejeje-codeforces-backend/get-languages-js-is-string ()
  ":get-languages-js is a non-empty string."
  (let ((js (plist-get (jejeje-test--codeforces-backend) :get-languages-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-codeforces-backend/get-languages-js-references-program-type-select ()
  ":get-languages-js targets the programTypeId select element."
  (let ((js (plist-get (jejeje-test--codeforces-backend) :get-languages-js)))
    (should (string-match-p "programTypeId" js))))


;;; ─── Codeforces backend — :set-language-js ──────────────────────────────────

(ert-deftest jejeje-codeforces-backend/set-language-js-is-function ()
  ":set-language-js value is callable."
  (should (functionp (plist-get (jejeje-test--codeforces-backend) :set-language-js))))

(ert-deftest jejeje-codeforces-backend/set-language-js-returns-string ()
  ":set-language-js called with a value returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-language-js))
         (result (funcall fn "54")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-codeforces-backend/set-language-js-contains-program-type-selector ()
  ":set-language-js output references the programTypeId select element."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-language-js))
         (result (funcall fn "54")))
    (should (string-match-p "programTypeId" result))))

(ert-deftest jejeje-codeforces-backend/set-language-js-dispatches-change-event ()
  ":set-language-js output fires a DOM change event."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-language-js))
         (result (funcall fn "54")))
    (should (string-match-p "change" result))))


;;; ─── Codeforces backend — :set-code-js ──────────────────────────────────────

(ert-deftest jejeje-codeforces-backend/set-code-js-is-function ()
  ":set-code-js value is callable."
  (should (functionp (plist-get (jejeje-test--codeforces-backend) :set-code-js))))

(ert-deftest jejeje-codeforces-backend/set-code-js-references-codemirror ()
  ":set-code-js output references the CodeMirror editor or sourceCodeTextarea."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-code-js))
         (result (funcall fn "int main(){}")))
    (should (or (string-match-p "CodeMirror" result)
                (string-match-p "sourceCodeTextarea" result)))))

(ert-deftest jejeje-codeforces-backend/set-code-js-calls-set-value ()
  ":set-code-js output calls setValue to set the editor content."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-code-js))
         (result (funcall fn "int main(){}")))
    (should (string-match-p "setValue" result))))

(ert-deftest jejeje-codeforces-backend/set-code-js-escapes-newlines ()
  "Source code containing newlines is safely embedded in the JS output."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-code-js))
         (result (funcall fn "line1\nline2\nline3")))
    ;; Literal newline must not appear unescaped inside the JS string.
    (should (not (string-match-p "\n" result)))))

(ert-deftest jejeje-codeforces-backend/set-code-js-embeds-source-code ()
  "The supplied source code appears (JSON-encoded) in the JS output."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-code-js))
         (result (funcall fn "unique_token_xyz")))
    (should (string-match-p "unique_token_xyz" result))))


;;; ─── Codeforces backend — :extract-problem-fn ───────────────────────────────

(ert-deftest jejeje-codeforces-backend/extract-problem-fn-is-function ()
  ":extract-problem-fn is callable."
  (should (functionp (plist-get (jejeje-test--codeforces-backend)
                                :extract-problem-fn))))

(ert-deftest jejeje-codeforces-backend/extract-problem-fn-extracts-index ()
  ":extract-problem-fn returns the problem letter from a problem page URL."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :extract-problem-fn))
         (result (funcall fn "https://codeforces.com/contest/1352/problem/A")))
    (should (equal "A" result))))

(ert-deftest jejeje-codeforces-backend/extract-problem-fn-multichar-index ()
  ":extract-problem-fn handles multi-character problem indices (e.g. \"E1\")."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :extract-problem-fn))
         (result (funcall fn "https://codeforces.com/contest/999/problem/E1")))
    (should (equal "E1" result))))

(ert-deftest jejeje-codeforces-backend/extract-problem-fn-returns-nil-on-submit-page ()
  ":extract-problem-fn returns nil when given the submit page URL."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :extract-problem-fn))
         (result (funcall fn "https://codeforces.com/contest/1352/submit")))
    (should (null result))))


;;; ─── Codeforces backend — :set-problem-js ───────────────────────────────────

(ert-deftest jejeje-codeforces-backend/set-problem-js-is-function ()
  ":set-problem-js is callable."
  (should (functionp (plist-get (jejeje-test--codeforces-backend)
                                :set-problem-js))))

(ert-deftest jejeje-codeforces-backend/set-problem-js-returns-string ()
  ":set-problem-js called with an index returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-problem-js))
         (result (funcall fn "A")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-codeforces-backend/set-problem-js-references-submitted-problem-index ()
  ":set-problem-js targets the submittedProblemIndex select element."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-problem-js))
         (result (funcall fn "A")))
    (should (string-match-p "submittedProblemIndex" result))))

(ert-deftest jejeje-codeforces-backend/set-problem-js-embeds-index ()
  ":set-problem-js output embeds the supplied problem index."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-problem-js))
         (result (funcall fn "E1")))
    (should (string-match-p "E1" result))))

(ert-deftest jejeje-codeforces-backend/set-problem-js-dispatches-change-event ()
  ":set-problem-js output fires a DOM change event."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :set-problem-js))
         (result (funcall fn "A")))
    (should (string-match-p "change" result))))


;;; ─── Codeforces backend — :redirect-url-fn ──────────────────────────────────

(ert-deftest jejeje-codeforces-backend/redirect-url-fn-is-function ()
  ":redirect-url-fn is callable."
  (should (functionp (plist-get (jejeje-test--codeforces-backend) :redirect-url-fn))))

(ert-deftest jejeje-codeforces-backend/redirect-url-fn-converts-problem-page ()
  ":redirect-url-fn returns the submit URL when given a problem page URL."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :redirect-url-fn))
         (result (funcall fn "https://codeforces.com/contest/1352/problem/A")))
    (should (stringp result))
    (should (string-match-p "/contest/1352/submit" result))))

(ert-deftest jejeje-codeforces-backend/redirect-url-fn-returns-nil-on-submit-page ()
  ":redirect-url-fn returns nil when already on the submit page."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :redirect-url-fn))
         (result (funcall fn "https://codeforces.com/contest/1352/submit")))
    (should (null result))))

(ert-deftest jejeje-codeforces-backend/redirect-url-fn-preserves-contest-id ()
  ":redirect-url-fn embeds the correct contest ID in the submit URL."
  (let* ((fn (plist-get (jejeje-test--codeforces-backend) :redirect-url-fn))
         (result (funcall fn "https://codeforces.com/contest/9999/problem/B")))
    (should (string-match-p "contest/9999/submit" result))))


;;; ─── jejeje-submit-problem — Codeforces integration ─────────────────────────

(ert-deftest jejeje-submit-problem/codeforces-problem-page-triggers-redirect ()
  "On a Codeforces problem page, navigates via JS and schedules injection."
  (let ((fake-session (list 'fake-session))
        navigation-js
        timer-fn)
    (cl-letf (((symbol-function 'jejeje--get-xwidget-session)
               (lambda () fake-session))
              ((symbol-function 'xwidget-webkit-uri)
               (lambda (_s)
                 "https://codeforces.com/contest/1352/problem/A"))
              ((symbol-function 'xwidget-webkit-execute-script)
               (lambda (_s js &optional _cb)
                 ;; Capture the first (navigation) JS call.
                 (unless navigation-js (setq navigation-js js))))
              ((symbol-function 'run-with-timer)
               (lambda (_delay _repeat fn &rest _args)
                 (setq timer-fn fn)))
              ((symbol-function 'message) #'ignore))
      (jejeje-submit-problem)
      ;; Navigation must be done via window.location.href JS, not browse-url.
      (should (stringp navigation-js))
      (should (string-match-p "location\\.href" navigation-js))
      (should (string-match-p "1352/submit" navigation-js))
      ;; A timer callback must be scheduled for the deferred injection.
      (should (functionp timer-fn)))))

(ert-deftest jejeje-submit-problem/codeforces-submit-page-injects-js ()
  "On a Codeforces submit page, three JS calls are made without redirecting."
  (jejeje-test--with-submit-mocks
      "https://codeforces.com/contest/1352/submit"
      "int main(){return 0;}"
      "GNU G++17 7.3.0"
    (jejeje-submit-problem)
    ;; get-languages, set-language, set-code — exactly three calls
    (should (= 3 (length jejeje-test--js-calls)))))


;;; ─── yukicoder backend ────────────────────────────────────────────────────────

(defun jejeje-test--yukicoder-backend ()
  "Return the yukicoder submit backend plist from `jejeje--submit-backend-alist'."
  (jejeje--detect-submit-backend "https://yukicoder.me/problems/no/1234"))

(ert-deftest jejeje-detect-submit-backend/yukicoder-matches ()
  "yukicoder URLs are matched by the built-in backend."
  (should (jejeje-test--yukicoder-backend)))

(ert-deftest jejeje-yukicoder-backend/get-languages-js-is-string ()
  ":get-languages-js is a non-empty string."
  (let ((js (plist-get (jejeje-test--yukicoder-backend) :get-languages-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-yukicoder-backend/get-languages-js-references-lang-select ()
  ":get-languages-js targets the #lang select element."
  (let ((js (plist-get (jejeje-test--yukicoder-backend) :get-languages-js)))
    (should (string-match-p "select#lang" js))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-is-function ()
  ":set-language-js value is callable."
  (should (functionp (plist-get (jejeje-test--yukicoder-backend) :set-language-js))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-returns-string ()
  ":set-language-js called with a value returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-language-js))
         (result (funcall fn "cpp23")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-contains-lang-selector ()
  ":set-language-js output references the yukicoder #lang select element."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-language-js))
         (result (funcall fn "cpp23")))
    (should (string-match-p "select#lang" result))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-embeds-value ()
  ":set-language-js embeds the supplied value in the JS output."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-language-js))
         (result (funcall fn "rust")))
    (should (string-match-p (regexp-quote "\"rust\"") result))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-dispatches-change-event ()
  ":set-language-js fires a DOM change event."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-language-js))
         (result (funcall fn "python3")))
    (should (string-match-p "change" result))
    (should (string-match-p "dispatchEvent" result))))

(ert-deftest jejeje-yukicoder-backend/set-language-js-escapes-special-chars ()
  ":set-language-js safely escapes double-quotes and backslashes via jejeje--js-string."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-language-js))
         (result (funcall fn "a\"b\\c")))
    (should (string-match-p (regexp-quote "\\\"") result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-is-function ()
  ":set-code-js value is callable."
  (should (functionp (plist-get (jejeje-test--yukicoder-backend) :set-code-js))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-references-rich-source ()
  ":set-code-js targets the ACE editor element (rich_source)."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "int main(){}")))
    (should (string-match-p "rich_source" result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-references-textarea ()
  ":set-code-js also targets the raw textarea (#source) as a fallback."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "int main(){}")))
    (should (string-match-p (regexp-quote "'source'") result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-calls-set-value ()
  ":set-code-js calls setValue on the ACE editor."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "x=1")))
    (should (string-match-p "setValue" result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-embeds-source-code ()
  ":set-code-js embeds the supplied source code in the JS output."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "my_unique_code_42")))
    (should (string-match-p "my_unique_code_42" result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-escapes-newlines ()
  ":set-code-js safely encodes embedded newlines."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "line1\nline2")))
    (should (string-match-p "\\\\n" result))))

(ert-deftest jejeje-yukicoder-backend/set-code-js-escapes-backslashes ()
  ":set-code-js safely encodes embedded backslashes."
  (let* ((fn (plist-get (jejeje-test--yukicoder-backend) :set-code-js))
         (result (funcall fn "a\\b")))
    (should (string-match-p "\\\\\\\\" result))))

(ert-deftest jejeje-yukicoder-backend/scroll-js-is-string ()
  ":scroll-js is a non-empty string."
  (let ((js (plist-get (jejeje-test--yukicoder-backend) :scroll-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-yukicoder-backend/scroll-js-calls-scroll-to ()
  ":scroll-js calls window.scrollTo."
  (let ((js (plist-get (jejeje-test--yukicoder-backend) :scroll-js)))
    (should (string-match-p "scrollTo" js))))

(ert-deftest jejeje-yukicoder-backend/no-redirect-url-fn ()
  "yukicoder backend has no :redirect-url-fn (form is on the problem page)."
  (should (null (plist-get (jejeje-test--yukicoder-backend) :redirect-url-fn))))

(ert-deftest jejeje-submit-problem/yukicoder-injects-four-js-calls ()
  "On a yukicoder problem page, exactly four JS calls are made: get-languages,
set-language, set-code, and scroll."
  (jejeje-test--with-submit-mocks
      "https://yukicoder.me/problems/no/1234"
      "fn main() {}"
      "Rust\n(1.94.0 + proconio + num + itertools)"
    (jejeje-submit-problem)
    (should (= 4 (length jejeje-test--js-calls)))))

;;; ─── jejeje--fetch-contests ──────────────────────────────────────────────────
;;
;; These tests mock `call-process' so no real `je' binary is invoked.
;; The key property being checked: the CDR of each returned pair (the value
;; that will be passed to `je prepare') must be the full contest URL, NOT a
;; bare numeric ID.  Passing a bare numeric ID triggers an ambiguous all-judge
;; search in the `je' CLI (regression: "Query '1' did not match direct
;; patterns. Searching all judges...").

(defmacro jejeje-test--with-mocked-contests (output &rest body)
  "Evaluate BODY with `call-process' stubbed to emit OUTPUT into the work buffer.
EXIT-CODE is always 0 (success).  OUTPUT is a string that mimics what
`je contests <judge>' writes to stdout.

The BUFFER argument of `call-process' may be t (meaning the current buffer),
a buffer object, or a buffer name string.  We normalise all three cases."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'call-process)
              (lambda (_program _infile buffer _display &rest _args)
                ;; buffer can be: t (current), a buffer object, or a string name.
                (let ((target (cond ((eq buffer t)   (current-buffer))
                                    ((bufferp buffer) buffer)
                                    ((stringp buffer) (get-buffer-create buffer))
                                    (t               (current-buffer)))))
                  (with-current-buffer target
                    (insert ,output)))
                0)))
     ,@body))

;; Shared sample outputs for each judge, matching the real `je contests' format:
;;   <id> — <display-name> (<url>)

(defconst jejeje-test--yukicoder-contests-output
  "Fetching contest list for yukicoder...\n\
602 \u2014 yukicoder contest 503 (https://yukicoder.me/contests/602)\n\
601 \u2014 yukicoder contest 502 (https://yukicoder.me/contests/601)\n\
1 \u2014 yukicoder contest 1 (https://yukicoder.me/contests/1)\n"
  "Sample stdout from `je contests yukicoder'.")

(defconst jejeje-test--atcoder-contests-output
  "Fetching contest list for atcoder...\n\
abc400 \u2014 AtCoder Beginner Contest 400 (https://atcoder.jp/contests/abc400)\n\
abc001 \u2014 AtCoder Beginner Contest 001 (https://atcoder.jp/contests/abc001)\n"
  "Sample stdout from `je contests atcoder'.")

(defconst jejeje-test--codeforces-contests-output
  "Fetching contest list for codeforces...\n\
2090 \u2014 Codeforces Round 1001 (https://codeforces.com/contest/2090)\n\
1 \u2014 Codeforces Beta Round 1 (https://codeforces.com/contest/1)\n"
  "Sample stdout from `je contests codeforces'.")

(defconst jejeje-test--aoj-contests-output
  "Fetching contest list for aoj...\n\
ITP1 \u2014 Introduction to Programming I (https://onlinejudge.u-aizu.ac.jp/courses/lesson/2/ITP1/all)\n\
ITP2 \u2014 Introduction to Programming II (https://onlinejudge.u-aizu.ac.jp/courses/lesson/8/ITP2/all)\n"
  "Sample stdout from `je contests aoj'.")

;; ── display string (CAR) ────────────────────────────────────────────────────

(ert-deftest jejeje-fetch-contests/yukicoder-display-contains-name-and-id ()
  "Display string includes the contest name and bracket-quoted numeric ID."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let ((result (jejeje--fetch-contests "yukicoder")))
      (should result)
      ;; The earliest contest (contest 1, id=1) should appear somewhere.
      (should (cl-some (lambda (pair)
                         (and (string-match-p "yukicoder contest 1" (car pair))
                              (string-match-p "\\[1\\]" (car pair))))
                       result)))))

(ert-deftest jejeje-fetch-contests/atcoder-display-contains-name-and-id ()
  "AtCoder display string includes the contest name and bracket-quoted ID."
  (jejeje-test--with-mocked-contests jejeje-test--atcoder-contests-output
    (let ((result (jejeje--fetch-contests "atcoder")))
      (should result)
      (should (cl-some (lambda (pair)
                         (and (string-match-p "AtCoder Beginner Contest 001" (car pair))
                              (string-match-p "\\[abc001\\]" (car pair))))
                       result)))))

(ert-deftest jejeje-fetch-contests/codeforces-display-contains-name-and-id ()
  "Codeforces display string includes the contest name and bracket-quoted ID."
  (jejeje-test--with-mocked-contests jejeje-test--codeforces-contests-output
    (let ((result (jejeje--fetch-contests "codeforces")))
      (should result)
      (should (cl-some (lambda (pair)
                         (and (string-match-p "Codeforces Beta Round 1" (car pair))
                              (string-match-p "\\[1\\]" (car pair))))
                       result)))))

(ert-deftest jejeje-fetch-contests/aoj-display-contains-name-and-id ()
  "AOJ display string includes the contest name and bracket-quoted ID."
  (jejeje-test--with-mocked-contests jejeje-test--aoj-contests-output
    (let ((result (jejeje--fetch-contests "aoj")))
      (should result)
      (should (cl-some (lambda (pair)
                         (and (string-match-p "Introduction to Programming I" (car pair))
                              (string-match-p "\\[ITP1\\]" (car pair))))
                       result)))))

;; ── value (CDR) must be a full URL, never a bare ID ────────────────────────
;;
;; This is the core regression guard.  Passing a bare numeric or slug ID to
;; `je prepare' causes "Query '...' did not match direct patterns. Searching
;; all judges..." because the CLI performs a global search instead of scoping
;; to the already-known judge.

(ert-deftest jejeje-fetch-contests/yukicoder-value-is-full-url ()
  "The CDR (value for `je prepare') is the full https URL, not a bare number.
Regression: bare id '1' triggered ambiguous global search in the `je' CLI."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let ((result (jejeje--fetch-contests "yukicoder")))
      (should result)
      (dolist (pair result)
        (let ((value (cdr pair)))
          ;; Must start with https:// — never a bare numeric string.
          (should (string-prefix-p "https://" value))
          ;; Must point to the yukicoder domain.
          (should (string-match-p "yukicoder\\.me" value)))))))

(ert-deftest jejeje-fetch-contests/atcoder-value-is-full-url ()
  "AtCoder CDR values are full https URLs pointing to atcoder.jp."
  (jejeje-test--with-mocked-contests jejeje-test--atcoder-contests-output
    (let ((result (jejeje--fetch-contests "atcoder")))
      (should result)
      (dolist (pair result)
        (let ((value (cdr pair)))
          (should (string-prefix-p "https://" value))
          (should (string-match-p "atcoder\\.jp" value)))))))

(ert-deftest jejeje-fetch-contests/codeforces-value-is-full-url ()
  "Codeforces CDR values are full https URLs pointing to codeforces.com."
  (jejeje-test--with-mocked-contests jejeje-test--codeforces-contests-output
    (let ((result (jejeje--fetch-contests "codeforces")))
      (should result)
      (dolist (pair result)
        (let ((value (cdr pair)))
          (should (string-prefix-p "https://" value))
          (should (string-match-p "codeforces\\.com" value)))))))

(ert-deftest jejeje-fetch-contests/aoj-value-is-full-url ()
  "AOJ CDR values are full https URLs pointing to the AOJ domain."
  (jejeje-test--with-mocked-contests jejeje-test--aoj-contests-output
    (let ((result (jejeje--fetch-contests "aoj")))
      (should result)
      (dolist (pair result)
        (let ((value (cdr pair)))
          (should (string-prefix-p "https://" value))
          (should (string-match-p "u-aizu\\.ac\\.jp" value)))))))

;; ── value never equals the bare ID ─────────────────────────────────────────

(ert-deftest jejeje-fetch-contests/yukicoder-value-not-bare-id ()
  "No CDR value equals the raw numeric ID string extracted from the line."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let ((result (jejeje--fetch-contests "yukicoder")))
      ;; IDs in the sample: "602", "601", "1"
      (dolist (pair result)
        (should (not (member (cdr pair) '("602" "601" "1"))))))))

(ert-deftest jejeje-fetch-contests/specific-url-mapping ()
  "The URL stored for 'yukicoder contest 1' is exactly the expected URL."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let* ((result (jejeje--fetch-contests "yukicoder"))
           ;; Find the pair whose display string mentions contest 1.
           (pair (cl-find-if
                  (lambda (p) (string-match-p "\\[1\\]" (car p)))
                  result)))
      (should pair)
      (should (equal "https://yukicoder.me/contests/1" (cdr pair))))))

;; ── error / edge cases ──────────────────────────────────────────────────────

(ert-deftest jejeje-fetch-contests/returns-nil-on-failure ()
  "Returns nil when `je contests' exits non-zero."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_prog _in _buf _disp &rest _args) 1)))  ; exit code 1
    (should (null (jejeje--fetch-contests "yukicoder")))))

(ert-deftest jejeje-fetch-contests/skips-header-line ()
  "The 'Fetching contest list...' header line in stdout is silently ignored."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let ((result (jejeje--fetch-contests "yukicoder")))
      ;; We should get exactly 3 real contest entries, not 4.
      (should (= 3 (length result))))))

(ert-deftest jejeje-fetch-contests/order-preserved ()
  "Contests are returned in the same top-to-bottom order as `je' output."
  (jejeje-test--with-mocked-contests jejeje-test--yukicoder-contests-output
    (let ((result (jejeje--fetch-contests "yukicoder")))
      ;; Output order: 602, 601, 1 → same order in result.
      (should (string-match-p "503" (car (nth 0 result))))
      (should (string-match-p "502" (car (nth 1 result))))
      (should (string-match-p "\\[1\\]" (car (nth 2 result)))))))


;;; ─── AOJ backend ──────────────────────────────────────────────────────────────

(defun jejeje-test--aoj-backend ()
  "Return the AOJ submit backend plist from `jejeje--submit-backend-alist'."
  (jejeje--detect-submit-backend
   "https://onlinejudge.u-aizu.ac.jp/challenges/sources/JOI/Prelim/0763"))

(ert-deftest jejeje-detect-submit-backend/aoj-matches ()
  "AOJ URLs are matched by the built-in backend."
  (should (jejeje-test--aoj-backend)))

(ert-deftest jejeje-aoj-backend/get-languages-js-is-string ()
  ":get-languages-js is a non-empty string."
  (let ((js (plist-get (jejeje-test--aoj-backend) :get-languages-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-aoj-backend/get-languages-js-queries-el-select-items ()
  ":get-languages-js targets the Element UI el-select dropdown items."
  (let ((js (plist-get (jejeje-test--aoj-backend) :get-languages-js)))
    (should (string-match-p "el-select-dropdown__item" js))))

(ert-deftest jejeje-aoj-backend/get-languages-js-filters-hidden ()
  ":get-languages-js filters out items with display:none."
  (let ((js (plist-get (jejeje-test--aoj-backend) :get-languages-js)))
    (should (string-match-p "display" js))
    (should (string-match-p "none" js))))

(ert-deftest jejeje-aoj-backend/set-language-js-is-function ()
  ":set-language-js value is callable."
  (should (functionp (plist-get (jejeje-test--aoj-backend) :set-language-js))))

(ert-deftest jejeje-aoj-backend/set-language-js-returns-string ()
  ":set-language-js called with a value returns a non-empty string."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "C++17")))
    (should (stringp result))
    (should (not (string-empty-p result)))))

(ert-deftest jejeje-aoj-backend/set-language-js-clicks-el-input ()
  ":set-language-js opens the dropdown by clicking the el-input element."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "C++17")))
    (should (string-match-p "el-input__inner" result))
    (should (string-match-p "\\.click" result))))

(ert-deftest jejeje-aoj-backend/set-language-js-clicks-matching-li ()
  ":set-language-js clicks the <li> whose text matches the chosen language."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "Rust")))
    (should (string-match-p "el-select-dropdown__item" result))
    (should (string-match-p (regexp-quote "\"Rust\"") result))))

(ert-deftest jejeje-aoj-backend/set-language-js-embeds-value ()
  ":set-language-js embeds the supplied value in the JS output."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "Python3")))
    (should (string-match-p (regexp-quote "\"Python3\"") result))))

(ert-deftest jejeje-aoj-backend/set-language-js-uses-settimeout ()
  ":set-language-js uses setTimeout to wait for the dropdown to open."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "Go")))
    (should (string-match-p "setTimeout" result))))

(ert-deftest jejeje-aoj-backend/set-language-js-escapes-special-chars ()
  ":set-language-js safely escapes double-quotes and backslashes."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-language-js))
         (result (funcall fn "a\"b\\c")))
    (should (string-match-p (regexp-quote "\\\"") result))))

(ert-deftest jejeje-aoj-backend/set-code-js-is-function ()
  ":set-code-js value is callable."
  (should (functionp (plist-get (jejeje-test--aoj-backend) :set-code-js))))

(ert-deftest jejeje-aoj-backend/set-code-js-uses-ace-editor ()
  ":set-code-js targets the ACE editor (id=\"editor\")."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-code-js))
         (result (funcall fn "int main(){}")))
    (should (string-match-p "ace\\.edit" result))
    (should (string-match-p (regexp-quote "'editor'") result))))

(ert-deftest jejeje-aoj-backend/set-code-js-calls-set-value ()
  ":set-code-js calls setValue on the ACE editor."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-code-js))
         (result (funcall fn "x=1")))
    (should (string-match-p "setValue" result))))

(ert-deftest jejeje-aoj-backend/set-code-js-embeds-source-code ()
  ":set-code-js embeds the supplied source code in the JS output."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-code-js))
         (result (funcall fn "my_unique_code_aoj")))
    (should (string-match-p "my_unique_code_aoj" result))))

(ert-deftest jejeje-aoj-backend/set-code-js-escapes-newlines ()
  ":set-code-js safely encodes embedded newlines."
  (let* ((fn (plist-get (jejeje-test--aoj-backend) :set-code-js))
         (result (funcall fn "line1\nline2")))
    (should (string-match-p "\\\\n" result))))

(ert-deftest jejeje-aoj-backend/scroll-js-is-string ()
  ":scroll-js is a non-empty string."
  (let ((js (plist-get (jejeje-test--aoj-backend) :scroll-js)))
    (should (stringp js))
    (should (not (string-empty-p js)))))

(ert-deftest jejeje-aoj-backend/scroll-js-calls-scroll-to ()
  ":scroll-js calls window.scrollTo."
  (let ((js (plist-get (jejeje-test--aoj-backend) :scroll-js)))
    (should (string-match-p "scrollTo" js))))

(ert-deftest jejeje-aoj-backend/no-redirect-url-fn ()
  "AOJ backend has no :redirect-url-fn (submit form is on the problem page)."
  (should (null (plist-get (jejeje-test--aoj-backend) :redirect-url-fn))))

(ert-deftest jejeje-submit-problem/aoj-injects-four-js-calls ()
  "On an AOJ problem page, exactly four JS calls are made: get-languages,
set-language, scroll, and set-code."
  (jejeje-test--with-submit-mocks
      "https://onlinejudge.u-aizu.ac.jp/challenges/sources/JOI/Prelim/0763"
      "int main(){}"
      "C++ (GCC 9.2.1)"
    (jejeje-submit-problem)
    (should (= 4 (length jejeje-test--js-calls)))))

(ert-deftest jejeje-submit-problem/aoj-scroll-before-code ()
  "Scroll JS is executed before set-code JS in the AOJ submit flow.
jejeje-test--js-calls collects calls in push order (newest-first), so:
  index 0 = last call  (set-code)
  index 1 = second-to-last (scroll)
  index 2 = set-language
  index 3 = first call (get-languages)"
  (jejeje-test--with-submit-mocks
      "https://onlinejudge.u-aizu.ac.jp/challenges/sources/JOI/Prelim/0763"
      "int main(){}"
      "C++ (GCC 9.2.1)"
    (jejeje-submit-problem)
    ;; index 1 must contain scrollTo (scroll step)
    (should (string-match-p "scrollTo" (nth 1 jejeje-test--js-calls)))
    ;; index 0 must contain ace.edit (set-code step)
    (should (string-match-p "ace\\.edit" (nth 0 jejeje-test--js-calls)))))

(provide 'jejeje-test)
;;; jejeje-test.el ends here
