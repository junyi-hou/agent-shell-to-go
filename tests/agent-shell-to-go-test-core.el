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
    (agent-shell-to-go-test-fire-reaction tr "C1" id "testuser" 'hide t)
    (should (string-match-p "hidden"
                            (or (agent-shell-to-go-transport-get-message-text tr "C1" id) "")))
    (agent-shell-to-go-test-fire-reaction tr "C1" id "testuser" 'hide nil)
    (should (equal "original text"
                   (agent-shell-to-go-transport-get-message-text tr "C1" id)))))

(ert-deftest agent-shell-to-go-test-core-slash-arg-parsing ()
  "Slash command args parse correctly for each command."
  (let ((args (agent-shell-to-go--parse-slash-args "/new-agent" "~/code/myproject")))
    (should (equal "~/code/myproject" (plist-get args :folder)))
    (should (null (plist-get args :container-p))))
  (let ((args (agent-shell-to-go--parse-slash-args "/new-agent-container" "~/code/foo")))
    (should (equal "~/code/foo" (plist-get args :folder)))
    (should (plist-get args :container-p)))
  (let ((args (agent-shell-to-go--parse-slash-args "/new-project" "myapp")))
    (should (equal "myapp" (plist-get args :project-name)))))

(provide 'agent-shell-to-go-test-core)
;;; agent-shell-to-go-test-core.el ends here
