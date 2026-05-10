;;; agent-shell-to-go-test-bridge.el --- Unit tests for agent-shell-to-go-bridge.el -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; Unit tests for agent-shell-to-go-bridge.el.  Each test exercises one
;; bridge behaviour in isolation using a real agent-shell session backed by
;; mock-acp and a mock transport — no Slack/Discord credentials required.
;;
;; The full pipeline under test:
;;
;;   ACP protocol → agent-shell → bridge → mock transport
;;
;; Prerequisites:
;;   - Run `make test' from the project root; it clones and builds all deps automatically.
;;
;; Run:
;;   make test TEST=agent-shell-to-go-test-bridge.el

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'agent-shell)
(require 'agent-shell-mock-agent)
(require 'agent-shell-to-go)
(require 'mock-transport)

;;; Configuration

(defconst agent-shell-to-go-test-bridge--mock-acp-root
  (expand-file-name "deps/mock-acp"
                    (file-name-directory (or load-file-name buffer-file-name ".")))
  "Root directory of the mock-acp project.")

(defconst agent-shell-to-go-test-bridge--python
  (expand-file-name ".venv/bin/python" agent-shell-to-go-test-bridge--mock-acp-root)
  "Python interpreter in mock-acp's virtual environment.")

;;; Helpers

(defun agent-shell-to-go-test-bridge--wait-until (pred &optional timeout-sec)
  "Poll PRED every 100ms for up to TIMEOUT-SEC seconds (default 10).
Pumps process output each iteration.  Returns truthy on success, nil on timeout."
  (let ((deadline (+ (float-time) (or timeout-sec 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun agent-shell-to-go-test-bridge--session-id (buf)
  "Return the ACP session ID for BUF, or nil if not yet established."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (map-nested-elt agent-shell--state '(:session :id)))))

(defun agent-shell-to-go-test-bridge--sent-texts (transport)
  "Return all text payloads sent via TRANSPORT in call order."
  (mapcar
   (lambda (c) (nth 3 c)) (agent-shell-to-go-test-outbound-calls transport 'send-text)))

(defun agent-shell-to-go-test-bridge--wait-for-ready (transport &optional timeout)
  "Wait until TRANSPORT has received a Ready signal from the bridge.
Returns non-nil on success, nil on timeout."
  (agent-shell-to-go-test-bridge--wait-until
   (lambda ()
     (cl-some
      (lambda (text) (string-match-p "Ready" text))
      (agent-shell-to-go-test-bridge--sent-texts transport)))
   (or timeout 15)))

(defun agent-shell-to-go-test-bridge--start-session ()
  "Start an agent-shell session backed by mock-acp and return the buffer.

Configures `agent-shell-mock-agent-acp-command' to point at the local
mock-acp Python environment and calls `agent-shell-start'.  The caller
is responsible for cleanup (kill the buffer when done)."
  (let ((agent-shell-mock-agent-acp-command
         (list agent-shell-to-go-test-bridge--python "src/main.py"))
        (default-directory agent-shell-to-go-test-bridge--mock-acp-root))
    (agent-shell-start :config (agent-shell-mock-agent-make-agent-config))))

(defmacro agent-shell-to-go-test-bridge--with-session (transport buf &rest body)
  "Evaluate BODY with TRANSPORT bound to a mock transport and BUF to a live agent-shell buffer.

Starts an agent-shell session connected to mock-acp, waits for the ACP
session to be established, enables `agent-shell-to-go-mode' on BUF using
TRANSPORT, waits for the bridge to initialize, then evaluates BODY.  Always kills BUF on exit."
  (declare (indent 2))
  `(let* ((,transport (agent-shell-to-go-test-make))
          (,buf (agent-shell-to-go-test-bridge--start-session)))
     (unwind-protect
         (progn
           (unless (agent-shell-to-go-test-bridge--wait-until
                    (lambda () (agent-shell-to-go-test-bridge--session-id ,buf))
                    15)
             (error "Timed out waiting for mock-acp session to establish"))
           (with-current-buffer ,buf
             (cl-letf (((symbol-function 'agent-shell-to-go--get-transport)
                        (lambda () ,transport)))
               (agent-shell-to-go-mode 1)))
           ,@body)
       (setq agent-shell-to-go--pending-permissions nil)
       (when (buffer-live-p ,buf)
         (kill-buffer ,buf)))))

(defun agent-shell-to-go-test-bridge--send-prompt (buf text)
  "Send TEXT as a prompt in the agent-shell buffer BUF.

Calls `agent-shell--handle' directly, which goes through the full
initialization check and the bridge advice on `agent-shell--send-command'."
  (agent-shell--handle :command text :shell-buffer buf))

;;; Tests

(ert-deftest agent-shell-to-go-test-bridge-user-message-echoed ()
  "The user prompt is echoed to the transport before the agent replies."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test agent_message")
    (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
    (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should (cl-some (lambda (t) (string-match-p "test agent_message" t)) texts))
      (should (cl-some (lambda (t) (string-match-p "Processing" t)) texts)))))

(ert-deftest agent-shell-to-go-test-bridge-agent-message-forwarded ()
  "Agent message chunks are accumulated and forwarded to the transport on turn-complete."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test agent_message")
    (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
    (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should (cl-some (lambda (t) (string-match-p "Paris" t)) texts)))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-forwarded ()
  "Tool call results are forwarded to the transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test tool_call")
    (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
    (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
      ;; Bridge forwards tool call results — either [ok]/[fail] icon or full
      ;; formatted output depending on agent-shell-to-go-show-tool-output.
      (should
       (cl-some
        (lambda (t)
          (string-match-p "\\[ok\\]\\|\\[fail\\]\\|\\[completed\\]\\|\\[running\\]" t))
        texts)))))

;;; tool-call-update branching

(ert-deftest agent-shell-to-go-test-bridge-tool-call-output-shown ()
  "With show-tool-output t, completed tool call forwards full text output."
  (let ((agent-shell-to-go-show-tool-output t))
    (agent-shell-to-go-test-bridge--with-session tr buf
      (agent-shell-to-go-test-bridge--send-prompt buf "test tool_call_read")
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
      (should
       (cl-some
        (lambda (text) (string-match-p "File read successfully" text))
        (agent-shell-to-go-test-bridge--sent-texts tr))))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-output-hidden ()
  "With show-tool-output nil, completed tool call sends only the [ok] icon."
  (let ((agent-shell-to-go-show-tool-output nil))
    (agent-shell-to-go-test-bridge--with-session tr buf
      (agent-shell-to-go-test-bridge--send-prompt buf "test tool_call_read")
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
      (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
        (should-not
         (cl-some (lambda (text) (string-match-p "File read successfully" text)) texts))
        (should (cl-some (lambda (text) (equal text "[ok]")) texts))))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-diff-shown ()
  "With show-tool-output t, diff content uses transport-format-diff not plain text."
  (let ((agent-shell-to-go-show-tool-output t))
    (agent-shell-to-go-test-bridge--with-session tr buf
      (agent-shell-to-go-test-bridge--send-prompt buf "test tool_call_diff")
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
      (should
       (cl-some
        (lambda (text)
          (string-match-p "diff omitted in test transport" text))
        (agent-shell-to-go-test-bridge--sent-texts tr))))))

(ert-deftest agent-shell-to-go-test-bridge-tool-call-diff-hidden ()
  "With show-tool-output nil, diff content sends only the [ok] icon."
  (let ((agent-shell-to-go-show-tool-output nil))
    (agent-shell-to-go-test-bridge--with-session tr buf
      (agent-shell-to-go-test-bridge--send-prompt buf "test tool_call_diff")
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
      (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
        (should-not
         (cl-some
          (lambda (text) (string-match-p "diff omitted in test transport" text)) texts))
        (should (cl-some (lambda (text) (equal text "[ok]")) texts))))))

;;; permission responder + reaction

(ert-deftest agent-shell-to-go-test-bridge-permission-forwarded ()
  "Permission request from agent sends 'Permission Required' message to transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test request_permission")
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (cl-some
         (lambda (text) (string-match-p "Permission Required" text))
         (agent-shell-to-go-test-bridge--sent-texts tr)))))
    ;; Respond to unblock the mock-acp so it can send PromptResponse.
    (let* ((key (caar agent-shell-to-go--pending-permissions))
           (msg-id (nth 2 key))
           (channel (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-reaction
       tr channel msg-id "testuser" 'permission-allow t))
    (should (agent-shell-to-go-test-bridge--wait-for-ready tr))))

(ert-deftest agent-shell-to-go-test-bridge-permission-allow ()
  "permission-allow reaction removes the pending permission entry."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test request_permission")
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (and agent-shell-to-go--pending-permissions
             (cl-some
              (lambda (text) (string-match-p "Permission Required" text))
              (agent-shell-to-go-test-bridge--sent-texts tr))))))
    (let* ((key (caar agent-shell-to-go--pending-permissions))
           (msg-id (nth 2 key))
           (channel (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-reaction
       tr channel msg-id "testuser" 'permission-allow t)
      (should (null agent-shell-to-go--pending-permissions))
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr)))))

(ert-deftest agent-shell-to-go-test-bridge-permission-reject ()
  "permission-reject reaction removes the pending permission entry."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test request_permission")
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (and agent-shell-to-go--pending-permissions
             (cl-some
              (lambda (text) (string-match-p "Permission Required" text))
              (agent-shell-to-go-test-bridge--sent-texts tr))))))
    (let* ((key (caar agent-shell-to-go--pending-permissions))
           (msg-id (nth 2 key))
           (channel (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-reaction
       tr channel msg-id "testuser" 'permission-reject t)
      (should (null agent-shell-to-go--pending-permissions))
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr)))))

;;; inbound hook handling

(ert-deftest agent-shell-to-go-test-bridge-remote-message-not-echoed ()
  "Messages injected from the transport do not produce a [user] echo or Processing line.
Exercises the `agent-shell-to-go--remote-queued' suppression in
`agent-shell-to-go--on-send-command'."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-message
       tr channel-id thread-id "testuser" "test agent_message")
      (should (agent-shell-to-go-test-bridge--wait-for-ready tr))
      (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
        (should-not
         (cl-some
          (lambda (text) (string-match-p "\\[user\\].*test agent_message" text)) texts))
        (should-not
         (cl-some (lambda (text) (string-match-p "Processing" text)) texts))))))

(ert-deftest agent-shell-to-go-test-bridge-help-command ()
  "!help sends a command reference synchronously without touching agent-shell.
Exercises `agent-shell-to-go--handle-command' via the message hook."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-message
       tr channel-id thread-id "testuser" "!help")
      (should
       (cl-some
        (lambda (text) (string-match-p "Commands" text))
        (agent-shell-to-go-test-bridge--sent-texts tr))))))

(ert-deftest agent-shell-to-go-test-bridge-info-command ()
  "!info sends buffer/thread/channel/session info synchronously.
Exercises `agent-shell-to-go--handle-command' via the message hook."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-inbound-message
       tr channel-id thread-id "testuser" "!info")
      (let ((texts (agent-shell-to-go-test-bridge--sent-texts tr)))
        (should (cl-some (lambda (text) (string-match-p "Thread" text)) texts))
        (should (cl-some (lambda (text) (string-match-p "Channel" text)) texts))
        (should (cl-some (lambda (text) (string-match-p "Session" text)) texts))))))

(provide 'agent-shell-to-go-test-bridge)
;;; agent-shell-to-go-test-bridge.el ends here
