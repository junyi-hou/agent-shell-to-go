;;; agent-shell-to-go-core-test.el --- Tests for agent-shell-to-go.el -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; Unit tests for agent-shell-to-go-core.el.  Each test exercises one
;; core behaviour in isolation using a mock transport — no Slack/Discord
;; credentials required.
;;
;; Run:
;;   make test TEST=agent-shell-to-go-test-core.el
;;
;; APIs under test:
;;
;;   agent-shell-to-go--handle-presentation-reaction
;;     - presentation-hide-unhide: hide reaction edits message; removal restores original
;;     - presentation-expand-truncated: expand-truncated shows first 500 chars with hint
;;     - presentation-expand-full: expand-full shows full text
;;     - presentation-collapse-restores: removing expand reaction restores collapsed form
;;
;;   agent-shell-to-go-register-transport / agent-shell-to-go-get-transport
;;     - transport-registry: transports registered and retrieved by name
;;
;;   agent-shell-to-go--all-transport-objects
;;     - all-transport-objects: default and alist transports collected, deduplicated
;;
;;   agent-shell-to-go--get-transport
;;     - default-transport-prefix-match: longest alist prefix wins; falls back to default

;;; Code:

(require 'ert)

(require 'mock-transport)

(ert-deftest agent-shell-to-go-test-core-presentation-hide-unhide ()
  "Presentation reaction handler edits the message and restores it on removal."
  (let* ((tr (agent-shell-to-go-test-make))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "original text")))
    (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'hide t)
    (should
     (string-match-p
      "hidden" (or (agent-shell-to-go-transport-get-message-text tr "C1" id) "")))
    (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'hide nil)
    (should
     (equal
      "original text" (agent-shell-to-go-transport-get-message-text tr "C1" id)))))

(ert-deftest agent-shell-to-go-test-core-presentation-expand-truncated ()
  "expand-truncated shows first 500 chars with hint when full text is longer."
  (let* ((tr (agent-shell-to-go-test-make))
         (full (make-string 1000 ?z))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed"))
         (agent-shell-to-go-storage-base-dir (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed")
          (agent-shell-to-go-test-inbound-reaction
           tr "C1" id "testuser" 'expand-truncated t)
          (let ((text (agent-shell-to-go-transport-get-message-text tr "C1" id)))
            (should (string-prefix-p (make-string 500 ?z) text))
            (should (string-match-p "expand further" text))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-presentation-expand-full ()
  "expand-full shows full text when within message length limit."
  (let* ((tr (agent-shell-to-go-test-make))
         (full "complete output text")
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed"))
         (agent-shell-to-go-storage-base-dir (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed")
          (agent-shell-to-go-test-inbound-reaction tr "C1" id "testuser" 'expand-full t)
          (should
           (equal full (agent-shell-to-go-transport-get-message-text tr "C1" id))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-presentation-collapse-restores ()
  "Removing expand reaction restores the collapsed form."
  (let* ((tr (agent-shell-to-go-test-make))
         (full (make-string 800 ?z))
         (id (agent-shell-to-go-transport-send-text tr "C1" nil "collapsed-header"))
         (agent-shell-to-go-storage-base-dir (make-temp-file "astg-test-" t)))
    (unwind-protect
        (progn
          (agent-shell-to-go--save-truncated-message tr "C1" id full "collapsed-header")
          (agent-shell-to-go-test-inbound-reaction
           tr "C1" id "testuser" 'expand-full nil)
          (should
           (equal
            "collapsed-header"
            (agent-shell-to-go-transport-get-message-text tr "C1" id))))
      (delete-directory agent-shell-to-go-storage-base-dir t))))

(ert-deftest agent-shell-to-go-test-core-transport-registry ()
  "Transports can be registered and retrieved by name."
  (let ((tr (agent-shell-to-go-test-make))
        (agent-shell-to-go--transports nil))
    (should (null (agent-shell-to-go-get-transport 'mytest)))
    (agent-shell-to-go-register-transport 'mytest tr)
    (should (eq tr (agent-shell-to-go-get-transport 'mytest)))))

(ert-deftest agent-shell-to-go-test-core-all-transport-objects ()
  "All-transport list includes default and alist transports, deduplicated."
  (let* ((tr1 (agent-shell-to-go-test-make))
         (tr2 (agent-shell-to-go-test-make))
         (agent-shell-to-go--transports nil)
         (agent-shell-to-go-default-transport 'tr1)
         (agent-shell-to-go-project-transport-alist
          (list (cons "/work/acme/" 'tr2) (cons "/work/other/" 'tr1))))
    (agent-shell-to-go-register-transport 'tr1 tr1)
    (agent-shell-to-go-register-transport 'tr2 tr2)
    (let ((objs (agent-shell-to-go--all-transport-objects)))
      (should (= 2 (length objs)))
      (should (memq tr1 objs))
      (should (memq tr2 objs)))))

(ert-deftest agent-shell-to-go-test-core-default-transport-prefix-match ()
  "Longest prefix in alist wins; falls back to default when no match."
  (let* ((tr-default (agent-shell-to-go-test-make))
         (tr-work (agent-shell-to-go-test-make))
         (tr-acme (agent-shell-to-go-test-make))
         (agent-shell-to-go--transports nil)
         (agent-shell-to-go-default-transport 'default)
         (agent-shell-to-go-project-transport-alist
          (list (cons "/work/" 'work) (cons "/work/acme/" 'acme))))
    (agent-shell-to-go-register-transport 'default tr-default)
    (agent-shell-to-go-register-transport 'work tr-work)
    (agent-shell-to-go-register-transport 'acme tr-acme)
    (let ((default-directory "/home/user/"))
      (should (eq tr-default (agent-shell-to-go--get-transport))))
    (let ((default-directory "/work/other/"))
      (should (eq tr-work (agent-shell-to-go--get-transport))))
    (let ((default-directory "/work/acme/myproject/"))
      (should (eq tr-acme (agent-shell-to-go--get-transport))))))

(provide 'agent-shell-to-go-core-test)
;;; agent-shell-to-go-core-test.el ends here
