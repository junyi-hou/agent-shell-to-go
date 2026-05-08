;;; agent-shell-to-go-test-core.el --- Tests for agent-shell-to-go.el -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for functions defined in agent-shell-to-go.el (core/main).
;; Uses mock-transport for hook-driven tests.
;;
;; Run:
;;   emacsclient -e '(load-file "tests/agent-shell-to-go-test-core.el")'
;;   emacsclient -e '(ert-run-tests-batch "^agent-shell-to-go-test-core-")'

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name ".")))))
  (add-to-list 'load-path root))

(require 'mock-transport)

(ert-deftest agent-shell-to-go-test-core-presentation-hide-unhide ()
  "Presentation reaction handler edits the message and restores it on removal."
  (let* ((tr (agent-shell-to-go-test-make))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "original text")))
    (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'hide t)
    (should (string-match-p "hidden"
                            (or (agent-shell-to-go-transport-get-message-text tr "C1" id) "")))
    (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'hide nil)
    (should (equal "original text"
                   (agent-shell-to-go-transport-get-message-text tr "C1" id)))))

(ert-deftest agent-shell-to-go-test-core-slash-arg-parsing ()
  "Slash command args parse correctly for each command."
  (let ((args (agent-shell-to-go--parse-slash-args "/new-agent" "~/code/myproject")))
    (should (equal "~/code/myproject" (map-elt args :folder))))
  (let ((args (agent-shell-to-go--parse-slash-args "/new-project" "myapp")))
    (should (equal "myapp" (map-elt args :project-name)))))

(ert-deftest agent-shell-to-go-test-core-slash-arg-parsing-edge-cases ()
  "Slash arg parsing handles empty args and unknown commands."
  (let ((args (agent-shell-to-go--parse-slash-args "/new-agent" "")))
    (should (null (map-elt args :folder))))
  (let ((args (agent-shell-to-go--parse-slash-args "/new-agent" "  ")))
    (should (null (map-elt args :folder))))
  (should (null (agent-shell-to-go--parse-slash-args "/unknown-command" "foo")))
  (should (null (agent-shell-to-go--parse-slash-args "/projects" "ignored"))))

(ert-deftest agent-shell-to-go-test-core-strip-non-ascii ()
  "Non-ASCII characters are replaced with `?'."
  (should (equal "hello?" (agent-shell-to-go--strip-non-ascii "hello\u00e9")))
  (should (equal "abc" (agent-shell-to-go--strip-non-ascii "abc")))
  (should (null (agent-shell-to-go--strip-non-ascii nil))))

(ert-deftest agent-shell-to-go-test-core-sanitize-channel-name ()
  "Channel name sanitization lowercases, collapses hyphens, and trims."
  (should (equal "my-project" (agent-shell-to-go--sanitize-channel-name "My Project")))
  (should (equal "foo-bar" (agent-shell-to-go--sanitize-channel-name "foo---bar")))
  (should (equal "foo-bar" (agent-shell-to-go--sanitize-channel-name "-foo-bar-")))
  (should (equal "abc123" (agent-shell-to-go--sanitize-channel-name "ABC123")))
  (let ((long (make-string 100 ?a)))
    (should (= 80 (length (agent-shell-to-go--sanitize-channel-name long))))))

(ert-deftest agent-shell-to-go-test-core-truncate-text ()
  "Text within limit is unchanged; longer text gets a hint appended."
  (should (equal "short" (agent-shell-to-go--truncate-text "short")))
  (let* ((text (make-string 600 ?x))
         (result (agent-shell-to-go--truncate-text text)))
    (should (= 500 (length (substring result 0 500))))
    (should (string-match-p "expand" result)))
  (let* ((text (make-string 20 ?x))
         (result (agent-shell-to-go--truncate-text text 10)))
    (should (string-match-p "expand" result))
    (should (string-prefix-p (make-string 10 ?x) result))))

(ert-deftest agent-shell-to-go-test-core-transport-registry ()
  "Transports can be registered and retrieved by name."
  (let ((tr (agent-shell-to-go-test-make))
        (agent-shell-to-go--transports (make-hash-table :test 'eq)))
    (should (null (agent-shell-to-go-get-transport 'mytest)))
    (agent-shell-to-go-register-transport 'mytest tr)
    (should (eq tr (agent-shell-to-go-get-transport 'mytest)))))

(ert-deftest agent-shell-to-go-test-core-active-transport-objects ()
  "Active transport list filters to registered transports only."
  (let ((tr (agent-shell-to-go-test-make))
        (agent-shell-to-go--transports (make-hash-table :test 'eq))
        (agent-shell-to-go-active-transports '(registered missing)))
    (agent-shell-to-go-register-transport 'registered tr)
    (let ((objs (agent-shell-to-go--active-transport-objects)))
      (should (= 1 (length objs)))
      (should (eq tr (car objs))))))

(ert-deftest agent-shell-to-go-test-core-presentation-expand-truncated ()
  "expand-truncated shows first 500 chars with hint when full text is longer."
  (let* ((tr (agent-shell-to-go-test-make))
         (full (make-string 1000 ?z))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed"))
         (agent-shell-to-go-storage-base-dir
          (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed")
          (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'expand-truncated t)
          (let ((text (agent-shell-to-go-transport-get-message-text tr "C1" id)))
            (should (string-prefix-p (make-string 500 ?z) text))
            (should (string-match-p "expand further" text))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-presentation-expand-full ()
  "expand-full shows full text when within message length limit."
  (let* ((tr (agent-shell-to-go-test-make))
         (full "complete output text")
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed"))
         (agent-shell-to-go-storage-base-dir
          (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed")
          (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'expand-full t)
          (should (equal full (agent-shell-to-go-transport-get-message-text tr "C1" id))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-presentation-collapse-restores ()
  "Removing expand reaction restores the collapsed form."
  (let* ((tr (agent-shell-to-go-test-make))
         (full (make-string 800 ?z))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed-header"))
         (agent-shell-to-go-storage-base-dir
          (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed-header")
          (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'expand-full nil)
          (should (equal "collapsed-header"
                         (agent-shell-to-go-transport-get-message-text tr "C1" id))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-save-load-file ()
  "save-file and load-file round-trip correctly."
  (let* ((dir (make-temp-file "astg-test-" t))
         (path (expand-file-name "sub/dir/test.txt" dir)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-file path "hello world")
          (should (equal "hello world" (agent-shell-to-go--load-file path)))
          (should (null (agent-shell-to-go--load-file (concat path ".missing")))))
      (delete-directory dir t))))

(provide 'agent-shell-to-go-test-core)
;;; agent-shell-to-go-test-core.el ends here
