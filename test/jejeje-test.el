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


(provide 'jejeje-test)
;;; jejeje-test.el ends here
