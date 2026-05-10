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
;;
;; APIs under test:
;;
;;   agent-shell-to-go--on-send-command
;;     - user-message-echoed: user prompt echo to transport
;;   agent-shell-to-go--on-turn-complete
;;     - agent-message-forwarded: agent message forwarding on turn end
;;     - remote-message-not-echoed: remote-injected messages produce no echo or Processing line
;;   agent-shell-to-go--bridge-on-tool-call-update
;;     - tool-call-forwarded: tool call forwarding (generic)
;;     - tool-call-output-shown: show-tool-output t: full text output
;;     - tool-call-output-hidden: show-tool-output nil: [ok] icon only
;;     - tool-call-diff-shown: diff branch, show-tool-output t
;;     - tool-call-diff-hidden: diff branch, show-tool-output nil
;;   agent-shell-to-go--permission-responder
;;     - permission-forwarded: permission request forwarding
;;   agent-shell-to-go--bridge-on-reaction
;;     - permission-allow: permission-allow clears pending entry
;;     - permission-reject: permission-reject clears pending entry
;;   agent-shell-to-go--handle-command
;;     - help-command: !help command response
;;     - info-command: !info command response
;;     - yolo-command: !yolo sets bypassPermissions mode
;;     - bypass-command: !bypass alias for !yolo
;;     - safe-command: !safe sets acceptEdits mode
;;     - accept-command: !accept alias for !safe
;;     - acceptedits-command: !acceptedits alias for !safe
;;     - plan-command: !plan sets plan mode
;;     - planmode-command: !planmode alias for !plan
;;     - mode-command: !mode returns current mode name
;;     - stop-command: !stop interrupts a long-running agent
;;   agent-shell-to-go--on-init-client
;;     - on-init-client-failure: failure branch when :client is nil
;;   agent-shell-to-go--on-error
;;     - on-error-init-failure: ACP init error forwarding
;;     - on-error-auth-failure: ACP auth error forwarding
;;     - on-error-prompt-failure: prompt error forwarding

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

(defun agent-shell-to-go-test-bridge--start-session-with-server
    (server &optional config-fn)
  "Like `agent-shell-to-go-test-bridge--start-session' but using SERVER script.
SERVER is a path relative to the mock-acp root (e.g. \"src/init_error_server.py\").
CONFIG-FN, if provided, is called with the base config alist and must return
the final config (use it to add extra keys such as :authenticate-request-maker)."
  (let ((agent-shell-mock-agent-acp-command
         (list agent-shell-to-go-test-bridge--python server))
        (default-directory agent-shell-to-go-test-bridge--mock-acp-root))
    (let ((config (agent-shell-mock-agent-make-agent-config)))
      (agent-shell-start
       :config
       (if config-fn
           (funcall config-fn config)
         config)))))

(defmacro agent-shell-to-go-test-bridge--with-error-session
    (transport buf server config-fn &rest body)
  "Like `agent-shell-to-go-test-bridge--with-session' but for error-path testing.

Starts a session using SERVER script (path relative to mock-acp root), applies
CONFIG-FN (or nil) to the base config, enables `agent-shell-to-go-mode'
immediately (without waiting for session establishment), then evaluates BODY.
Use this when the server is expected to fail during ACP initialization so the
normal session-ID wait would time out."
  (declare (indent 4))
  `(let* ((,transport (agent-shell-to-go-test-make))
          (,buf
           (agent-shell-to-go-test-bridge--start-session-with-server ,server
                                                                     ,config-fn)))
     (unwind-protect
         (progn
           (with-current-buffer ,buf
             (cl-letf (((symbol-function 'agent-shell-to-go--get-transport)
                        (lambda () ,transport)))
               (agent-shell-to-go-mode 1)))
           ,@body)
       (setq agent-shell-to-go--pending-permissions nil)
       (when (buffer-live-p ,buf)
         (kill-buffer ,buf)))))

(defmacro agent-shell-to-go-test-bridge--with-mode-stub (&rest body)
  "Evaluate BODY with `agent-shell--send-request' stubbed to call on-success immediately."
  `(cl-letf (((symbol-function 'agent-shell--send-request)
              (lambda (&rest args)
                (when-let* ((on-success (plist-get args :on-success)))
                  (funcall on-success nil)))))
     ,@body))

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

;;; mode commands

(ert-deftest agent-shell-to-go-test-bridge-yolo-command ()
  "!yolo sets bypassPermissions mode and notifies the transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!yolo"))
      (should
       (cl-some (lambda (text) (string-match-p "Bypass Permissions" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "bypassPermissions"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-bypass-command ()
  "!bypass is an alias for !yolo — sets bypassPermissions mode."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!bypass"))
      (should
       (cl-some (lambda (text) (string-match-p "Bypass Permissions" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "bypassPermissions"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-safe-command ()
  "!safe sets acceptEdits mode and notifies the transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!safe"))
      (should
       (cl-some (lambda (text) (string-match-p "Accept Edits" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "acceptEdits"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-accept-command ()
  "!accept is an alias for !safe — sets acceptEdits mode."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!accept"))
      (should
       (cl-some (lambda (text) (string-match-p "Accept Edits" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "acceptEdits"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-acceptedits-command ()
  "!acceptedits is an alias for !safe — sets acceptEdits mode."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!acceptedits"))
      (should
       (cl-some (lambda (text) (string-match-p "Accept Edits" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "acceptEdits"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-plan-command ()
  "!plan sets plan mode and notifies the transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!plan"))
      (should
       (cl-some (lambda (text) (string-match-p "Plan" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "plan"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-planmode-command ()
  "!planmode is an alias for !plan — sets plan mode."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--with-mode-stub
        (agent-shell-to-go-test-inbound-message
         tr channel-id thread-id "testuser" "!planmode"))
      (should
       (cl-some (lambda (text) (string-match-p "Plan" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      (should
       (equal "plan"
              (with-current-buffer buf
                (map-nested-elt agent-shell--state '(:session :mode-id))))))))

(ert-deftest agent-shell-to-go-test-bridge-mode-command ()
  "!mode returns the current session mode-id."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (with-current-buffer buf
        (let ((session (map-elt agent-shell--state :session)))
          (map-put! session :mode-id "bypassPermissions")
          (map-put! agent-shell--state :session session)))
      (agent-shell-to-go-test-inbound-message
       tr channel-id thread-id "testuser" "!mode")
      (should
       (cl-some (lambda (text) (string-match-p "bypassPermissions" text))
                (agent-shell-to-go-test-bridge--sent-texts tr))))))

(ert-deftest agent-shell-to-go-test-bridge-stop-command ()
  "!stop interrupts a long_running scenario and notifies the transport.
The long_running fixture sends 6 steps at 1.5 s each (~9 s total); the test
verifies the session becomes idle well before that deadline."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (let ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))
          (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf)))
      (agent-shell-to-go-test-bridge--send-prompt buf "test long_running")
      ;; Wait until mock-acp has started producing output
      (should
       (agent-shell-to-go-test-bridge--wait-until
        (lambda () (with-current-buffer buf (shell-maker-busy)))
        5))
      ;; !stop fires agent-shell-interrupt synchronously then sends the notice
      (agent-shell-to-go-test-inbound-message
       tr channel-id thread-id "testuser" "!stop")
      (should
       (cl-some (lambda (text) (string-match-p "Agent interrupted" text))
                (agent-shell-to-go-test-bridge--sent-texts tr)))
      ;; Session must become idle well before the uninterrupted 9 s window
      (should
       (agent-shell-to-go-test-bridge--wait-until
        (lambda () (with-current-buffer buf (not (shell-maker-busy))))
        8)))))

;;; init-client and error event handling

(ert-deftest agent-shell-to-go-test-bridge-on-init-client-failure ()
  "When init-client fires with :client nil in agent-shell state, failure notice is sent.
Exercises the failure branch of `agent-shell-to-go--on-init-client'."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (with-current-buffer buf
      (let ((saved-client (map-elt agent-shell--state :client)))
        (map-put! agent-shell--state :client nil)
        (unwind-protect
            (agent-shell-to-go--on-init-client nil)
          (map-put! agent-shell--state :client saved-client))))
    (should
     (cl-some
      (lambda (text) (string-match-p "Agent failed to start" text))
      (agent-shell-to-go-test-bridge--sent-texts tr)))))

