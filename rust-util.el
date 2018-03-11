;;; rust-util.el --- Rust utility functions -*-lexical-binding: t-*-

;; This file is distributed under the terms of both the MIT license and the
;; Apache License (version 2.0).

;;; Code:

;;;;;;;;;;;;;;;;;;
;; Customization

(defcustom rust-format-on-save nil
  "Format future rust buffers before saving using rustfmt."
  :type 'boolean
  :safe #'booleanp
  :group 'rust-mode)

(defcustom rust-rustfmt-bin "rustfmt"
  "Path to rustfmt executable."
  :type 'string
  :group 'rust-mode)

(defcustom rust-cargo-bin "cargo"
  "Path to cargo executable.")

(defcustom rust-format-display-method 'pop-to-buffer
  "Default function used for displaying rustfmt buffer."
  :type 'function)

(defcustom rust-playpen-url-format "https://play.rust-lang.org/?code=%s"
  "Format string to use when submitting code to the playpen"
  :type 'string
  :group 'rust-mode)

(defcustom rust-shortener-url-format "https://is.gd/create.php?format=simple&url=%s"
  "Format string to use for creating the shortened link of a playpen submission"
  :type 'string
  :group 'rust-mode)


;;;;;;;;;;;;
;; Rustfmt 

(defvar rust-format-process-name "rust-rustfmt-process"
  "Process name for rustfmt processes.")

(defvar rust-format-buffer-name "*rustfmt*"
  "Buffer name for rustfmt process buffers.")

(defvar rust-format-file-name nil
  "Holds last file formatted by `rust-format-start-process'.")

(defvar rust-save-pos nil)

(defun rust-format-start-process (buffer string)
  "Start a new rustfmt process."
  (let* ((file (buffer-file-name buffer))
         (err-buf (get-buffer-create rust-format-buffer-name))
         (coding-system-for-read 'binary)
         (process-environment (nconc
	                           (list (format "TERM=%s" "ansi"))
                               process-environment))
         (inhibit-read-only t))
    (with-current-buffer err-buf
      (erase-buffer)
      (rust-format-mode))
    (setq rust-format-file-name (buffer-file-name buffer))
    (setq rust-save-pos (point))
    (let ((proc (make-process :name rust-format-process-name
                              :buffer err-buf
                              :command `(,rust-rustfmt-bin)
                              :filter #'rust-compile-filter
                              :sentinel #'rust-format-sentinel)))
      (while (not (process-live-p proc))
        (sleep-for 0.01))
      (process-send-string proc string)
      (process-send-eof proc))))

(defun rust-format-sentinel (proc output)
  "Sentinel for rustfmt processes."
  (let ((proc-buffer (process-buffer proc))
        (inhibit-read-only t))
    (with-current-buffer proc-buffer
      (if (string-match-p "^finished" output)
          (let ((file-buffer (get-file-buffer rust-format-file-name)))
            (copy-to-buffer file-buffer (point-min) (point-max))
            (with-current-buffer file-buffer
              (goto-char rust-save-pos))
            (kill-buffer proc-buffer)
            (message "Formatted buffer with rustfmt."))
        (goto-char (point-min))
        (save-excursion
          (save-match-data
            (when (search-forward "<stdin>" nil t)
              (replace-match rust-format-file-name)))
          (funcall rust-format-display-method proc-buffer)
          (message "Rustfmt error."))))))

(define-derived-mode rust-format-mode rust-compilation-mode "rustfmt"
  :group 'rust-mode)

(define-derived-mode rust-cargo-fmt-mode rust-compilation-mode "cargo-fmt"
  :group 'rust-mode)

;;;###autoload
(defun rust-format--enable-format-on-save ()
  "Enable formatting using rustfmt when saving buffer."
  (interactive)
  (setq-local rust-format-on-save t))

;;;###autoload
(defun rust-format--disable-format-on-save ()
  "Disable formatting using rustfmt when saving buffer."
  (interactive)
  (setq-local rust-format-on-save nil))

;;;###autoload
(defun rust-cargo-fmt ()
  (interactive)
  (let ((command (list rust-cargo-bin "fmt"))
        (buffer-name rust-format-buffer-name)
        (proc-name rust-format-process-name)
        (mode 'rust-cargo-fmt-mode)
        (dir (rust-buffer-workspace))
        (sentinel #'(lambda (proc output)
                      (let ((proc-buffer (process-buffer proc))
                            (inhibit-read-only t))
                        (with-current-buffer proc-buffer
                          (when (string-match-p "^finished" output)
                            (kill-buffer proc-buffer)
                            (message "Workspace formatted with cargo-fmt.")))))))
    (rust-compilation-process-live)
    (rust-compile-start-process command buffer-name proc-name mode dir sentinel)))

(defun rust-format-buffer ()
  "Format the current buffer using rustfmt."
  (interactive)
  (unless (executable-find rust-rustfmt-bin)
    (error "Could not locate executable \"%s\"" rust-rustfmt-bin))
  (rust-format-start-process (current-buffer) (buffer-string)))


;;;;;;;;;;;
;; Clippy

(defvar rust-clippy-process-name "rust-cargo-clippy-process"
  "Process name for clippy processes.")

(defvar rust-clippy-buffer-name "*cargo-clippy*"
  "Buffer name for clippy buffers.")

(define-derived-mode rust-cargo-clippy-mode rust-compilation-mode "cargo-clippy"
  :group 'rust-mode)

;;;###autoload
(defun rust-cargo-clippy ()
  "Run `cargo clippy'."
  (interactive)
  (let ((command (list rust-cargo-bin "clippy"))
        (buffer-name rust-clippy-buffer-name)
        (proc-name rust-clippy-process-name)
        (mode 'rust-cargo-clippy-mode)
        (root (rust-buffer-workspace)))
    (rust-compilation-process-live)
    (rust-compile-start-process command buffer-name proc-name mode root)))


;;;;;;;;;
;; Test

(defvar rust-test-process-name "rust-cargo-test-process"
  "Process name for test processes.")

(defvar rust-test-buffer-name "*cargo-test*"
  "Buffer name for test buffers.")

(define-derived-mode rust-cargo-test-mode rust-compilation-mode "cargo-test"
  :group 'rust-mode)

;;;###autoload
(defun rust-cargo-test ()
  "Run `cargo test'."
  (interactive)
  (let ((command (list rust-cargo-bin "test"))
        (buffer-name rust-test-buffer-name)
        (proc-name rust-test-process-name)
        (mode 'rust-cargo-test-mode)
        (root (rust-buffer-workspace)))
    (rust-compilation-process-live)
    (rust-compile-start-process command buffer-name proc-name mode root)))


;;;;;;;;;;;;;;;;
;; Interactive

(defun rust-playpen-region (begin end)
  "Create a sharable URL for the contents of the current region
   on the Rust playpen."
  (interactive "r")
  (let* ((data (buffer-substring begin end))
         (escaped-data (url-hexify-string data))
         (escaped-playpen-url (url-hexify-string (format rust-playpen-url-format escaped-data))))
    (if (> (length escaped-playpen-url) 5000)
        (error "encoded playpen data exceeds 5000 character limit (length %s)"
               (length escaped-playpen-url))
      (let ((shortener-url (format rust-shortener-url-format escaped-playpen-url))
            (url-request-method "POST"))
        (url-retrieve shortener-url
                      (lambda (state)
                        ;; filter out the headers etc. included at the
                        ;; start of the buffer: the relevant text
                        ;; (shortened url or error message) is exactly
                        ;; the last line.
                        (goto-char (point-max))
                        (let ((last-line (thing-at-point 'line t))
                              (err (plist-get state :error)))
                          (kill-buffer)
                          (if err
                              (error "failed to shorten playpen url: %s" last-line)
                            (message "%s" last-line)))))))))

(defun rust-playpen-buffer ()
  "Create a sharable URL for the contents of the current buffer
   on the Rust playpen."
  (interactive)
  (rust-playpen-region (point-min) (point-max)))

;;;###autoload
(defun rust-cargo-build ()
  (interactive)
  (call-interactively 'rust-compile "cargo build"))

(provide 'rust-util)
;;; rust-util.el ends here
