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
  "Subscription token for the turn-complete event.")

(defvar-local agent-shell-to-go--file-watcher nil
  "The fswatch process watching the project directory.")

(defvar-local agent-shell-to-go--uploaded-images nil
  "Hash table of image paths already uploaded (path → mtime float).")

(defvar-local agent-shell-to-go--upload-timestamps nil
  "List of recent upload timestamps for rate limiting.")

(defvar-local agent-shell-to-go--mentioned-files nil
  "Hash table of file paths mentioned in recent tool calls (path → time).")

(defvar-local agent-shell-to-go--tool-calls nil
  "Hash table tracking tool calls by toolCallId (id → t if sent).")

(defvar-local agent-shell-to-go--from-remote nil
  "Non-nil when the current input originated from a remote transport.")

; Global state 

(defvar agent-shell-to-go--active-buffers nil
  "List of `'agent-shell' buffers with active mirroring.")

(defvar agent-shell-to-go--pending-permissions nil
  "Alist of pending permission requests.
Key: (transport-name channel-id message-id)
Value: plist with :request-id :buffer :options :command")

; Constants 

(defconst agent-shell-to-go--image-extensions
  '("png" "jpg" "jpeg" "gif" "webp" "bmp" "svg")
  "File extensions recognized as images.")

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
          (eq transport (buffer-local-value 'agent-shell-to-go--transport buf))
          (equal channel-id (buffer-local-value 'agent-shell-to-go--channel-id buf))
          (or (not thread-id)
              (equal
               thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf)))))
   agent-shell-to-go--active-buffers))