(ert-deftest agent-shell-to-go-test-bridge-on-error-init-failure ()
  "When the ACP server raises an error on initialize, --on-error forwards it to the transport.
Also verifies --on-init-client does not fire a false \"failed to start\" notice,
since the client struct was created successfully before the RPC failed."
  (agent-shell-to-go-test-bridge--with-error-session tr buf "src/init_error_server.py"
                                                     nil
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (cl-some
         (lambda (text) (string-match-p "Agent error" text))
         (agent-shell-to-go-test-bridge--sent-texts tr)))))
    (should-not
     (cl-some
      (lambda (text) (string-match-p "Agent failed to start" text))
      (agent-shell-to-go-test-bridge--sent-texts tr)))))

(ert-deftest agent-shell-to-go-test-bridge-on-error-auth-failure ()
  "When the ACP server raises an auth-required error, --on-error forwards it to the transport."
  (agent-shell-to-go-test-bridge--with-error-session
      tr buf "src/auth_error_server.py"
      (lambda (config)
        (map-put! config :needs-authentication t)
        (map-put!
         config
         :authenticate-request-maker
         (lambda () (acp-make-authenticate-request :method-id "token" :method "token")))
        config)
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (cl-some
         (lambda (text) (string-match-p "Agent error" text))
         (agent-shell-to-go-test-bridge--sent-texts tr)))))))

(ert-deftest agent-shell-to-go-test-bridge-on-error-prompt-failure ()
  "When the agent raises an error in response to a prompt, --on-error forwards it to the transport."
  (agent-shell-to-go-test-bridge--with-session tr buf
    (agent-shell-to-go-test-bridge--send-prompt buf "test error")
    (should
     (agent-shell-to-go-test-bridge--wait-until
      (lambda ()
        (cl-some
         (lambda (text) (string-match-p "Agent error" text))
         (agent-shell-to-go-test-bridge--sent-texts tr)))))))

(provide 'agent-shell-to-go-test-bridge)
;;; agent-shell-to-go-test-bridge.el ends here
