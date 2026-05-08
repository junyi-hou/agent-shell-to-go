;;; agent-shell-to-go-test-bridge.el --- Tests for agent-shell integration bridge -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for agent-shell-to-go-bridge.el.
;;
;; Strategy: create a minimal fake buffer (buffer-local vars matching what
;; bridge-enable would leave behind), wire a test transport, then call the
;; advice functions directly — no real agent-shell session needed.
;; agent-shell-specific functions are stubbed with cl-letf per test.
;;
;; Run:
;;   emacsclient -e '(load-file "tests/agent-shell-to-go-test-bridge.el")'
;;   emacsclient -e '(ert-run-tests-batch "^agent-shell-to-go-test-bridge-")'

;;; Code:

(require 'ert)
(require 'cl-lib)

(let ((root
       (expand-file-name ".."
                         (file-name-directory
                          (or load-file-name buffer-file-name ".")))))
  (add-to-list 'load-path root))

(require 'agent-shell-to-go)
(require 'mock-transport)
(require 'agent-shell-to-go-bridge)

; Helpers 

(defun agent-shell-to-go-test--make-bridge-buffer (transport)
  "Return a buffer wired as if `agent-shell-to-go--bridge-enable' ran on it."
  (let ((buf (generate-new-buffer "*test-agent-shell-bridge*")))
    (with-current-buffer buf
      (setq major-mode 'agent-shell-mode)
      (setq agent-shell-to-go-mode t)
      (setq agent-shell-to-go--transport transport)
      (setq agent-shell-to-go--channel-id "test-channel")
      (setq agent-shell-to-go--thread-id "test-thread")
      (setq agent-shell-to-go--remote-queued nil)
      (setq agent-shell-to-go--current-agent-message nil)
      (setq agent-shell-to-go--tool-calls nil)
      (setq agent-shell--state
            (list
             (cons :buffer buf)
             (cons :client nil)
             (cons :pending-requests nil)
             (cons :session (list (cons :id "s1") (cons :mode-id nil)))))
      (push buf agent-shell-to-go--active-buffers))
    buf))

(defun agent-shell-to-go-test--cleanup-buffer (buf)
  "Remove BUF from active list and kill it."
  (setq agent-shell-to-go--active-buffers
        (delete buf agent-shell-to-go--active-buffers))
  (when (buffer-live-p buf)
    (kill-buffer buf)))

(defun agent-shell-to-go-test--sent-texts (transport)
  "Return texts of all send-text calls on TRANSPORT in order."
  (mapcar
   (lambda (c) (nth 3 c)) (agent-shell-to-go-test-outbound-calls transport 'send-text)))

(defun agent-shell-to-go-test--make-notification (update-type &rest update-fields)
  "Build an ACP notification alist for UPDATE-TYPE with UPDATE-FIELDS."
  `((params . ((update . ((sessionUpdate . ,update-type) ,@update-fields))))))

; --on-send-command 

(ert-deftest agent-shell-to-go-test-bridge-send-command-normal ()
  "Normal prompt sends formatted user message then Processing notice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--on-send-command
           (lambda (&rest _) nil)
           :prompt "hello world")
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "hello world" (car texts)))
            (should (string-match-p "Processing" (cadr texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-send-command-from-remote ()
  "Remote-originated prompt is not echoed; removed from remote-queued list."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (setq agent-shell-to-go--remote-queued '("injected text"))
          (agent-shell-to-go--on-send-command
           (lambda (&rest _) nil)
           :prompt "injected text")
          (should (null (agent-shell-to-go-test-outbound-calls tr 'send-text)))
          (should (not (member "injected text" agent-shell-to-go--remote-queued))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-send-command-mode-off ()
  "Nothing is sent when agent-shell-to-go-mode is nil."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (setq agent-shell-to-go-mode nil)
          (agent-shell-to-go--on-send-command (lambda (&rest _) nil) :prompt "hello")
          (should (null (agent-shell-to-go-test-outbound-calls tr 'send-text))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-notification 

(ert-deftest agent-shell-to-go-test-bridge-chunk-accumulates ()
  "agent_message_chunk accumulates without sending anything."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (noop (lambda (&rest _) nil)))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           noop
           :state state
           :acp-notification
           (agent-shell-to-go-test--make-notification "agent_message_chunk"
                                                      '(content . ((text . "hello ")))))
          (agent-shell-to-go--on-notification
           noop
           :state state
           :acp-notification
           (agent-shell-to-go-test--make-notification "agent_message_chunk"
                                                      '(content . ((text . "world")))))
          (should (null (agent-shell-to-go-test-outbound-calls tr 'send-text)))
          (should
           (equal
            "hello world"
            (buffer-local-value 'agent-shell-to-go--current-agent-message buf))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-other-notifications-no-accumulate ()
  "Notifications other than agent_message_chunk do NOT trigger accumulation."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (noop (lambda (&rest _) nil)))
    (unwind-protect
        ;; Session update types per the Agent Client Protocol:
        ;; https://agentclientprotocol.com/protocol/schema#sessionupdate
        ;; Only agent_message_chunk triggers accumulation; these must not.
        (dolist (update-type
                 '("agent_thought_chunk"
                   "user_message_chunk"
                   "tool_call"
                   "tool_call_update"
                   "plan"
                   "available_commands_update"
                   "current_mode_update"
                   "config_option_update"
                   "usage_update"
                   "session_push_end"))
          (agent-shell-to-go--on-notification
           noop
           :state state
           :acp-notification
           (agent-shell-to-go-test--make-notification
            update-type
            '(content . ((text . "should be ignored")))))
          (should (null (agent-shell-to-go-test-outbound-calls tr 'send-text)))
          (should
           (null (buffer-local-value 'agent-shell-to-go--current-agent-message buf))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-turn-complete 

(ert-deftest agent-shell-to-go-test-bridge-turn-complete-flushes ()
  "turn-complete flushes accumulated agent text and sends Ready notice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq agent-shell-to-go--current-agent-message "agent reply"))
          (with-current-buffer buf
            (agent-shell-to-go--on-turn-complete nil))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "agent reply" (car texts)))
            (should (string-match-p "Ready" (cadr texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --bridge-on-tool-call-update: start 

(ert-deftest agent-shell-to-go-test-bridge-tool-call-sends-start ()
  "tool-call-update event sends formatted start message."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--bridge-on-tool-call-update
           (list
            :data
            (list
             :tool-call-id "tc1"
             :tool-call
             (list
              :status "in_progress"
              :title "Bash"
              :raw-input
              (list 'command "ls -la")
              :content nil))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "ls -la" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-dedup ()
  "Duplicate toolCallId is not sent twice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (event
          (list
           :data
           (list
            :tool-call-id "tc1"
            :tool-call
            (list
             :status "in_progress"
             :title "Bash"
             :raw-input (list :command "ls")
             :content nil)))))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--bridge-on-tool-call-update event)
          (agent-shell-to-go--bridge-on-tool-call-update event)
          (should (= 1 (length (agent-shell-to-go-test-outbound-calls tr 'send-text)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-flushes-pending-text ()
  "tool-call-update flushes any accumulated agent message before the tool start."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (setq agent-shell-to-go--current-agent-message "thinking...")
          (agent-shell-to-go--bridge-on-tool-call-update
           (list
            :data
            (list
             :tool-call-id "tc2"
             :tool-call
             (list
              :status "in_progress"
              :title "Read"
              :raw-input
              (list :file_path "/tmp/foo.txt")
              :content nil))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "thinking" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --bridge-on-tool-call-update: completed/failed

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-completed-icon-only ()
  "Completed update sends icon only when show-tool-output is nil."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (agent-shell-to-go-show-tool-output nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-to-go--save-truncated-message)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (agent-shell-to-go--bridge-on-tool-call-update
             (list
              :data
              (list
               :tool-call-id "tc1"
               :tool-call
               (list
                :status "completed"
                :raw-input nil
                :content
                [((:content . ((:text . "file contents here"))))])))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "\\[ok\\]" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-completed-full-output ()
  "Completed update sends full result text when show-tool-output is t."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (agent-shell-to-go-show-tool-output t))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--bridge-on-tool-call-update
           (list
            :data
            (list
             :tool-call-id "tc1"
             :tool-call
             (list
              :status "completed"
              :raw-input nil
              :content
              [((:content . ((:text . "file contents here"))))]))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "file contents here" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-failed ()
  "Failed tool call update sends [fail] icon."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--bridge-on-tool-call-update
           (list
            :data
            (list
             :tool-call-id "tc1"
             :tool-call
             (list :status "failed" :raw-input nil :content nil))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "\\[fail\\]" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --permission-responder

(ert-deftest agent-shell-to-go-test-bridge-permission-responder ()
  "Permission responder sends notice, registers :respond/:options in pending-permissions, returns t."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (respond-fn (lambda (_id) nil))
         (options
          (list
           (list :kind "allow" :option-id "o-allow")
           (list :kind "deny" :option-id "o-deny")))
         (agent-shell-to-go--pending-permissions nil))
    (unwind-protect
        (with-current-buffer buf
          (let ((result
                 (agent-shell-to-go--permission-responder
                  (list
                   :tool-call
                   (list :title "Bash")
                   :options options
                   :respond respond-fn))))
            (should (eq t result))
            (let ((texts (agent-shell-to-go-test--sent-texts tr)))
              (should (= 1 (length texts)))
              (should (string-match-p "Permission Required" (car texts))))
            (should (= 1 (length agent-shell-to-go--pending-permissions)))
            (let ((info (cdar agent-shell-to-go--pending-permissions)))
              (should (eq respond-fn (map-elt info :respond)))
              (should (equal options (map-elt info :options))))))
      (setq agent-shell-to-go--pending-permissions nil)
      (agent-shell-to-go-test--cleanup-buffer buf))))

; Inbound message hook 

(ert-deftest agent-shell-to-go-test-bridge-on-message-inject ()
  "Message in known thread submits text to agent."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (submitted nil))
    (unwind-protect
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil))
                  ((symbol-function 'shell-maker-submit) (lambda () (setq submitted t)))
                  ((symbol-function 'derived-mode-p)
                   (lambda (mode) (eq mode 'agent-shell-mode))))
          (agent-shell-to-go-test-inbound-message
           tr "test-channel" "test-thread" "u1" "do the thing")
          (should submitted))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-on-message-busy-enqueues ()
  "Message when shell is busy enqueues rather than injecting."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (enqueued nil))
    (unwind-protect
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t))
                  ((symbol-function 'agent-shell--enqueue-request)
                   (lambda (&key prompt) (setq enqueued prompt)))
                  ((symbol-function 'derived-mode-p)
                   (lambda (mode) (eq mode 'agent-shell-mode))))
          (agent-shell-to-go-test-inbound-message
           tr "test-channel" "test-thread" "u1" "queued msg")
          (should (equal "queued msg" enqueued)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-on-message-unknown-thread ()
  "Message in an unknown thread is silently ignored."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (progn
          (agent-shell-to-go-test-inbound-message
           tr "test-channel" "other-thread" "u1" "ignored")
          (should (null (agent-shell-to-go-test-outbound-calls tr 'send-text))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-on-message-stop-command ()
  "!stop interrupts the agent and sends a confirmation."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (interrupted nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-interrupt)
                   (lambda (&optional _force) (setq interrupted t)))
                  ((symbol-function 'derived-mode-p)
                   (lambda (mode) (eq mode 'agent-shell-mode))))
          (agent-shell-to-go-test-inbound-message
           tr "test-channel" "test-thread" "u1" "!stop")
          (should interrupted)
          (should
           (string-match-p
            "interrupted" (car (agent-shell-to-go-test--sent-texts tr)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; Inbound reaction hook 

(ert-deftest agent-shell-to-go-test-bridge-reaction-permission-allow ()
  "permission-allow reaction calls the :respond closure with the allow option-id."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (msg-id
          (agent-shell-to-go-transport-send-text
           tr "test-channel" "test-thread" "allow?"))
         (responded-with nil)
         (agent-shell-to-go--pending-permissions
          (list
           (cons
            (list 'test "test-channel" msg-id)
            (list
             :respond (lambda (id) (setq responded-with id))
             :options
             (list
              (list :kind "allow" :option-id "opt-allow")
              (list :kind "deny" :option-id "opt-deny")))))))
    (unwind-protect
        (progn
          (agent-shell-to-go-test-inbound-reaction
           tr "test-channel" msg-id "u1" 'permission-allow t)
          (should (equal "opt-allow" responded-with)))
      (setq agent-shell-to-go--pending-permissions nil)
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-reaction-permission-reject ()
  "permission-reject reaction calls the :respond closure with the deny option-id."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (msg-id
          (agent-shell-to-go-transport-send-text
           tr "test-channel" "test-thread" "reject?"))
         (responded-with nil)
         (agent-shell-to-go--pending-permissions
          (list
           (cons
            (list 'test "test-channel" msg-id)
            (list
             :respond (lambda (id) (setq responded-with id))
             :options
             (list
              (list :kind "allow" :option-id "opt-allow")
              (list :kind "deny" :option-id "opt-deny")))))))
    (unwind-protect
        (progn
          (agent-shell-to-go-test-inbound-reaction
           tr "test-channel" msg-id "u1" 'permission-reject t)
          (should (equal "opt-deny" responded-with)))
      (setq agent-shell-to-go--pending-permissions nil)
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-reaction-unknown-msg ()
  "Reaction on a msg-id with no pending entry does nothing."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (agent-shell-to-go--pending-permissions nil)
         (called nil))
    (unwind-protect
        (progn
          (agent-shell-to-go-test-inbound-reaction
           tr "test-channel" "no-such-msg" "u1" 'permission-allow t)
          (should (null called)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --find-option-id

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-allow ()
  "Returns :option-id for allow kind variants."
  (let ((options
         (list
          (list :kind "deny" :option-id "d1") (list :kind "allow" :option-id "a1"))))
    (should (equal "a1" (agent-shell-to-go--find-option-id options 'permission-allow))))
  (let ((options (list (list :kind "accept" :option-id "a2"))))
    (should (equal "a2" (agent-shell-to-go--find-option-id options 'permission-allow))))
  (let ((options (list (list :kind "allow_once" :option-id "a3"))))
    (should
     (equal "a3" (agent-shell-to-go--find-option-id options 'permission-allow)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-always ()
  "Returns :option-id for always kind variants."
  (let ((options (list (list :kind "always" :option-id "al1"))))
    (should
     (equal "al1" (agent-shell-to-go--find-option-id options 'permission-always))))
  (let ((options (list (list :kind "alwaysAllow" :option-id "al2"))))
    (should
     (equal "al2" (agent-shell-to-go--find-option-id options 'permission-always))))
  (let ((options (list (list :kind "allow_always" :option-id "al3"))))
    (should
     (equal "al3" (agent-shell-to-go--find-option-id options 'permission-always)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-reject ()
  "Returns :option-id for reject kind variants."
  (let ((options (list (list :kind "deny" :option-id "r1"))))
    (should
     (equal "r1" (agent-shell-to-go--find-option-id options 'permission-reject))))
  (let ((options (list (list :kind "reject" :option-id "r2"))))
    (should
     (equal "r2" (agent-shell-to-go--find-option-id options 'permission-reject))))
  (let ((options (list (list :kind "reject_once" :option-id "r3"))))
    (should
     (equal "r3" (agent-shell-to-go--find-option-id options 'permission-reject)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-no-match ()
  "Returns nil when no option matches the action."
  (let ((options (list (list :kind "deny" :option-id "r1"))))
    (should (null (agent-shell-to-go--find-option-id options 'permission-allow))))
  (should (null (agent-shell-to-go--find-option-id nil 'permission-allow))))

(provide 'agent-shell-to-go-test-bridge)
;;; agent-shell-to-go-test-bridge.el ends here