(defun agent-shell-to-go--bridge-thread-active-p (transport channel thread-id)
  "Return non-nil if THREAD-ID in CHANNEL on TRANSPORT has a live buffer."
  (cl-some
   (lambda (buf)
     (and (buffer-live-p buf)
          (eq transport (buffer-local-value 'agent-shell-to-go--transport buf))
          (equal channel (buffer-local-value 'agent-shell-to-go--channel-id buf))
          (equal thread-id (buffer-local-value 'agent-shell-to-go--thread-id buf))))
   agent-shell-to-go--active-buffers))

; Rate limiting 

(defun agent-shell-to-go--check-upload-rate-limit ()
  "Return t if an upload is allowed under the current rate limit."
  (if (not agent-shell-to-go-image-upload-rate-limit)
      t
    (let* ((now (float-time))
           (window (- now agent-shell-to-go-image-upload-rate-window)))
      (setq agent-shell-to-go--upload-timestamps
            (cl-remove-if
             (lambda (ts) (< ts window)) agent-shell-to-go--upload-timestamps))
      (< (length agent-shell-to-go--upload-timestamps)
         agent-shell-to-go-image-upload-rate-limit))))

(defun agent-shell-to-go--record-upload ()
  "Record an upload timestamp for rate limiting."
  (push (float-time) agent-shell-to-go--upload-timestamps))

; Mentioned-file tracking 


(defun agent-shell-to-go--record-mentioned-file (file-path)
  "Record FILE-PATH as recently mentioned by this buffer's agent."
  (unless agent-shell-to-go--mentioned-files
    (setq agent-shell-to-go--mentioned-files (make-hash-table :test 'equal)))
  (puthash file-path (float-time) agent-shell-to-go--mentioned-files))

(defun agent-shell-to-go--file-was-mentioned-p (file-path)
  "Return non-nil if FILE-PATH was recently mentioned by this buffer's agent."
  (when agent-shell-to-go--mentioned-files
    (let ((ts (gethash file-path agent-shell-to-go--mentioned-files)))
      (and ts (< (- (float-time) ts) agent-shell-to-go-mentioned-file-ttl)))))

; File path extraction from tool call updates 

(defun agent-shell-to-go--extract-file-paths-from-update (update)
  "Extract file paths from a tool call UPDATE alist."
  (let ((paths nil)
        (raw-input (alist-get 'rawInput update))
        (content (alist-get 'content update)))
    (when-let ((fp (alist-get 'file_path raw-input)))
      (push fp paths))
    (when-let ((p (alist-get 'path raw-input)))
      (push p paths))
    (when content
      (let ((items
             (cond
              ((vectorp content)
               (append content nil))
              ((listp content)
               content))))
        (dolist (item items)
          (when-let ((p (alist-get 'path item)))
            (push p paths)))))
    paths))

; Image file detection 

(defun agent-shell-to-go--image-file-p (path)
  "Return non-nil if PATH has an image file extension."
  (when (and path (stringp path))
    (member
     (downcase (or (file-name-extension path) ""))
     agent-shell-to-go--image-extensions)))

; File watcher 

(defun agent-shell-to-go--handle-fswatch-output (buffer output)
  "Handle fswatch OUTPUT, uploading new images for BUFFER."
  (when (buffer-live-p buffer)
    (dolist (file-path (split-string output "\n" t))
      (when (and (agent-shell-to-go--image-file-p file-path)
                 (file-exists-p file-path)
                 (> (file-attribute-size (file-attributes file-path)) 0))
        (with-current-buffer buffer
          (when (agent-shell-to-go--file-was-mentioned-p file-path)
            (unless agent-shell-to-go--uploaded-images
              (setq agent-shell-to-go--uploaded-images (make-hash-table :test 'equal)))
            (let* ((mtime
                    (float-time
                     (file-attribute-modification-time (file-attributes file-path))))
                   (prev (gethash file-path agent-shell-to-go--uploaded-images)))
              (when (or (not prev) (> mtime prev))
                (if (not (agent-shell-to-go--check-upload-rate-limit))
                    (agent-shell-to-go--debug "rate limit, skipping: %s" file-path)
                  (puthash file-path mtime agent-shell-to-go--uploaded-images)
                  (run-at-time
                   0.5 nil
                   (lambda ()
                     (when (and (buffer-live-p buffer) (file-exists-p file-path))
                       (with-current-buffer buffer
                         (agent-shell-to-go--debug "uploading: %s" file-path)
                         (agent-shell-to-go--record-upload)
                         (agent-shell-to-go-transport-upload-file
                          agent-shell-to-go--transport
                          agent-shell-to-go--channel-id
                          agent-shell-to-go--thread-id
                          file-path
                          (format ":frame_with_picture: `%s`"
                                  (file-name-nondirectory file-path))))))))))))))))

(defun agent-shell-to-go--start-file-watcher ()
  "Start fswatch on the project directory for this buffer."
  (agent-shell-to-go--stop-file-watcher)
  (let ((project-dir (agent-shell-to-go--get-project-path))
        (buffer (current-buffer)))
    (when (and project-dir (file-directory-p project-dir))
      (if (not (executable-find "fswatch"))
          (agent-shell-to-go--debug "fswatch not found, image watching disabled")
        (condition-case err
            (let ((proc
                   (start-process "agent-shell-to-go-fswatch" nil "fswatch"
                                  "-r"
                                  "--event"
                                  "Created"
                                  "--event"
                                  "Updated"
                                  project-dir)))
              (set-process-filter
               proc
               (lambda (_p output)
                 (agent-shell-to-go--handle-fswatch-output buffer output)))
              (set-process-query-on-exit-flag proc nil)
              (setq agent-shell-to-go--file-watcher proc)
              (agent-shell-to-go--debug "fswatch started on %s" project-dir))
          (error
           (agent-shell-to-go--debug "fswatch failed: %s" err)))))))

(defun agent-shell-to-go--stop-file-watcher ()
  "Stop the fswatch process for this buffer."
  (when (and agent-shell-to-go--file-watcher
             (process-live-p agent-shell-to-go--file-watcher))
    (ignore-errors
      (kill-process agent-shell-to-go--file-watcher)))
  (setq agent-shell-to-go--file-watcher nil))

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
  (let* ((content (alist-get 'content update))
         (raw-input (alist-get 'rawInput update))
         (content-list
          (cond
           ((vectorp content)
            (append content nil))
           ((and content (listp content) (not (alist-get 'type content)))
            content)
           (content
            (list content)))))
    (cond
     ((and content-list
           (seq-find
            (lambda (item) (equal (alist-get 'type item) "diff")) content-list))
      (let ((di
             (seq-find
              (lambda (item) (equal (alist-get 'type item) "diff")) content-list)))
        (cons (or (alist-get 'oldText di) "") (alist-get 'newText di))))
     ((and raw-input (alist-get 'new_str raw-input))
      (cons (or (alist-get 'old_str raw-input) "") (alist-get 'new_str raw-input)))
     ((and raw-input (alist-get 'diff raw-input))
      (agent-shell-to-go--parse-unified-diff (alist-get 'diff raw-input))))))

; Send helpers (buffer-context wrappers) 

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

; Inject message into agent-shell 

(defun agent-shell-to-go--inject-message (text)
  "Inject TEXT into the current agent-shell buffer as if typed locally."
  (when (derived-mode-p 'agent-shell-mode)
    (if (shell-maker-busy)
        (progn
          (agent-shell--enqueue-request :prompt text)
          (agent-shell-to-go--send
           (format "_Queued: %s_" (agent-shell-to-go--truncate-text text 100))))
      (setq agent-shell-to-go--from-remote t)
      (save-excursion
        (goto-char (point-max))
        (insert text))
      (goto-char (point-max))
      (call-interactively #'shell-maker-submit))))

; Permission helpers 

(defun agent-shell-to-go--find-option-id (options action)
  "Find option id in OPTIONS matching canonical ACTION symbol."
  (let ((kinds
         (pcase action
           ('permission-allow '("allow" "accept" "allow_once"))
           ('permission-always '("always" "alwaysAllow" "allow_always"))
           ('permission-reject '("deny" "reject" "reject_once")))))
    (when-let* ((opt
                 (seq-find
                  (lambda (opt) (member (alist-get 'kind opt) kinds))
                  (append options nil))))
      (or (alist-get 'optionId opt) (alist-get 'id opt)))))

; Set agent mode helper 

(defun agent-shell-to-go--set-mode (buffer mode-id mode-name)
  "Set MODE-ID in BUFFER and notify the thread."
  (with-current-buffer buffer
    (agent-shell--set-default-session-mode
     :shell-buffer (get-buffer buffer)
     :mode-id mode-id
     :on-mode-changed
     (lambda () (agent-shell-to-go--send (format "Mode: *%s*" mode-name))))))

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
           "`!latest` — jump to bottom of thread\n"
           "`!debug` — show session info"))
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
        ("!latest"
         (agent-shell-to-go--send "↓")
         t)
        ("!debug"
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
             (let* ((project-dir default-directory)
                    (state agent-shell--state)
                    (session-id (map-nested-elt state '(:session :id)))
                    (transcript-dir
                     (expand-file-name "transcripts"
                                       (or (bound-and-true-p agent-shell-sessions-dir)
                                           "~/.agent-shell")))
                    (transcript-file
                     (and session-id
                          (expand-file-name (concat session-id ".md") transcript-dir)))
                    (has-transcript
                     (and transcript-file (file-exists-p transcript-file))))
               (agent-shell-to-go--send "Restarting agent…")
               (ignore-errors
                 (agent-shell-interrupt t))
               (run-at-time
                1 nil
                (lambda ()
                  (let ((default-directory project-dir))
                    (save-window-excursion
                      (funcall agent-shell-to-go-start-agent-function nil)
                      (when has-transcript
                        (run-at-time
                         2 nil
                         (lambda ()
                           (when-let* ((new-buf
                                        (car agent-shell-to-go--active-buffers)))
                             (with-current-buffer new-buf
                               (agent-shell-to-go--inject-message
                                (format "Continue from previous session. Transcript: %s"
                                        transcript-file))))))))))))
           (error
            (agent-shell-to-go--send (format "Restart failed: %s" err))))
         t)
        (_ nil)))))

; Inbound hook handlers (registered on message/reaction/slash hooks) 

(cl-defun agent-shell-to-go--bridge-on-message
    (&key transport channel thread-id text &allow-other-keys)
  "Handle an inbound message from a transport."
  (let ((buffer
         (and thread-id
              (agent-shell-to-go--find-buffer-for-transport-channel-thread
               transport channel
               thread-id))))
    (when buffer
      (with-current-buffer buffer
        (if (string-prefix-p "!" text)
            (agent-shell-to-go--handle-command text buffer)
          (agent-shell-to-go--inject-message text))))))

(cl-defun agent-shell-to-go--bridge-on-reaction
    (&key transport channel msg-id action added-p &allow-other-keys)
  "Handle an inbound reaction from a transport.
Presentation reactions are handled by the main dispatcher registered first.
Here we only handle agent-state reactions."
  (when added-p
    (pcase action
      ('heart
       (let* ((buffer
               (agent-shell-to-go--find-buffer-for-transport-channel-thread
                transport channel
                nil))
              (thread-id
               (and buffer (buffer-local-value 'agent-shell-to-go--thread-id buffer)))
              (message-text
               (and buffer
                    (agent-shell-to-go-transport-get-message-text
                     transport channel msg-id))))
         (when (and buffer message-text)
           (with-current-buffer buffer
             (agent-shell-to-go--inject-message
              (format "The user heart reacted to: %s" message-text))))))
      ('bookmark (agent-shell-to-go--handle-bookmark-reaction transport channel msg-id))
      ((or 'permission-allow 'permission-always 'permission-reject)
       (agent-shell-to-go--handle-permission-reaction
        transport channel msg-id action)))))

(defun agent-shell-to-go--handle-bookmark-reaction (transport channel msg-id)
  "Create an org TODO for MSG-ID in CHANNEL on TRANSPORT."
  (let* ((buffer
          (agent-shell-to-go--find-buffer-for-transport-channel-thread transport channel
                                                                       nil))
         (thread-id
          (and buffer (buffer-local-value 'agent-shell-to-go--thread-id buffer)))
         (message-text
          (agent-shell-to-go-transport-get-message-text transport channel msg-id))
         (project-name
          (or (and buffer
                   (with-current-buffer buffer
                     (file-name-nondirectory (directory-file-name default-directory))))
              "slack"))
         (today (format-time-string "%Y-%m-%d"))
         (timestamp (format-time-string "%Y%m%d-%H%M%S"))
         (todo-dir (expand-file-name agent-shell-to-go-todo-directory))
         (todo-file
          (expand-file-name (format "%s-%s.org" project-name timestamp) todo-dir))
         (title-text
          (if message-text
              (let ((first-line (car (split-string message-text "\n" t))))
                (if (> (length first-line) 60)
                    (concat (substring first-line 0 57) "…")
                  first-line))
            "Bookmarked message")))
    (when message-text
      (make-directory todo-dir t)
      (with-temp-file todo-file
        (insert
         (format "* TODO %s\nSCHEDULED: <%s>\n\nProject: %s\n\n** Message\n%s\n"
                 title-text
                 today
                 project-name
                 message-text)))
      (agent-shell-to-go-transport-send-text
       transport
       channel
       (or thread-id msg-id)
       (format "TODO created: `%s`" (file-name-nondirectory todo-file))))))

(defun agent-shell-to-go--handle-permission-reaction (transport channel msg-id action)
  "Handle a permission reaction ACTION on MSG-ID."
  (let* ((key (list (agent-shell-to-go-transport-name transport) channel msg-id))
         (pending (assoc key agent-shell-to-go--pending-permissions #'equal)))
    (when pending
      (let* ((info (cdr pending))
             (request-id (plist-get info :request-id))
             (buffer (plist-get info :buffer))
             (options (plist-get info :options)))
        (when (and buffer (buffer-live-p buffer))
          (let ((option-id (agent-shell-to-go--find-option-id options action)))
            (when option-id
              (with-current-buffer buffer
                (let ((state agent-shell--state))
                  (agent-shell--send-permission-response
                   :client (alist-get :client state)
                   :request-id request-id
                   :option-id option-id
                   :state state)))
              (setq agent-shell-to-go--pending-permissions
                    (cl-remove key agent-shell-to-go--pending-permissions
                               :key #'car
                               :test #'equal)))))))))

(cl-defun agent-shell-to-go--bridge-on-slash-command
    (&key transport command args channel &allow-other-keys)
  "Handle an inbound slash command from a transport."
  (let* ((typed-args args)
         (reply
          (lambda (text)
            (agent-shell-to-go-transport-send-text transport channel nil text))))
    (pcase command
      ("/new-agent" (let* ((folder
               (expand-file-name
                (or (plist-get typed-args :folder) agent-shell-to-go-default-folder)))
              (container-p (plist-get typed-args :container-p)))
         (agent-shell-to-go--start-agent-in-folder
          folder container-p transport channel)))
      ("/new-agent-container" (let ((folder
              (expand-file-name
               (or (plist-get typed-args :folder) agent-shell-to-go-default-folder))))
         (agent-shell-to-go--start-agent-in-folder folder t transport channel)))
      ("/new-project" (let ((project-name (plist-get typed-args :project-name)))
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
                         final-dir nil transport channel))))
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

(defun agent-shell-to-go--start-agent-in-folder (folder container-p transport channel)
  "Start an agent in FOLDER, notify CHANNEL via TRANSPORT."
  (agent-shell-to-go--debug "starting agent in %s (container: %s)" folder container-p)
  (if (file-directory-p folder)
      (let ((default-directory folder))
        (save-window-excursion
          (condition-case err
              (progn
                (funcall agent-shell-to-go-start-agent-function
                         (if container-p
                             '(4)
                           nil))
                (agent-shell-to-go-transport-send-text
                 transport channel nil
                 (format "Agent started in `%s`%s"
                         folder
                         (if container-p
                             " (container)"
                           ""))))
            (error
             (agent-shell-to-go--debug "error starting agent: %s" err)))))
    (agent-shell-to-go-transport-send-text
     transport channel nil (format "Folder does not exist: `%s`" folder))))

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
         (when-let ((f (buffer-file-name buf)))
           (file-name-directory f)))
       (buffer-list)))))))

; Session title fetch (ACP) 

(defun agent-shell-to-go--fetch-session-title ()
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

; Advice functions 

(defun agent-shell-to-go--on-request (orig-fn &rest args)
  "Advice around `agent-shell--on-request'.  Notify on permission requests."
  (let* ((state (plist-get args :state))
         (request (plist-get args :acp-request))
         (method (alist-get 'method request))
         (buffer (and state (alist-get :buffer state))))
    (when (and buffer
               (buffer-live-p buffer)
               (equal method "session/request_permission")
               (buffer-local-value 'agent-shell-to-go-mode buffer))
      (let* ((thread-id (buffer-local-value 'agent-shell-to-go--thread-id buffer))
             (transport (buffer-local-value 'agent-shell-to-go--transport buffer))
             (channel-id (buffer-local-value 'agent-shell-to-go--channel-id buffer))
             (request-id (alist-get 'id request))
             (params (alist-get 'params request))
             (options (alist-get 'options params))
             (tool-call (alist-get 'toolCall params))
             (title (alist-get 'title tool-call))
             (raw-input (alist-get 'rawInput tool-call))
             (command (and raw-input (alist-get 'command raw-input))))
        (when (and thread-id transport channel-id)
          (condition-case err
              (let
                  ((msg-id
                    (agent-shell-to-go-transport-send-text
                     transport channel-id thread-id
                     (format
                      "*Permission Required*\n`%s`\n\nReact to approve, deny, or always allow."
                      (or command title "Unknown action")))))
                (when msg-id
                  (push (cons
                         (list
                          (agent-shell-to-go-transport-name transport)
                          channel-id
                          msg-id)
                         (list
                          :request-id request-id
                          :buffer buffer
                          :options options
                          :command (or command title "Unknown")))
                        agent-shell-to-go--pending-permissions)))
            (error
             (message "agent-shell-to-go permission notify error: %s" err)))))))
  (apply orig-fn args))

(defun agent-shell-to-go--on-send-command (orig-fn &rest args)
  "Advice around `agent-shell--send-command'.  Mirror user prompts."
  (when (and agent-shell-to-go-mode
             agent-shell-to-go--thread-id
             (not agent-shell-to-go--from-remote))
    (let ((prompt (plist-get args :prompt)))
      (when prompt
        (agent-shell-to-go--send
         (agent-shell-to-go-transport-format-user-message
          agent-shell-to-go--transport prompt))
        (agent-shell-to-go--send "Processing..."))))
  (setq agent-shell-to-go--from-remote nil)
  (setq agent-shell-to-go--current-agent-message nil)
  (apply orig-fn args))

(cl-defun agent-shell-to-go--on-client-initialized (&key shell)
  "After-advice for `agent-shell--initialize-client'.  Forward failures."
  (let ((buffer (map-elt agent-shell--state :buffer)))
    (when (and buffer
               (buffer-live-p buffer)
               (buffer-local-value 'agent-shell-to-go-mode buffer)
               (not (map-elt agent-shell--state :client)))
      (with-current-buffer buffer
        (when agent-shell-to-go--thread-id
          (agent-shell-to-go--send
           "*Agent failed to start* — check API key / OAuth token"))))))

(defun agent-shell-to-go--on-notification (orig-fn &rest args)
  "Advice around `agent-shell--on-notification'.  Mirror updates to transport."
  (let* ((state (plist-get args :state))
         (buffer (alist-get :buffer state)))
    (when (and buffer
               (buffer-live-p buffer)
               (buffer-local-value 'agent-shell-to-go-mode buffer))
      (let* ((notification (plist-get args :acp-notification))
             (params (alist-get 'params notification))
             (update (alist-get 'update params))
             (update-type (alist-get 'sessionUpdate update))
             (transport (buffer-local-value 'agent-shell-to-go--transport buffer))
             (thread-id (buffer-local-value 'agent-shell-to-go--thread-id buffer)))
        (when (and thread-id transport)
          (pcase update-type
            ("agent_message_chunk"
             (let ((text (alist-get 'text (alist-get 'content update))))
               (with-current-buffer buffer
                 (setq agent-shell-to-go--current-agent-message
                       (concat agent-shell-to-go--current-agent-message text)))))

            ("tool_call"
             (with-current-buffer buffer
               ;; Flush pending agent text first to preserve ordering
               (when (and agent-shell-to-go--current-agent-message
                          (> (length agent-shell-to-go--current-agent-message) 0))
                 (agent-shell-to-go--send
                  (agent-shell-to-go-transport-format-agent-message
                   transport agent-shell-to-go--current-agent-message))
                 (setq agent-shell-to-go--current-agent-message nil))
               ;; Record mentioned file paths for image uploads
               (dolist (path (agent-shell-to-go--extract-file-paths-from-update update))
                 (agent-shell-to-go--record-mentioned-file path))
               (unless agent-shell-to-go--tool-calls
                 (setq agent-shell-to-go--tool-calls (make-hash-table :test 'equal))))
             (let* ((tool-call-id (alist-get 'toolCallId update))
                    (title (alist-get 'title update))
                    (raw-input (alist-get 'rawInput update))
                    (command (alist-get 'command raw-input))
                    (file-path (alist-get 'file_path raw-input))
                    (query (alist-get 'query raw-input))
                    (url (alist-get 'url raw-input))
                    (specific (or command file-path query url))
                    (title-has-specific
                     (and title
                          specific
                          (string-match-p (regexp-quote specific) title)))
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
                    (diff (agent-shell-to-go--extract-diff update))
                    (diff-text
                     (and diff
                          (agent-shell-to-go-transport-format-diff
                           transport (car diff) (cdr diff))))
                    (already-sent
                     (and tool-call-id
                          (with-current-buffer buffer
                            (gethash tool-call-id agent-shell-to-go--tool-calls)))))
               (when (and specific (not already-sent))
                 (with-current-buffer buffer
                   (puthash tool-call-id t agent-shell-to-go--tool-calls))
                 (condition-case err
                     (if (and diff-text (> (length diff-text) 0))
                         (agent-shell-to-go--send
                          (format "%s\n%s"
                                  (agent-shell-to-go-transport-format-tool-call-start
                                   transport display)
                                  diff-text)
                          '(:truncate t))
                       (agent-shell-to-go--send
                        (agent-shell-to-go-transport-format-tool-call-start
                         transport display)
                        '(:truncate t)))
                   (error
                    (agent-shell-to-go--debug "tool_call send error: %s" err))))))

            ("tool_call_update"
             (with-current-buffer buffer
               (dolist (path (agent-shell-to-go--extract-file-paths-from-update update))
                 (agent-shell-to-go--record-mentioned-file path)))
             (let* ((status-str (alist-get 'status update))
                    (status (intern (or status-str "unknown")))
                    (content (alist-get 'content update))
                    (content-text
                     (and content
                          (mapconcat (lambda (item)
                                       (or (alist-get 'text (alist-get 'content item))
                                           (alist-get 'text item)
                                           ""))
                                     (if (vectorp content)
                                         (append content nil)
                                       (if (listp content)
                                           content
                                         nil))
                                     "\n")))
                    (output
                     (or (alist-get 'rawOutput update)
                         (alist-get 'output update)
                         content-text))
                    (diff
                     (condition-case nil
                         (agent-shell-to-go--extract-diff update)
                       (error
                        nil)))
                    (diff-text
                     (and diff
                          (condition-case nil
                              (agent-shell-to-go-transport-format-diff
                               transport (car diff) (cdr diff))
                            (error
                             nil)))))
               (when (member status-str '("completed" "failed"))
                 (let ((icon
                        (if (equal status-str "completed")
                            "[ok]"
                          "[fail]")))
                   (cond
                    ((and diff-text (> (length diff-text) 0))
                     (let ((full (format "%s\n%s" icon diff-text)))
                       (if agent-shell-to-go-show-tool-output
                           (agent-shell-to-go--send full '(:truncate t))
                         (let ((msg-id (agent-shell-to-go--send icon)))
                           (when msg-id
                             (with-current-buffer buffer
                               (agent-shell-to-go--save-truncated-message
                                transport
                                agent-shell-to-go--channel-id
                                msg-id
                                full
                                icon)))))))
                    ((and output (stringp output) (> (length output) 0))
                     (let ((full
                            (agent-shell-to-go-transport-format-tool-call-result
                             transport "output" status output)))
                       (if agent-shell-to-go-show-tool-output
                           (agent-shell-to-go--send full '(:truncate t))
                         (let ((msg-id (agent-shell-to-go--send icon)))
                           (when msg-id
                             (with-current-buffer buffer
                               (agent-shell-to-go--save-truncated-message
                                transport
                                agent-shell-to-go--channel-id
                                msg-id
                                full
                                icon)))))))
                    (t
                     (agent-shell-to-go--send icon)))))))))))
    (apply orig-fn args)))

(defun agent-shell-to-go--on-heartbeat-stop (orig-fn &rest args)
  "Advice around `agent-shell-heartbeat-stop'.  Flush and signal readiness."
  (when (and agent-shell-to-go-mode agent-shell-to-go--thread-id)
    (when (and agent-shell-to-go--current-agent-message
               (> (length agent-shell-to-go--current-agent-message) 0))
      (agent-shell-to-go--send
       (agent-shell-to-go-transport-format-agent-message
        agent-shell-to-go--transport agent-shell-to-go--current-agent-message))
      (setq agent-shell-to-go--current-agent-message nil))
    (agent-shell-to-go--send "_Ready for input_"))
  (apply orig-fn args))

; Hook registration 

(add-hook 'agent-shell-to-go-message-hook #'agent-shell-to-go--bridge-on-message)
(add-hook 'agent-shell-to-go-reaction-hook #'agent-shell-to-go--bridge-on-reaction)
(add-hook
 'agent-shell-to-go-slash-command-hook #'agent-shell-to-go--bridge-on-slash-command)

; Enable / disable 

(defun agent-shell-to-go--bridge-enable ()
  "Enable transport mirroring for this buffer."
  (let* ((transport (agent-shell-to-go--default-transport))
         (project-path (agent-shell-to-go--get-project-path)))
    ;; Load credentials / connect if needed
    (unless (agent-shell-to-go-transport-connected-p transport)
      (agent-shell-to-go-transport-connect transport))
    ;; Resolve channel
    (setq agent-shell-to-go--transport transport)
    (setq agent-shell-to-go--channel-id
          (agent-shell-to-go-transport-ensure-project-channel transport project-path))
    ;; Start thread
    (setq agent-shell-to-go--thread-id
          (agent-shell-to-go-transport-start-thread
           transport agent-shell-to-go--channel-id (buffer-name)))
    ;; Track buffer
    (add-to-list 'agent-shell-to-go--active-buffers (current-buffer))
    ;; Add advice
    (advice-add 'agent-shell--send-command :around #'agent-shell-to-go--on-send-command)
    (advice-add
     'agent-shell--on-notification
     :around #'agent-shell-to-go--on-notification)
    (advice-add 'agent-shell--on-request :around #'agent-shell-to-go--on-request)
    (advice-add
     'agent-shell-heartbeat-stop
     :around #'agent-shell-to-go--on-heartbeat-stop)
    (advice-add
     'agent-shell--initialize-client
     :after #'agent-shell-to-go--on-client-initialized)
    ;; Subscribe to turn-complete for session title
    (setq agent-shell-to-go--turn-complete-subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :event 'turn-complete
           :on-event
           (lambda (_event) (agent-shell-to-go--fetch-session-title))))
    ;; Start file watcher
    (agent-shell-to-go--start-file-watcher)
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
  (agent-shell-to-go--stop-file-watcher)
  (when agent-shell-to-go--turn-complete-subscription
    (ignore-errors
      (agent-shell-unsubscribe
       :subscription agent-shell-to-go--turn-complete-subscription))
    (setq agent-shell-to-go--turn-complete-subscription nil))
  (when (and agent-shell-to-go--thread-id agent-shell-to-go--transport)
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
  (setq agent-shell-to-go--active-buffers
        (delete (current-buffer) agent-shell-to-go--active-buffers))
  (unless agent-shell-to-go--active-buffers
    (advice-remove 'agent-shell--send-command #'agent-shell-to-go--on-send-command)
    (advice-remove 'agent-shell--on-notification #'agent-shell-to-go--on-notification)
    (advice-remove 'agent-shell--on-request #'agent-shell-to-go--on-request)
    (advice-remove 'agent-shell-heartbeat-stop #'agent-shell-to-go--on-heartbeat-stop)
    (advice-remove
     'agent-shell--initialize-client #'agent-shell-to-go--on-client-initialized))
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
              (or agent-shell-to-go--transport (agent-shell-to-go--default-transport)))
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
        (agent-shell-to-go--start-file-watcher)
        (advice-add
         'agent-shell--send-command
         :around #'agent-shell-to-go--on-send-command)
        (advice-add
         'agent-shell--on-notification
         :around #'agent-shell-to-go--on-notification)
        (advice-add 'agent-shell--on-request :around #'agent-shell-to-go--on-request)
        (advice-add
         'agent-shell-heartbeat-stop
         :around #'agent-shell-to-go--on-heartbeat-stop)
        (add-hook 'kill-buffer-hook #'agent-shell-to-go--on-buffer-kill nil t)
        (unless agent-shell-to-go-mode
          (setq agent-shell-to-go-mode t))
        (message "Reconnected %s (new thread)" (buffer-name buf))))))

(defun agent-shell-to-go--bridge-buffer-connected-p (&optional buffer)
  "Return non-nil if BUFFER has a valid transport connection."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (buffer-local-value 'agent-shell-to-go--thread-id buf)
         (buffer-local-value 'agent-shell-to-go--channel-id buf)
         (memq buf agent-shell-to-go--active-buffers))))


(provide 'agent-shell-to-go-bridge)
;;; agent-shell-to-go-bridge.el ends here
