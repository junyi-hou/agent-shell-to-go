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

(let ((root (expand-file-name ".." (file-name-directory
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
      (setq agent-shell-to-go--from-remote nil)
      (setq agent-shell-to-go--current-agent-message nil)
      (setq agent-shell-to-go--tool-calls nil)
      (setq agent-shell--state
            (list (cons :buffer buf)
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
  (mapcar (lambda (c) (nth 3 c))
          (agent-shell-to-go-test-calls transport 'send-text)))

(defun agent-shell-to-go-test--make-notification (update-type &rest update-fields)
  "Build an ACP notification alist for UPDATE-TYPE with UPDATE-FIELDS."
  `((params . ((update . ((sessionUpdate . ,update-type)
                          ,@update-fields))))))

; --on-send-command 

(ert-deftest agent-shell-to-go-test-bridge-send-command-normal ()
  "Normal prompt sends formatted user message then Processing notice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (agent-shell-to-go--on-send-command
           (lambda (&rest _) nil) :prompt "hello world")
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "hello world" (car texts)))
            (should (string-match-p "Processing" (cadr texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-send-command-from-remote ()
  "Remote-originated prompt is not echoed; from-remote flag is cleared."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (setq agent-shell-to-go--from-remote t)
          (agent-shell-to-go--on-send-command
           (lambda (&rest _) nil) :prompt "injected text")
          (should (null (agent-shell-to-go-test-calls tr 'send-text)))
          (should (null agent-shell-to-go--from-remote)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-send-command-mode-off ()
  "Nothing is sent when agent-shell-to-go-mode is nil."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (with-current-buffer buf
          (setq agent-shell-to-go-mode nil)
          (agent-shell-to-go--on-send-command
           (lambda (&rest _) nil) :prompt "hello")
          (should (null (agent-shell-to-go-test-calls tr 'send-text))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-notification: agent_message_chunk 

(ert-deftest agent-shell-to-go-test-bridge-chunk-accumulates ()
  "agent_message_chunk accumulates without sending anything."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (noop (lambda (&rest _) nil)))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           noop :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "agent_message_chunk"
                              '(content . ((text . "hello ")))))
          (agent-shell-to-go--on-notification
           noop :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "agent_message_chunk"
                              '(content . ((text . "world")))))
          (should (null (agent-shell-to-go-test-calls tr 'send-text)))
          (should (equal "hello world"
                         (buffer-local-value 'agent-shell-to-go--current-agent-message buf))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-heartbeat-stop 

(ert-deftest agent-shell-to-go-test-bridge-heartbeat-flushes ()
  "heartbeat-stop flushes accumulated agent text and sends Ready notice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf)))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "agent_message_chunk"
                              '(content . ((text . "agent reply")))))
          (with-current-buffer buf
            (agent-shell-to-go--on-heartbeat-stop (lambda (&rest _) nil)))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "agent reply" (car texts)))
            (should (string-match-p "Ready" (cadr texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-notification: tool_call 

(ert-deftest agent-shell-to-go-test-bridge-tool-call-sends-start ()
  "tool_call notification sends formatted start message."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf)))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "tool_call"
                              '(toolCallId . "tc1")
                              '(title . "Bash")
                              '(rawInput . ((command . "ls -la")))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "ls -la" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-dedup ()
  "Duplicate toolCallId is not sent twice."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (notif (agent-shell-to-go-test--make-notification
                 "tool_call"
                 '(toolCallId . "tc1")
                 '(title . "Bash")
                 '(rawInput . ((command . "ls"))))))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification (lambda (&rest _) nil)
                                              :state state :acp-notification notif)
          (agent-shell-to-go--on-notification (lambda (&rest _) nil)
                                              :state state :acp-notification notif)
          (should (= 1 (length (agent-shell-to-go-test-calls tr 'send-text)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-flushes-pending-text ()
  "tool_call flushes any accumulated agent message before the tool start."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq agent-shell-to-go--current-agent-message "thinking..."))
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "tool_call"
                              '(toolCallId . "tc2")
                              '(title . "Read")
                              '(rawInput . ((file_path . "/tmp/foo.txt")))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 2 (length texts)))
            (should (string-match-p "thinking" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-notification: tool_call_update 

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-completed-icon-only ()
  "Completed update sends icon only when show-tool-output is nil."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (agent-shell-to-go-show-tool-output nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-to-go--save-truncated-message)
                   (lambda (&rest _) nil)))
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "tool_call_update"
                              '(status . "completed")
                              '(rawOutput . "file contents here")))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "\\[ok\\]" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-completed-full-output ()
  "Completed update sends full result text when show-tool-output is t."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (agent-shell-to-go-show-tool-output t))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "tool_call_update"
                              '(status . "completed")
                              '(rawOutput . "file contents here")))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "file contents here" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-update-failed ()
  "Failed tool call update sends :x: icon."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf)))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-notification
           (lambda (&rest _) nil) :state state
           :acp-notification (agent-shell-to-go-test--make-notification
                              "tool_call_update"
                              '(status . "failed")))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "\\[fail\\]" (car texts)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --on-request: permission 

(ert-deftest agent-shell-to-go-test-bridge-on-request-permission ()
  "Permission request sends warning and registers in pending-permissions."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (state (buffer-local-value 'agent-shell--state buf))
         (agent-shell-to-go--pending-permissions nil))
    (unwind-protect
        (progn
          (agent-shell-to-go--on-request
           (lambda (&rest _) nil)
           :state state
           :acp-request
           `((id . "req1")
             (method . "session/request_permission")
             (params . ((toolCall . ((title . "Bash")
                                     (rawInput . ((command . "rm -rf /tmp/test")))))
                         (options . [((kind . "allow") (optionId . "o-allow"))
                                     ((kind . "deny") (optionId . "o-deny"))])))))
          (let ((texts (agent-shell-to-go-test--sent-texts tr)))
            (should (= 1 (length texts)))
            (should (string-match-p "Permission Required" (car texts)))
            (should (string-match-p "rm -rf /tmp/test" (car texts))))
          (should (= 1 (length agent-shell-to-go--pending-permissions)))
          (let ((info (cdar agent-shell-to-go--pending-permissions)))
            (should (equal "req1" (plist-get info :request-id)))
            (should (eq buf (plist-get info :buffer)))))
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
          (agent-shell-to-go-test-fire-message
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
          (agent-shell-to-go-test-fire-message
           tr "test-channel" "test-thread" "u1" "queued msg")
          (should (equal "queued msg" enqueued)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-on-message-unknown-thread ()
  "Message in an unknown thread is silently ignored."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr)))
    (unwind-protect
        (progn
          (agent-shell-to-go-test-fire-message
           tr "test-channel" "other-thread" "u1" "ignored")
          (should (null (agent-shell-to-go-test-calls tr 'send-text))))
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
          (agent-shell-to-go-test-fire-message
           tr "test-channel" "test-thread" "u1" "!stop")
          (should interrupted)
          (should (string-match-p "interrupted"
                                  (car (agent-shell-to-go-test--sent-texts tr)))))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; Inbound reaction hook 

(ert-deftest agent-shell-to-go-test-bridge-reaction-heart ()
  "Heart reaction injects a message referencing the reacted-to text."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (msg-id (agent-shell-to-go-transport-send-text
                  tr "test-channel" "test-thread" "great work"))
         (injected nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-to-go--inject-message)
                   (lambda (text) (setq injected text))))
          (agent-shell-to-go-test-fire-reaction
           tr "test-channel" msg-id "u1" 'heart t)
          (should (stringp injected))
          (should (string-match-p "heart reacted" injected))
          (should (string-match-p "great work" injected)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-reaction-permission-allow ()
  "permission-allow reaction calls send-permission-response with the allow option-id."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (msg-id (agent-shell-to-go-transport-send-text
                  tr "test-channel" "test-thread" "allow?"))
         (responded-with nil)
         (agent-shell-to-go--pending-permissions
          (list (cons (list 'test "test-channel" msg-id)
                      (list :request-id "req1"
                            :buffer buf
                            :options [((kind . "allow") (optionId . "opt-allow"))
                                      ((kind . "deny") (optionId . "opt-deny"))])))))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                   (lambda (&rest args)
                     (setq responded-with (plist-get args :option-id)))))
          (agent-shell-to-go-test-fire-reaction
           tr "test-channel" msg-id "u1" 'permission-allow t)
          (should (equal "opt-allow" responded-with)))
      (setq agent-shell-to-go--pending-permissions nil)
      (agent-shell-to-go-test--cleanup-buffer buf))))

(ert-deftest agent-shell-to-go-test-bridge-reaction-permission-reject ()
  "permission-reject reaction calls send-permission-response with the deny option-id."
  (let* ((tr (agent-shell-to-go-test-make))
         (buf (agent-shell-to-go-test--make-bridge-buffer tr))
         (msg-id (agent-shell-to-go-transport-send-text
                  tr "test-channel" "test-thread" "reject?"))
         (responded-with nil)
         (agent-shell-to-go--pending-permissions
          (list (cons (list 'test "test-channel" msg-id)
                      (list :request-id "req2"
                            :buffer buf
                            :options [((kind . "allow") (optionId . "opt-allow"))
                                      ((kind . "deny") (optionId . "opt-deny"))])))))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                   (lambda (&rest args)
                     (setq responded-with (plist-get args :option-id)))))
          (agent-shell-to-go-test-fire-reaction
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
        (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                   (lambda (&rest _) (setq called t))))
          (agent-shell-to-go-test-fire-reaction
           tr "test-channel" "no-such-msg" "u1" 'permission-allow t)
          (should (null called)))
      (agent-shell-to-go-test--cleanup-buffer buf))))

; --find-option-id

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-allow ()
  "Returns optionId for allow kind variants."
  (let ((options '(((kind . "deny") (optionId . "d1"))
                   ((kind . "allow") (optionId . "a1")))))
    (should (equal "a1" (agent-shell-to-go--find-option-id options 'permission-allow))))
  (let ((options '(((kind . "accept") (optionId . "a2")))))
    (should (equal "a2" (agent-shell-to-go--find-option-id options 'permission-allow))))
  (let ((options '(((kind . "allow_once") (optionId . "a3")))))
    (should (equal "a3" (agent-shell-to-go--find-option-id options 'permission-allow)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-always ()
  "Returns optionId for always kind variants."
  (let ((options '(((kind . "always") (optionId . "al1")))))
    (should (equal "al1" (agent-shell-to-go--find-option-id options 'permission-always))))
  (let ((options '(((kind . "alwaysAllow") (optionId . "al2")))))
    (should (equal "al2" (agent-shell-to-go--find-option-id options 'permission-always))))
  (let ((options '(((kind . "allow_always") (optionId . "al3")))))
    (should (equal "al3" (agent-shell-to-go--find-option-id options 'permission-always)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-reject ()
  "Returns optionId for reject kind variants."
  (let ((options '(((kind . "deny") (optionId . "r1")))))
    (should (equal "r1" (agent-shell-to-go--find-option-id options 'permission-reject))))
  (let ((options '(((kind . "reject") (optionId . "r2")))))
    (should (equal "r2" (agent-shell-to-go--find-option-id options 'permission-reject))))
  (let ((options '(((kind . "reject_once") (optionId . "r3")))))
    (should (equal "r3" (agent-shell-to-go--find-option-id options 'permission-reject)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-fallback-id ()
  "Falls back to `id' key when `optionId' is absent."
  (let ((options '(((kind . "allow") (id . "fallback-id")))))
    (should (equal "fallback-id" (agent-shell-to-go--find-option-id options 'permission-allow)))))

(ert-deftest agent-shell-to-go-test-bridge-find-option-id-no-match ()
  "Returns nil when no option matches the action."
  (let ((options '(((kind . "deny") (optionId . "r1")))))
    (should (null (agent-shell-to-go--find-option-id options 'permission-allow))))
  (should (null (agent-shell-to-go--find-option-id nil 'permission-allow))))

(provide 'agent-shell-to-go-test-bridge)
;;; agent-shell-to-go-test-bridge.el ends here
