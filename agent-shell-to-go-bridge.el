;;; agent-shell-to-go-bridge.el --- agent-shell integration for agent-shell-to-go -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Transport-agnostic bridge between agent-shell internals and the
;; agent-shell-to-go transport protocol.
;;
;; This file knows about agent-shell internals (via advice) but knows
;; NOTHING about Slack, mrkdwn, or any specific transport.  All sends
;; go through the transport protocol defined in agent-shell-to-go.el.

;;; Code:

(require 'agent-shell-to-go-core)

; Buffer-local state 

(defvar-local agent-shell-to-go--transport nil
  "The transport struct in use for this `agent-shell' buffer.")

(defvar-local agent-shell-to-go--channel-id nil
  "The remote channel id for this buffer.")

(defvar-local agent-shell-to-go--thread-id nil
  "The remote thread id for this buffer.")

(defvar-local agent-shell-to-go--current-agent-message nil
  "Accumulator for streaming agent message chunks.")

(defvar-local agent-shell-to-go--thread-title-updated nil
  "Non-nil after the thread header has been updated with a session title.")

(defvar-local agent-shell-to-go--turn-complete-subscription nil
  "Subscription token for the turn-complete event (session title fetch).")

(defvar-local agent-shell-to-go--ready-subscription nil
  "Subscription token for flushing agent message and sending ready signal.")

(defvar-local agent-shell-to-go--tool-call-update-subscription nil
  "Subscription token for tool-call-update events.")

(defvar-local agent-shell-to-go--init-client-subscription nil
  "Subscription token for init-client events (failure detection).")

(defvar-local agent-shell-to-go--init-finished-subscription nil
  "Subscription token for init-finished events (Ready signal for new sessions).")

(defvar-local agent-shell-to-go--error-subscription nil
  "Subscription token for error events.")

(defvar-local agent-shell-to-go--tool-calls nil
  "Alist tracking tool calls by toolCallId (id → t if sent).")

(defvar-local agent-shell-to-go--remote-queued nil
  "List of prompts injected from a remote transport, to suppress echo on submit.")

(defvar-local agent-shell-to-go--restarting nil
  "Non-nil when this buffer is being killed as part of a session restart.
Suppresses the '_Session ended_' message in bridge-disable.")

(defvar-local agent-shell-to-go--prev-permission-responder nil
  "Saved value of `agent-shell-permission-responder-function' before bridge-enable.")

; Global state 

(defvar agent-shell-to-go--active-buffers nil
  "List of `'agent-shell' buffers with active mirroring.")

(defvar agent-shell-to-go--pending-permissions nil
  "Alist of pending permission requests.
Key: (transport-name channel-id message-id)
Value: plist with :respond :options")

(defvar agent-shell-to-go--inherit-state nil
  "Plist of transport state for bridge-enable to inherit on a restarted session.
Keys: :transport :channel-id :thread-id.  Consumed (set to nil) on first use.")

; Buffer lookup 

(defun agent-shell-to-go--bridge-active-buffers ()
  "Return the list of active agent-shell-to-go buffers."
  agent-shell-to-go--active-buffers)

(defun agent-shell-to-go--find-buffer-for-transport-channel-thread
    (transport channel-id &optional thread-id)
  "Find an active buffer matching TRANSPORT, CHANNEL-ID and optionally THREAD-ID."
  (cl-find-if
   (lambda (buf)
     (and (buffer-live-p buf)
          (process-live-p (get-buffer-process buf))
          (eq transport (buffer-local-value 'agent-shell-to-go--transport buf))
          (equal channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf))
          (or (not thread-id)
              (equal
               thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf)))))
   agent-shell-to-go--active-buffers))

(defun agent-shell-to-go--bridge-thread-active-p (transport channel-id thread-id)
  "Return non-nil if THREAD-ID in CHANNEL-ID on TRANSPORT has a live buffer."
  (cl-some
   (lambda (buf)
     (and (buffer-live-p buf)
          (process-live-p (get-buffer-process buf))
          (eq transport (buffer-local-value 'agent-shell-to-go--transport buf))
          (equal channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf))
          (equal thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))))
   agent-shell-to-go--active-buffers))

; Diff extraction 

(defun agent-shell-to-go--parse-unified-diff (diff-string)
  "Parse unified DIFF-STRING into (old-text . new-text)."
  (let (old-lines
        new-lines
        in-hunk)
    (dolist (line (split-string diff-string "\n"))
      (cond
       ((string-match "^@@.*@@" line)
        (setq in-hunk t))
       ((and in-hunk (string-prefix-p " " line))
        (push (substring line 1) old-lines)
        (push (substring line 1) new-lines))
       ((and in-hunk (string-prefix-p "-" line))
        (push (substring line 1) old-lines))
       ((and in-hunk (string-prefix-p "+" line))
        (push (substring line 1) new-lines))))
    (cons
     (string-join (nreverse old-lines) "\n") (string-join (nreverse new-lines) "\n"))))

(defun agent-shell-to-go--extract-diff (update)
  "Extract (old-text . new-text) from tool call UPDATE, or nil."
  (let* ((content (map-elt update 'content))
         (raw-input (map-elt update 'rawInput))
         (content-list
          (cond
           ((vectorp content)
            (append content nil))
           ((and content (listp content) (not (map-elt content 'type)))
            content)
           (content
            (list content)))))
    (cond
     ((and content-list
           (seq-find (lambda (item) (equal (map-elt item 'type) "diff")) content-list))
      (let ((di
             (seq-find
              (lambda (item) (equal (map-elt item 'type) "diff")) content-list)))
        (cons (or (map-elt di 'oldText) "") (map-elt di 'newText))))
     ((and raw-input (map-elt raw-input 'new_str))
      (cons (or (map-elt raw-input 'old_str) "") (map-elt raw-input 'new_str)))
     ((and raw-input (map-elt raw-input 'diff))
      (agent-shell-to-go--parse-unified-diff (map-elt raw-input 'diff))))))

; helpers 

(defun agent-shell-to-go--send (text &optional options)
  "Send TEXT via the buffer-local transport.
OPTIONS is forwarded to `agent-shell-to-go-transport-send-text'."
  (when (and agent-shell-to-go--transport agent-shell-to-go--channel-id)
    (agent-shell-to-go-transport-send-text
     agent-shell-to-go--transport
     agent-shell-to-go--channel-id
     agent-shell-to-go--thread-id
     text
     options)))

(defun agent-shell-to-go--inject-message (text)
  "Inject TEXT into the current agent-shell buffer as if typed locally."
  (when (derived-mode-p 'agent-shell-mode)
    ;; Track every remote-originated prompt so --on-send-command can skip
    ;; mirroring it back (preventing echo), regardless of whether it is
    ;; submitted immediately or dequeued later by agent-shell.
    (push text agent-shell-to-go--remote-queued)
    (if (shell-maker-busy)
        (progn
          (agent-shell--enqueue-request :prompt text)
          (agent-shell-to-go--send
           (format "_Queued_: %s" (agent-shell-to-go--truncate-text text 100))))
      (agent-shell-insert :text text :submit t :no-focus t))))

(defun agent-shell-to-go--find-option-id (options action)
  "Find option id in OPTIONS matching canonical ACTION symbol.
OPTIONS is the enriched list from `agent-shell-permission-responder-function',
where each entry is a plist with :kind and :option-id."
  (let ((kinds
         (pcase action
           ('permission-allow '("allow" "accept" "allow_once"))
           ('permission-always '("always" "alwaysAllow" "allow_always"))
           ('permission-reject '("deny" "reject" "reject_once")))))
    (when-let* ((opt
                 (seq-find (lambda (opt) (member (map-elt opt :kind) kinds)) options)))
      (map-elt opt :option-id))))

(defun agent-shell-to-go--set-mode (buffer mode-id mode-name)
  "Set MODE-ID in BUFFER and notify the thread."
  (with-current-buffer buffer
    (let ((session-id (map-nested-elt agent-shell--state '(:session :id))))
      (if (not session-id)
          (agent-shell-to-go--send "No active session")
        (agent-shell--send-request
         :state agent-shell--state
         :client (map-elt agent-shell--state :client)
         :request (acp-make-session-set-mode-request :session-id session-id :mode-id mode-id)
         :buffer buffer
         :on-success
         (lambda (_)
           (let ((session (map-elt agent-shell--state :session)))
             (map-put! session :mode-id mode-id)
             (map-put! agent-shell--state :session session))
           (agent-shell--update-header-and-mode-line)
           (agent-shell-to-go--send (format "Mode: *%s*" mode-name)))
         :on-failure
         (lambda (err _)
           (agent-shell-to-go--send (format "Failed to set mode: %s" err))))))))

; !-command handler 

(defun agent-shell-to-go--handle-command (text buffer)
  "Handle !-command TEXT in BUFFER.  Return t if handled, nil otherwise."
  (let ((cmd (downcase (string-trim text))))
    (with-current-buffer buffer
      (pcase cmd
        ((or "!yolo" "!bypass")
         (agent-shell-to-go--set-mode buffer "bypassPermissions" "Bypass Permissions")
         t)
        ((or "!safe" "!accept" "!acceptedits")
         (agent-shell-to-go--set-mode buffer "acceptEdits" "Accept Edits")
         t)
        ((or "!plan" "!planmode")
         (agent-shell-to-go--set-mode buffer "plan" "Plan")
         t)
        ("!mode"
         (let ((mode-id (map-nested-elt agent-shell--state '(:session :mode-id))))
           (agent-shell-to-go--send (format "Mode: *%s*" (or mode-id "unknown"))))
         t)
        ("!help"
         (agent-shell-to-go--send
          (concat
           "*Commands:*\n"
           "`!yolo` — bypass permissions\n"
           "`!safe` — accept edits mode\n"
           "`!plan` — plan mode\n"
           "`!mode` — show current mode\n"
           "`!stop` — interrupt agent\n"
           "`!restart` — kill and restart agent\n"
           "`!queue` — show queued messages\n"
           "`!clearqueue` — clear queued messages\n"
           ;; "`!latest` — jump to bottom of thread\n"
           "`!info` — show session info"))
         t)
        ("!queue"
         (let ((pending (map-elt agent-shell--state :pending-requests)))
           (if (seq-empty-p pending)
               (agent-shell-to-go--send "No pending requests")
             (agent-shell-to-go--send
              (format "*Pending (%d):*\n%s"
                      (length pending)
                      (mapconcat
                       (lambda (r)
                         (format "- %s" (agent-shell-to-go--truncate-text r 80)))
                       pending
                       "\n")))))
         t)
        ("!clearqueue"
         (let ((count (length (map-elt agent-shell--state :pending-requests))))
           (map-put! agent-shell--state :pending-requests nil)
           (agent-shell-to-go--send
            (format "Cleared %d request%s"
                    count
                    (if (= count 1)
                        ""
                      "s"))))
         t)
        ("!info"
         (let* ((state agent-shell--state)
                (session-id (map-nested-elt state '(:session :id)))
                (mode-id (map-nested-elt state '(:session :mode-id)))
                (truncated-count
                 (let ((dir
                        (expand-file-name (format "truncated/%s/"
                                                  agent-shell-to-go--channel-id)
                                          (agent-shell-to-go-transport-storage-root
                                           agent-shell-to-go--transport))))
                   (if (file-directory-p dir)
                       (length (directory-files dir nil "\\.txt$"))
                     0))))
           (agent-shell-to-go--send
            (format
             "*Debug*\nBuffer: `%s`\nThread: `%s`\nChannel: `%s`\nSession: `%s`\nMode: `%s`\nTruncated: %d"
             (buffer-name buffer)
             agent-shell-to-go--thread-id
             agent-shell-to-go--channel-id
             (or session-id "none")
             (or mode-id "default")
             truncated-count)))
         t)
        ("!stop"
         (condition-case err
             (progn
               (agent-shell-interrupt t)
               (agent-shell-to-go--send "Agent interrupted"))
           (error
            (agent-shell-to-go--send (format "Stop failed: %s" err))))
         t)
        ("!restart"
         (condition-case err
             (let* ((session-id (map-nested-elt agent-shell--state '(:session :id))))
               (unless session-id
                 (error "No active session to restart"))
               (setq agent-shell-to-go--inherit-state
                     (list
                      :transport agent-shell-to-go--transport
                      :channel-id agent-shell-to-go--channel-id
                      :thread-id agent-shell-to-go--thread-id))
               (setq agent-shell-to-go--restarting t)
               (agent-shell-to-go--send "Restarting agent…")
               (ignore-errors
                 (agent-shell-interrupt t))
               (condition-case restart-err
                   (when-let* ((win (agent-shell-restart :session-id session-id))
                               (new-buf (and (windowp win) (window-buffer win)))
                               (_ (buffer-live-p new-buf))
                               (_
                                (with-current-buffer new-buf
                                  (derived-mode-p 'agent-shell-mode))))
                     (with-current-buffer new-buf
                       ;; Strictly speaking, we don't need this since
                       ;; agent-shell-to-go-mode is likely to be already hooked to
                       ;; agent-shell-mode-hook if we are here. But there is no harm
                       ;; to do it one more time.
                       (agent-shell-to-go-mode 1)))
                 (error
                  (setq agent-shell-to-go--inherit-state nil)
                  (agent-shell-to-go--debug "restart failed: %s" restart-err))))
           (error
            (setq agent-shell-to-go--inherit-state nil)
            (agent-shell-to-go--send (format "Restart failed: %s" err))))
         t)
        (_ nil)))))

; Inbound hook handlers (registered on message/reaction/slash hooks) 

(cl-defun agent-shell-to-go--bridge-on-message
    (&key transport channel-id thread-id text &allow-other-keys)
  "Handle an inbound message from a transport."
  (when-let* ((buffer
               (and thread-id
                    (agent-shell-to-go--find-buffer-for-transport-channel-thread
                     transport channel-id
                     thread-id))))
    (with-current-buffer buffer
      (if (string-prefix-p "!" text)
          (agent-shell-to-go--handle-command text buffer)
        (agent-shell-to-go--inject-message text)))))

(cl-defun agent-shell-to-go--bridge-on-reaction
    (&key transport channel-id msg-id action added-p &allow-other-keys)
  "Handle permission reactions from a transport.
Presentation reactions are handled by the main dispatcher registered first."
  (when (and added-p
             (memq action '(permission-allow permission-always permission-reject)))
    (let* ((key (list (agent-shell-to-go-transport-name transport) channel-id msg-id))
           (pending (assoc key agent-shell-to-go--pending-permissions #'equal)))
      (when pending
        (let* ((info (cdr pending))
               (respond (map-elt info :respond))
               (options (map-elt info :options))
               (option-id (agent-shell-to-go--find-option-id options action)))
          (when option-id
            (funcall respond option-id)
            (setq agent-shell-to-go--pending-permissions
                  (cl-remove key agent-shell-to-go--pending-permissions
                             :key #'car
                             :test #'equal))))))))

(cl-defun agent-shell-to-go--bridge-on-slash-command
    (&key transport command args channel-id &allow-other-keys)
  "Handle an inbound slash command from a transport."
  (let* ((typed-args args)
         (reply
          (lambda (text)
            (agent-shell-to-go-transport-send-text transport channel-id nil text))))
    (pcase command
      ("/new-agent" (let ((folder
              (expand-file-name
               (or (map-elt typed-args :folder) agent-shell-to-go-default-folder))))
         (agent-shell-to-go--start-agent-in-folder folder transport channel-id)))
      ("/new-project" (let ((project-name (map-elt typed-args :project-name)))
         (if (not project-name)
             (funcall reply "Usage: `/new-project <project-name>`")
           (let ((project-dir
                  (expand-file-name project-name agent-shell-to-go-projects-directory)))
             (if (file-exists-p project-dir)
                 (funcall reply (format "Project already exists: `%s`" project-dir))
               (funcall reply (format "Creating project: `%s`" project-dir))
               (let ((start-fn
                      (lambda (final-dir)
                        (funcall reply "Starting Claude Code…")
                        (agent-shell-to-go--start-agent-in-folder
                         final-dir transport channel-id))))
                 (if agent-shell-to-go-new-project-function
                     (funcall agent-shell-to-go-new-project-function
                              project-name
                              (expand-file-name agent-shell-to-go-projects-directory)
                              start-fn)
                   (make-directory project-dir t)
                   (funcall start-fn project-dir))))))))
      ("/projects" (let ((projects (agent-shell-to-go--get-open-projects)))
         (if projects
             (progn
               (funcall reply "*Open Projects:*")
               (dolist (p projects)
                 (funcall reply p)))
           (funcall reply "No open projects found")))))))

(defun agent-shell-to-go--start-agent-in-folder (folder transport channel-id)
  "Start an agent in FOLDER, notify CHANNEL-ID via TRANSPORT.
Enables `agent-shell-to-go-mode' on the new buffer so it is immediately
accessible from remote via TRANSPORT and CHANNEL-ID."
  (agent-shell-to-go--debug "starting agent in %s" folder)
  (if (file-directory-p folder)
      (let ((default-directory folder))
        (save-window-excursion
          (condition-case err
              (let ((bufs-before (agent-shell-buffers)))
                (setq agent-shell-to-go--inherit-state
                      (list :transport transport :channel-id channel-id))
                (funcall agent-shell-to-go-start-agent-function)
                (when-let* ((new-buf
                             (cl-find-if (lambda (b) (not (memq b bufs-before)))
                                         (agent-shell-buffers))))
                  (with-current-buffer new-buf
                    (agent-shell-to-go-mode 1)))
                (agent-shell-to-go-transport-send-text
                 transport channel-id nil (format "Agent started in `%s`" folder)))
            (error
             (setq agent-shell-to-go--inherit-state nil)
             (agent-shell-to-go--debug "error starting agent: %s" err)))))
    (agent-shell-to-go-transport-send-text
     transport channel-id nil (format "Folder does not exist: `%s`" folder))))

(defun agent-shell-to-go--get-open-projects ()
  "Return list of currently open project paths."
  (delete-dups
   (delq
    nil
    (cond
     ((fboundp 'projectile-open-projects)
      (projectile-open-projects))
     ((fboundp 'project-known-project-roots)
      (project-known-project-roots))
     (t
      (mapcar
       (lambda (buf)
         (when-let* ((f (buffer-file-name buf)))
           (file-name-directory f)))
       (buffer-list)))))))

; agent shell subscriptions 

;; TODO: use the new session-title-changed event
;; This needs a more recent `agent-shell'
(defun agent-shell-to-go--fetch-session-title (_event)
  "Fetch session title via ACP and update the thread header."
  (when (and (not agent-shell-to-go--thread-title-updated)
             agent-shell-to-go--thread-id
             (boundp 'agent-shell--state)
             agent-shell--state)
    (let* ((session-id (map-nested-elt agent-shell--state '(:session :id)))
           (client (map-elt agent-shell--state :client))
           (cwd (agent-shell--resolve-path default-directory)))
      (when (and session-id client cwd)
        (acp-send-request
         :client client
         :request (acp-make-session-list-request :cwd cwd)
         :buffer (current-buffer)
         :on-success
         (lambda (resp)
           (let* ((sessions (append (or (map-elt resp 'sessions) '()) nil))
                  (current
                   (seq-find
                    (lambda (s) (equal (map-elt s 'sessionId) session-id)) sessions))
                  (title (and current (map-elt current 'title))))
             (when (and title (not (string-empty-p title)))
               (agent-shell-to-go-transport-update-thread-header
                agent-shell-to-go--transport
                agent-shell-to-go--channel-id
                agent-shell-to-go--thread-id
                title)
               (setq agent-shell-to-go--thread-title-updated t)
               (when agent-shell-to-go--turn-complete-subscription
                 (agent-shell-unsubscribe
                  :subscription agent-shell-to-go--turn-complete-subscription)
                 (setq agent-shell-to-go--turn-complete-subscription nil)))))
         :on-failure
         (lambda (_err _raw)
           (agent-shell-to-go--debug "failed to fetch session title")))))))

(defun agent-shell-to-go--on-turn-complete (_event)
  "Flush buffered agent message and send ready signal."
  (when agent-shell-to-go-mode
    (when (and agent-shell-to-go--current-agent-message
               (> (length agent-shell-to-go--current-agent-message) 0))
      (agent-shell-to-go--send
       (agent-shell-to-go-transport-format-agent-message
        agent-shell-to-go--transport agent-shell-to-go--current-agent-message))
      (setq agent-shell-to-go--current-agent-message nil))
    (when agent-shell-to-go--thread-id
      (agent-shell-to-go--send "_Ready for input_"))))

(defun agent-shell-to-go--permission-responder (permission)
  "Handle a PERMISSION request by notifying the remote transport.
Set as `agent-shell-permission-responder-function' when mirroring is on.
Falls back to `agent-shell-to-go--prev-permission-responder' when transport
is not ready.  Returns t to suppress the Emacs permission UI."
  (if (and agent-shell-to-go-mode
           agent-shell-to-go--transport
           agent-shell-to-go--thread-id)
      (let*
          ((tool-call (map-elt permission :tool-call))
           (options (map-elt permission :options))
           (respond (map-elt permission :respond))
           (title (or (map-elt tool-call :title) "Unknown action"))
           (msg-id
            (condition-case err
                (agent-shell-to-go-transport-send-text
                 agent-shell-to-go--transport
                 agent-shell-to-go--channel-id
                 agent-shell-to-go--thread-id
                 (format
                  "*Permission Required*\n`%s`\n\nReact to approve, deny, or always allow."
                  title))
              (error
               (agent-shell-to-go--debug "permission notify error: %s" err)
               nil))))
        (if msg-id
            (progn
              (push (cons
                     (list
                      (agent-shell-to-go-transport-name
                       agent-shell-to-go--transport)
                      agent-shell-to-go--channel-id msg-id)
                     (list :respond respond :options options))
                    agent-shell-to-go--pending-permissions)
              t)
          (when (functionp agent-shell-to-go--prev-permission-responder)
            (funcall agent-shell-to-go--prev-permission-responder permission))))
    (when (functionp agent-shell-to-go--prev-permission-responder)
      (funcall agent-shell-to-go--prev-permission-responder permission))))

(defun agent-shell-to-go--on-send-command (orig-fn &rest args)
  "Advice around `agent-shell--send-command'.  Mirror user prompts."
  (let ((prompt (map-elt args :prompt)))
    (if (and prompt (member prompt agent-shell-to-go--remote-queued))
        (setq agent-shell-to-go--remote-queued
              (delete prompt agent-shell-to-go--remote-queued))
      (when (and agent-shell-to-go-mode agent-shell-to-go--thread-id prompt)
        (agent-shell-to-go--send
         (agent-shell-to-go-transport-format-user-message
          agent-shell-to-go--transport prompt))
        (agent-shell-to-go--send "Processing..."))))
  (setq agent-shell-to-go--current-agent-message nil)
  (apply orig-fn args))

(defun agent-shell-to-go--on-init-client (_event)
  "Handle init-client event.  Send failure notice if client was not created."
  (when (and agent-shell-to-go-mode
             agent-shell-to-go--thread-id
             (not (map-elt agent-shell--state :client)))
    (agent-shell-to-go--send "*Agent failed to start* — check API key / OAuth token")))

(defun agent-shell-to-go--on-init-finished (_event)
  "Handle init-finished event.  Notify remote that the session is connected."
  (when (and agent-shell-to-go-mode agent-shell-to-go--thread-id)
    (agent-shell-to-go--send "_Connected_")))

(defun agent-shell-to-go--on-error (event)
  "Handle error event.  Forward the error message to the remote transport."
  (when (and agent-shell-to-go-mode agent-shell-to-go--thread-id)
    (let* ((data (map-elt event :data))
           (code (map-elt data :code))
           (message (map-elt data :message)))
      (agent-shell-to-go--send (format "*Agent error* — %s: %s" code message)))))

;; there is no event available on notification so we use this
(defun agent-shell-to-go--on-notification (orig-fn &rest args)
  "Advice around `agent-shell--on-notification'.  Accumulate agent message chunks."
  (let* ((state (map-elt args :state))
         (buffer (map-elt state :buffer)))
    (when (and buffer
               (buffer-live-p buffer)
               (buffer-local-value 'agent-shell-to-go-mode buffer))
      (let* ((notification (map-elt args :acp-notification))
             (params (map-elt notification 'params))
             (update (map-elt params 'update))
             (thread-id (buffer-local-value 'agent-shell-to-go--thread-id buffer)))
        (when (and thread-id
                   (equal (map-elt update 'sessionUpdate) "agent_message_chunk"))
          (let ((text (map-elt (map-elt update 'content) 'text)))
            (with-current-buffer buffer
              (setq agent-shell-to-go--current-agent-message
                    (concat agent-shell-to-go--current-agent-message text))))))))
  (apply orig-fn args))

(defun agent-shell-to-go--bridge-on-tool-call-update (event)
  "Handle a tool-call-update EVENT from agent-shell.
Called via `agent-shell-subscribe-to' with the shell buffer current."
  (when (and agent-shell-to-go-mode agent-shell-to-go--thread-id)
    (let* ((data (map-elt event :data))
           (tool-call-id (map-elt data :tool-call-id))
           (tool-call (map-elt data :tool-call))
           (status (map-elt tool-call :status))
           (raw-input (map-elt tool-call :raw-input))
           (content (map-elt tool-call :content))
           (pseudo-update `((rawInput . ,raw-input) (content . ,content))))
      (if (member status '("completed" "failed"))
          (let* ((content-text
                  (and content
                       (mapconcat (lambda (item)
                                    (or (map-elt (map-elt item 'content) 'text)
                                        (map-elt item 'text)
                                        ""))
                                  (if (vectorp content)
                                      (append content nil)
                                    (if (listp content)
                                        content
                                      nil))
                                  "\n")))
                 (output content-text)
                 (diff
                  (condition-case nil
                      (agent-shell-to-go--extract-diff pseudo-update)
                    (error
                     nil)))
                 (diff-text
                  (and diff
                       (condition-case nil
                           (agent-shell-to-go-transport-format-diff
                            agent-shell-to-go--transport (car diff) (cdr diff))
                         (error
                          nil))))
                 (icon
                  (if (equal status "completed")
                      "[ok]"
                    "[fail]")))
            (cond
             ((and diff-text (> (length diff-text) 0))
              (let ((full (format "%s\n%s" icon diff-text)))
                (if agent-shell-to-go-show-tool-output
                    (agent-shell-to-go--send full '(:truncate t))
                  (let ((msg-id (agent-shell-to-go--send icon)))
                    (when msg-id
                      (agent-shell-to-go--save-truncated-message
                       agent-shell-to-go--transport
                       agent-shell-to-go--channel-id
                       msg-id
                       full
                       icon))))))
             ((and output (stringp output) (> (length output) 0))
              (let ((full
                     (agent-shell-to-go-transport-format-tool-call-result
                      agent-shell-to-go--transport "output" status output)))
                (if agent-shell-to-go-show-tool-output
                    (agent-shell-to-go--send full '(:truncate t))
                  (let ((msg-id (agent-shell-to-go--send icon)))
                    (when msg-id
                      (agent-shell-to-go--save-truncated-message
                       agent-shell-to-go--transport
                       agent-shell-to-go--channel-id
                       msg-id
                       full
                       icon))))))
             (t
              (agent-shell-to-go--send icon))))
        ;; Tool call started — flush any buffered agent text first, then notify
        (let* ((title (map-elt tool-call :title))
               (command (map-elt raw-input 'command))
               (file-path (map-elt raw-input 'file_path))
               (query (map-elt raw-input 'query))
               (url (map-elt raw-input 'url))
               (specific (or command file-path query url))
               (already-sent
                (and tool-call-id
                     (map-elt agent-shell-to-go--tool-calls tool-call-id))))
          (when (and (not already-sent) (or specific title))
            (when (and agent-shell-to-go--current-agent-message
                       (> (length agent-shell-to-go--current-agent-message) 0))
              (agent-shell-to-go--send
               (agent-shell-to-go-transport-format-agent-message
                agent-shell-to-go--transport agent-shell-to-go--current-agent-message))
              (setq agent-shell-to-go--current-agent-message nil))
            (setf (alist-get tool-call-id agent-shell-to-go--tool-calls) t)
            (let* ((title-has-specific
                    (and title specific (string-match-p (regexp-quote specific) title)))
                   (display
                    (cond
                     (command
                      command)
                     (title-has-specific
                      title)
                     ((and file-path title)
                      (format "%s: %s" title file-path))
                     ((and query title)
                      (format "%s: %s" title query))
                     ((and url title)
                      (format "%s: %s" title url))
                     (specific
                      specific)
                     (t
                      title)))
                   (diff
                    (condition-case nil
                        (agent-shell-to-go--extract-diff pseudo-update)
                      (error
                       nil)))
                   (diff-text
                    (and diff
                         (condition-case nil
                             (agent-shell-to-go-transport-format-diff
                              agent-shell-to-go--transport (car diff) (cdr diff))
                           (error
                            nil)))))
              (condition-case err
                  (if (and diff-text (> (length diff-text) 0))
                      (let* ((start-text
                              (agent-shell-to-go-transport-format-tool-call-start
                               agent-shell-to-go--transport display))
                             (full (format "%s\n%s" start-text diff-text)))
                        (if agent-shell-to-go-show-tool-output
                            (agent-shell-to-go--send full '(:truncate t))
                          (let ((msg-id (agent-shell-to-go--send start-text)))
                            (when msg-id
                              (agent-shell-to-go--save-truncated-message
                               agent-shell-to-go--transport
                               agent-shell-to-go--channel-id
                               msg-id
                               full
                               start-text)))))
                    (agent-shell-to-go--send
                     (agent-shell-to-go-transport-format-tool-call-start
                      agent-shell-to-go--transport display)
                     '(:truncate t)))
                (error
                 (agent-shell-to-go--debug "tool_call send error: %s" err))))))))))


; Hook registration 

(add-hook 'agent-shell-to-go-message-hook #'agent-shell-to-go--bridge-on-message)
(add-hook 'agent-shell-to-go-reaction-hook #'agent-shell-to-go--bridge-on-reaction)
(add-hook
 'agent-shell-to-go-slash-command-hook #'agent-shell-to-go--bridge-on-slash-command)

; Enable / disable 

(defun agent-shell-to-go--bridge-enable ()
  "Enable transport mirroring for this buffer."
  ;; `agent-shell-to-go--inherit-state' is set by !restart to carry the old
  ;; session's transport/channel/thread over to the new buffer.  Consumed
  ;; here (set to nil) so it's a one-shot handoff and can't leak elsewhere.
  (let* ((inherited agent-shell-to-go--inherit-state)
         (_ (setq agent-shell-to-go--inherit-state nil))
         (transport
          (or (map-elt inherited :transport) (agent-shell-to-go--get-transport)))
         (project-path (agent-shell-to-go--get-project-path)))
    ;; Load credentials / connect if needed
    (unless (agent-shell-to-go-transport-connected-p transport)
      (agent-shell-to-go-transport-connect transport))
    ;; Resolve channel (reuse inherited or create fresh)
    (setq agent-shell-to-go--transport transport)
    (setq agent-shell-to-go--channel-id
          (or (map-elt inherited :channel-id)
              (agent-shell-to-go-transport-ensure-project-channel
               transport project-path)))
    ;; Start thread (reuse inherited or create fresh)
    (setq agent-shell-to-go--thread-id
          (or (map-elt inherited :thread-id)
              (agent-shell-to-go-transport-start-thread
               transport agent-shell-to-go--channel-id (buffer-name))))
    ;; Track buffer
    (add-to-list 'agent-shell-to-go--active-buffers (current-buffer))

    ;; Save and install permission responder
    (setq agent-shell-to-go--prev-permission-responder
          agent-shell-permission-responder-function)
    (setq-local agent-shell-permission-responder-function
                #'agent-shell-to-go--permission-responder)
    ;; Add advice
    (advice-add 'agent-shell--send-command :around #'agent-shell-to-go--on-send-command)
    (advice-add
     'agent-shell--on-notification
     :around #'agent-shell-to-go--on-notification)
    ;; Subscribe to init-client to detect client creation failure
    (setq agent-shell-to-go--init-client-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'init-client
           :on-event #'agent-shell-to-go--on-init-client))
    ;; Subscribe to init-finished to send Ready when a new session connects.
    ;; init-client fires synchronously inside agent-shell-start so it is too
    ;; early; init-finished fires async after the ACP handshake completes.
    (setq agent-shell-to-go--init-finished-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'init-finished
           :on-event #'agent-shell-to-go--on-init-finished))
    ;; Subscribe to error events and forward to remote transport
    (setq agent-shell-to-go--error-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'error
           :on-event #'agent-shell-to-go--on-error))
    ;; Subscribe to turn-complete for session title
    (setq agent-shell-to-go--turn-complete-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'turn-complete
           :on-event #'agent-shell-to-go--fetch-session-title))
    ;; Subscribe to turn-complete for flush + ready signal
    (setq agent-shell-to-go--ready-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'turn-complete
           :on-event #'agent-shell-to-go--on-turn-complete))
    ;; Subscribe to tool-call-update for tool call mirroring
    (setq agent-shell-to-go--tool-call-update-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'tool-call-update
           :on-event #'agent-shell-to-go--bridge-on-tool-call-update))
    ;; Kill hook
    (add-hook 'kill-buffer-hook #'agent-shell-to-go--on-buffer-kill nil t)
    (agent-shell-to-go--debug
     "bridge enabled, thread=%s" agent-shell-to-go--thread-id)))

(defun agent-shell-to-go--on-buffer-kill ()
  "Hook to run when an agent-shell buffer is killed."
  (when agent-shell-to-go-mode
    (agent-shell-to-go--bridge-disable)))

(defun agent-shell-to-go--bridge-disable ()
  "Disable transport mirroring for this buffer."
  (remove-hook 'kill-buffer-hook #'agent-shell-to-go--on-buffer-kill t)
  (dolist (sub
           (list
            agent-shell-to-go--init-client-subscription
            agent-shell-to-go--init-finished-subscription
            agent-shell-to-go--error-subscription
            agent-shell-to-go--turn-complete-subscription
            agent-shell-to-go--ready-subscription
            agent-shell-to-go--tool-call-update-subscription))
    (when sub
      (ignore-errors
        (agent-shell-unsubscribe :subscription sub))))
  (setq
   agent-shell-to-go--init-client-subscription nil
   agent-shell-to-go--init-finished-subscription nil
   agent-shell-to-go--error-subscription nil
   agent-shell-to-go--turn-complete-subscription nil
   agent-shell-to-go--ready-subscription nil
   agent-shell-to-go--tool-call-update-subscription nil)
  (when (and agent-shell-to-go--thread-id
             agent-shell-to-go--transport
             (not agent-shell-to-go--restarting))
    (when (and agent-shell-to-go-upload-transcript-on-end
               (bound-and-true-p agent-shell--transcript-file)
               (file-exists-p agent-shell--transcript-file))
      (agent-shell-to-go-transport-upload-file
       agent-shell-to-go--transport
       agent-shell-to-go--channel-id
       agent-shell-to-go--thread-id
       agent-shell--transcript-file
       "Session transcript"))
    (agent-shell-to-go--send "_Session ended_"))
  ;; Restore permission responder
  (setq-local agent-shell-permission-responder-function
              agent-shell-to-go--prev-permission-responder)
  (setq agent-shell-to-go--active-buffers
        (delete (current-buffer) agent-shell-to-go--active-buffers))
  (unless agent-shell-to-go--active-buffers
    (advice-remove 'agent-shell--send-command #'agent-shell-to-go--on-send-command)
    (advice-remove 'agent-shell--on-notification #'agent-shell-to-go--on-notification))
  (agent-shell-to-go--debug "bridge disabled"))

(defun agent-shell-to-go--bridge-reconnect-buffer (&optional buffer)
  "Reconnect BUFFER (or current) to its transport with a fresh thread."
  (let ((buf (or buffer (current-buffer))))
    (unless (buffer-live-p buf)
      (user-error "Buffer is not live"))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-shell-mode)
        (user-error "Not an agent-shell buffer"))
      (let* ((transport
              (or agent-shell-to-go--transport (agent-shell-to-go--get-transport)))
             (project-path (agent-shell-to-go--get-project-path)))
        (unless (agent-shell-to-go-transport-connected-p transport)
          (agent-shell-to-go-transport-connect transport))
        (setq agent-shell-to-go--transport transport)
        (setq agent-shell-to-go--channel-id
              (agent-shell-to-go-transport-ensure-project-channel
               transport project-path))
        (setq agent-shell-to-go--thread-id
              (agent-shell-to-go-transport-start-thread
               transport agent-shell-to-go--channel-id (buffer-name)))
        (unless (memq buf agent-shell-to-go--active-buffers)
          (add-to-list 'agent-shell-to-go--active-buffers buf))
        (setq-local agent-shell-permission-responder-function
                    #'agent-shell-to-go--permission-responder)
        (advice-add
         'agent-shell--send-command
         :around #'agent-shell-to-go--on-send-command)
        (advice-add
         'agent-shell--on-notification
         :around #'agent-shell-to-go--on-notification)
        ;; Refresh subscriptions for the new thread
        (dolist (sub
                 (list
                  agent-shell-to-go--turn-complete-subscription
                  agent-shell-to-go--ready-subscription
                  agent-shell-to-go--tool-call-update-subscription))
          (when sub
            (ignore-errors
              (agent-shell-unsubscribe :subscription sub))))
        (setq agent-shell-to-go--turn-complete-subscription
              (agent-shell-subscribe-to
               :shell-buffer buf
               :event 'turn-complete
               :on-event
               (lambda (_event) (agent-shell-to-go--fetch-session-title))))
        (setq agent-shell-to-go--ready-subscription
              (agent-shell-subscribe-to
               :shell-buffer buf
               :event 'turn-complete
               :on-event #'agent-shell-to-go--on-turn-complete))
        (setq agent-shell-to-go--tool-call-update-subscription
              (agent-shell-subscribe-to
               :shell-buffer buf
               :event 'tool-call-update
               :on-event #'agent-shell-to-go--bridge-on-tool-call-update))
        (add-hook 'kill-buffer-hook #'agent-shell-to-go--on-buffer-kill nil t)
        (unless agent-shell-to-go-mode
          (setq agent-shell-to-go-mode t))
        (agent-shell-to-go--debug "reconnected %s (new thread)" (buffer-name buf))))))

(defun agent-shell-to-go--bridge-buffer-connected-p (&optional buffer)
  "Return non-nil if BUFFER has a valid transport connection."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'agent-shell-to-go--thread-id buf)
         (buffer-local-value 'agent-shell-to-go--channel-id buf)
         (memq buf agent-shell-to-go--active-buffers))))


(provide 'agent-shell-to-go-bridge)
;;; agent-shell-to-go-bridge.el ends here
