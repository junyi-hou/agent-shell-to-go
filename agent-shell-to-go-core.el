;;; agent-shell-to-go-core.el --- Shared protocol core for agent-shell-to-go -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Shared infrastructure required by all transport implementations:
;; defcustoms, shared utilities, the transport struct/generics, the
;; transport registry, inbound hook variables, storage helpers, the
;; generic WebSocket state machine, and slash-command arg schemas.
;;
;; Transport files (slack, discord, …) and the bridge all require this
;; file directly.  The top-level `agent-shell-to-go.el' requires this
;; plus the transport and bridge files.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'websocket)

(defgroup agent-shell-to-go nil
  "Take your `agent-shell' sessions anywhere."
  :group 'agent-shell
  :prefix "agent-shell-to-go-")

; Defcustoms

(defcustom agent-shell-to-go-default-folder
  (let ((default-folder (expand-file-name ".agent-shell-to-go" (expand-file-name "~"))))
    (make-directory default-folder t)
    default-folder)
  "Default folder for `/new-agent' when no folder is specified."
  :type 'string
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-start-agent-function #'agent-shell
  "Function to call to start a new agent-shell.
Override if you have a custom starter function."
  :type 'function
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-debug nil
  "When non-nil, log debug messages to *Messages*."
  :type 'boolean
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-show-tool-output t
  "When non-nil, show tool call outputs in remote messages.
When nil, only status icons are shown (use expand reaction to reveal)."
  :type 'boolean
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-upload-transcript-on-end nil
  "When non-nil, upload the agent-shell transcript when the session ends."
  :type 'boolean
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-event-log-max-entries 200
  "Maximum number of entries to keep in the event log buffer."
  :type 'integer
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-storage-base-dir "~/.agent-shell/"
  "Base directory for per-transport state storage.
Each transport gets a subdirectory named after it."
  :type 'string
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-projects-directory "~/code/"
  "Directory where `/new-project' creates new project folders."
  :type 'string
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-new-project-function nil
  "Function to call to set up a new project.
Called with (PROJECT-NAME BASE-DIR CALLBACK).
CALLBACK is called with PROJECT-DIR when setup is complete.
If nil, just creates the directory and starts the agent immediately."
  :type '(choice (const :tag "Just create directory" nil)
                 (function :tag "Custom setup function"))
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-active-transports '(slack)
  "List of transport names to use.
Each symbol must be a registered transport (see
`agent-shell-to-go-register-transport').  Buffers pick the first
transport in this list when the minor mode is enabled."
  :type '(repeat symbol)
  :group 'agent-shell-to-go)

(defcustom agent-shell-to-go-cleanup-age-hours 168
  "Threads older than this many hours are eligible for cleanup.
Default is 7 days."
  :type 'number
  :group 'agent-shell-to-go)

; Shared utilities

(defconst agent-shell-to-go--debug-buffer-name "*agent-shell-to-go-debug*"
  "Name of the buffer used for debug logging.")

(defun agent-shell-to-go--debug (format-string &rest args)
  "Append a timestamped debug line to `agent-shell-to-go--debug-buffer-name'.
Does nothing when `agent-shell-to-go-debug' is nil."
  (when agent-shell-to-go-debug
    (let* ((msg (apply #'format format-string args))
           (line (format "[%s] %s\n" (format-time-string "%H:%M:%S") msg))
           (buf (get-buffer-create agent-shell-to-go--debug-buffer-name)))
      (with-current-buffer buf
        (goto-char (point-max))
        (insert line)
        (let ((excess (- (count-lines (point-min) (point-max))
                         agent-shell-to-go-event-log-max-entries)))
          (when (> excess 0)
            (goto-char (point-min))
            (forward-line excess)
            (delete-region (point-min) (point))))))))

(defun agent-shell-to-go--strip-non-ascii (text)
  "Strip non-ASCII characters from TEXT, replacing them with `?'."
  (when text
    (replace-regexp-in-string "[^[:ascii:]]" "?" text)))

(defun agent-shell-to-go--sanitize-channel-name (name)
  "Sanitize NAME for use as a channel name.
Lowercase, replace invalid characters with hyphens, max 80 chars."
  (let* ((clean (downcase name))
         (clean (replace-regexp-in-string "[^a-z0-9-]" "-" clean))
         (clean (replace-regexp-in-string "-+" "-" clean))
         (clean (replace-regexp-in-string "^-\\|-$" "" clean)))
    (if (> (length clean) 80)
        (substring clean 0 80)
      clean)))

(defun agent-shell-to-go--get-project-path ()
  "Get the project path for the current buffer."
  (or (and (fboundp 'projectile-project-root) (projectile-project-root))
      (and (fboundp 'project-current)
           (when-let ((proj (project-current)))
             (if (fboundp 'project-root)
                 (project-root proj)
               (car (project-roots proj)))))
      default-directory))

(defun agent-shell-to-go--env-file-parse (path keys)
  "Parse a dotenv-style FILE at PATH, extracting KEYS.
KEYS is a list of key strings.  Returns alist of (key . value)."
  (when (file-exists-p path)
    (let (result)
      (with-temp-buffer
        (insert-file-contents (expand-file-name path))
        (goto-char (point-min))
        (while (re-search-forward "^\\([A-Z_]+\\)=\\(.+\\)$" nil t)
          (let ((k (match-string 1))
                (v (match-string 2)))
            (when (member k keys)
              (push (cons k v) result)))))
      (nreverse result))))

; Transport protocol

(cl-defstruct agent-shell-to-go-transport
  "Base struct for transport implementations.
Transports `:include' this and add their own slots."
  (name nil :read-only t))

;; Lifecycle

(cl-defgeneric agent-shell-to-go-transport-connect (transport)
  "Connect TRANSPORT to its remote service.")

(cl-defgeneric agent-shell-to-go-transport-disconnect (transport)
  "Disconnect TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-connected-p (transport)
  "Return non-nil if TRANSPORT is currently connected.")

(cl-defgeneric agent-shell-to-go-transport-authorized-p (transport user-id)
  "Return non-nil if USER-ID is allowed to interact via TRANSPORT.
Each transport knows its own user-id format.")

(cl-defgeneric agent-shell-to-go-transport-bot-user-id (transport)
  "Return the bot/self user-id for TRANSPORT, used for dedup.")

;; Send / edit / upload

(cl-defgeneric agent-shell-to-go-transport-send-text
    (transport channel thread-id text &optional options)
  "Send TEXT on TRANSPORT to CHANNEL under THREAD-ID.
OPTIONS is a plist, possibly including:
  :truncate           truncate long content, store the rest for expansion
  :ephemeral          only visible to :user-id
  :user-id            target user for ephemeral
  :interaction-token  opaque transport token for ack-style replies
Returns a message-id string.")

(cl-defgeneric agent-shell-to-go-transport-edit-message
    (transport channel message-id text)
  "Edit MESSAGE-ID on TRANSPORT in CHANNEL to be TEXT.
Returns non-nil if the edit succeeded.")

(cl-defgeneric agent-shell-to-go-transport-upload-file
    (transport channel thread-id path &optional comment)
  "Upload PATH to CHANNEL under THREAD-ID with optional COMMENT.")

(cl-defgeneric agent-shell-to-go-transport-acknowledge-interaction
    (transport interaction-token &optional options)
  "Acknowledge a transport interaction for INTERACTION-TOKEN.
Required on Discord for the 3-second interaction rule; no-op on Slack.
OPTIONS may include :ephemeral or :deferred.")

;; Read

(cl-defgeneric agent-shell-to-go-transport-get-message-text
    (transport channel message-id)
  "Return the text of MESSAGE-ID in CHANNEL on TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-get-reactions (transport channel message-id)
  "Return canonical reaction actions for MESSAGE-ID in CHANNEL on TRANSPORT.
Transports translate raw emoji to canonical actions before returning.")

(cl-defgeneric agent-shell-to-go-transport-fetch-thread-replies
    (transport channel thread-id)
  "Return a list of reply plists for THREAD-ID in CHANNEL on TRANSPORT.
Each plist has keys :msg-id :user :text.")

;; Threads & channels

(cl-defgeneric agent-shell-to-go-transport-start-thread (transport channel label)
  "Start a new thread on TRANSPORT in CHANNEL with LABEL.  Return thread id.")

(cl-defgeneric agent-shell-to-go-transport-update-thread-header
    (transport channel thread-id title)
  "Update the thread header for THREAD-ID in CHANNEL to TITLE.")

(cl-defgeneric agent-shell-to-go-transport-ensure-project-channel
    (transport project-path)
  "Return the top-level posting destination on TRANSPORT for PROJECT-PATH.")

(cl-defgeneric agent-shell-to-go-transport-list-threads (transport channel)
  "Return a list of thread plists (:thread-id :last-timestamp) in CHANNEL.")

(cl-defgeneric agent-shell-to-go-transport-delete-message (transport channel message-id)
  "Delete MESSAGE-ID in CHANNEL on TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-delete-thread (transport channel thread-id)
  "Delete THREAD-ID (all messages) in CHANNEL on TRANSPORT.")

;; Formatting (semantic; transport renders its own markup)

(cl-defgeneric agent-shell-to-go-transport-format-tool-call-start (transport title)
  "Return rendered string announcing a tool call with TITLE on TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-format-tool-call-result
    (transport title status output)
  "Return rendered string for a tool call result on TRANSPORT.
STATUS is a symbol; OUTPUT is a string (may be empty or nil).")

(cl-defgeneric agent-shell-to-go-transport-format-diff (transport old-text new-text)
  "Return rendered diff string on TRANSPORT between OLD-TEXT and NEW-TEXT.")

(cl-defgeneric agent-shell-to-go-transport-format-user-message (transport text)
  "Return rendered user-authored TEXT on TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-format-agent-message (transport text)
  "Return rendered agent-authored TEXT on TRANSPORT.")

(cl-defgeneric agent-shell-to-go-transport-format-markdown (transport markdown)
  "Convert MARKDOWN to TRANSPORT's native markup.")

;; Storage root (with default method)

(cl-defgeneric agent-shell-to-go-transport-storage-root (transport)
  "Return the per-transport on-disk storage directory.")

(cl-defmethod agent-shell-to-go-transport-storage-root
    ((transport agent-shell-to-go-transport))
  "Default: `{storage-base-dir}/{transport-name}/'."
  (expand-file-name (format "%s/"
                            (symbol-name (agent-shell-to-go-transport-name transport)))
                    agent-shell-to-go-storage-base-dir))

; Transport registry

(defvar agent-shell-to-go--transports (make-hash-table :test 'eq)
  "Hash of registered transports, keyed by symbol name.")

(defun agent-shell-to-go-register-transport (name transport)
  "Register TRANSPORT under NAME (a symbol).
Later lookups via `agent-shell-to-go-get-transport' return TRANSPORT."
  (puthash name transport agent-shell-to-go--transports)
  (agent-shell-to-go--debug "registered transport: %s" name))

(defun agent-shell-to-go-get-transport (name)
  "Return the registered transport named NAME, or nil."
  (gethash name agent-shell-to-go--transports))

(defun agent-shell-to-go--active-transport-objects ()
  "Return transport objects for each name in `agent-shell-to-go-active-transports'."
  (delq nil (mapcar #'agent-shell-to-go-get-transport agent-shell-to-go-active-transports)))

(defun agent-shell-to-go--default-transport ()
  "Return the first active, registered transport, or error."
  (or (car (agent-shell-to-go--active-transport-objects))
      (error "No active transport registered; check `agent-shell-to-go-active-transports'")))

; Canonical inbound events

(defconst agent-shell-to-go--canonical-reaction-actions
  '(hide
    expand-truncated
    expand-full
    collapse
    permission-allow
    permission-always
    permission-reject)
  "Closed set of canonical reaction action symbols.
Transports map raw reactions to these when firing the reaction hook.")

(defvar agent-shell-to-go-message-hook nil
  "Hook run when a remote message arrives.
Each function is called with a single plist argument:
  :transport  transport struct
  :channel    channel id
  :thread-id  thread id
  :user       remote user id
  :text       message text
  :msg-id     remote message id")

(defvar agent-shell-to-go-reaction-hook nil
  "Hook run when a remote reaction is added or removed.
Plist argument:
  :transport  transport struct
  :channel    channel id
  :thread-id  thread id (may be nil)
  :msg-id     target message id
  :user       remote user id
  :action     canonical symbol from `agent-shell-to-go--canonical-reaction-actions',
              or nil if the raw reaction didn't map to anything
  :raw-emoji  opaque raw emoji (do not assume stringp)
  :added-p    t if reaction was added, nil if removed")

(defvar agent-shell-to-go-slash-command-hook nil
  "Hook run when a remote slash command fires.
Plist argument:
  :transport         transport struct
  :command           command name string (with leading slash)
  :args              typed args plist (per-command schema)
  :args-text         raw argument text
  :channel           channel id
  :user              remote user id
  :interaction-token opaque ack token (nil on Slack)")

; Storage helpers

(defconst agent-shell-to-go--max-message-length 3800
  "Maximum body length for a transport message (with buffer for extra markup).")

(defconst agent-shell-to-go--truncation-note "\n_... (full text too long)_"
  "Note appended when an expanded message still exceeds transport limit.")

(defconst agent-shell-to-go--truncated-view-length 500
  "Length for truncated view (glance).")

(defun agent-shell-to-go--truncate-text (text &optional max-len)
  "Truncate TEXT to MAX-LEN (default 500), adding a hint."
  (let ((max-len (or max-len 500)))
    (if (> (length text) max-len)
        (concat (substring text 0 max-len) "\n_… expand for more_")
      text)))

(defun agent-shell-to-go--hidden-path (transport channel msg-id)
  "Return path for hidden MSG-ID in CHANNEL on TRANSPORT."
  (expand-file-name (format "hidden/%s/%s.txt" channel msg-id)
                    (agent-shell-to-go-transport-storage-root transport)))

(defun agent-shell-to-go--truncated-path (transport channel msg-id)
  "Return path for truncated MSG-ID full text in CHANNEL on TRANSPORT."
  (expand-file-name (format "truncated/%s/%s.txt" channel msg-id)
                    (agent-shell-to-go-transport-storage-root transport)))

(defun agent-shell-to-go--collapsed-path (transport channel msg-id)
  "Return path for collapsed form of MSG-ID in CHANNEL on TRANSPORT."
  (concat (agent-shell-to-go--truncated-path transport channel msg-id) ".collapsed"))

(defun agent-shell-to-go--save-file (path text)
  "Save TEXT to PATH, creating directories as needed."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert text)))

(defun agent-shell-to-go--load-file (path)
  "Read file at PATH as a string, or return nil if missing."
  (when (file-exists-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun agent-shell-to-go--save-hidden-message (transport channel msg-id text)
  "Save original TEXT for hidden MSG-ID."
  (agent-shell-to-go--save-file
   (agent-shell-to-go--hidden-path transport channel msg-id) text))

(defun agent-shell-to-go--load-hidden-message (transport channel msg-id)
  "Load original text for hidden MSG-ID."
  (agent-shell-to-go--load-file
   (agent-shell-to-go--hidden-path transport channel msg-id)))

(defun agent-shell-to-go--delete-hidden-message-file (transport channel msg-id)
  "Delete hidden MSG-ID file."
  (let ((path (agent-shell-to-go--hidden-path transport channel msg-id)))
    (when (file-exists-p path)
      (delete-file path))))

(defun agent-shell-to-go--save-truncated-message
    (transport channel msg-id full-text &optional collapsed-text)
  "Save FULL-TEXT for MSG-ID.  Optionally also save COLLAPSED-TEXT."
  (agent-shell-to-go--save-file
   (agent-shell-to-go--truncated-path transport channel msg-id) full-text)
  (when collapsed-text
    (agent-shell-to-go--save-file
     (agent-shell-to-go--collapsed-path transport channel msg-id) collapsed-text)))

(defun agent-shell-to-go--load-truncated-message (transport channel msg-id)
  "Load full text for MSG-ID."
  (agent-shell-to-go--load-file
   (agent-shell-to-go--truncated-path transport channel msg-id)))

(defun agent-shell-to-go--load-collapsed-message (transport channel msg-id)
  "Load collapsed form for MSG-ID, if any."
  (agent-shell-to-go--load-file
   (agent-shell-to-go--collapsed-path transport channel msg-id)))

; Presentation-reaction dispatcher

(cl-defun agent-shell-to-go--handle-presentation-reaction
    (&key transport channel msg-id action added-p &allow-other-keys)
  "Handle presentation reactions (hide/expand/collapse) from a transport.
This runs before bridge handlers so the bridge never sees presentation reactions."
  (pcase (cons added-p action)
    (`(t . hide)
     (when-let* ((text (agent-shell-to-go-transport-get-message-text
                        transport channel msg-id)))
       (agent-shell-to-go--save-hidden-message transport channel msg-id text)
       (agent-shell-to-go-transport-edit-message
        transport channel msg-id "_message hidden_")))
    (`(nil . hide)
     (when-let* ((original (agent-shell-to-go--load-hidden-message
                             transport channel msg-id)))
       (agent-shell-to-go-transport-edit-message transport channel msg-id original)
       (agent-shell-to-go--delete-hidden-message-file transport channel msg-id)))
    (`(t . expand-truncated)
     (when-let* ((full (agent-shell-to-go--load-truncated-message
                        transport channel msg-id)))
       (let* ((too-long (> (length full) agent-shell-to-go--truncated-view-length))
              (display (if too-long
                           (concat (substring full 0 agent-shell-to-go--truncated-view-length)
                                   "\n_… expand further for full output_")
                         full)))
         (agent-shell-to-go-transport-edit-message transport channel msg-id display))))
    (`(t . expand-full)
     (when-let* ((full (agent-shell-to-go--load-truncated-message
                        transport channel msg-id)))
       (let* ((too-long (> (length full) agent-shell-to-go--max-message-length))
              (display (if too-long
                           (concat (substring full 0 agent-shell-to-go--max-message-length)
                                   agent-shell-to-go--truncation-note)
                         full)))
         (agent-shell-to-go-transport-edit-message transport channel msg-id display))))
    ((or `(nil . expand-truncated) `(nil . expand-full))
     (let* ((collapsed (agent-shell-to-go--load-collapsed-message transport channel msg-id))
            (full (agent-shell-to-go--load-truncated-message transport channel msg-id))
            (restore (or collapsed (and full (agent-shell-to-go--truncate-text full 500)))))
       (when restore
         (agent-shell-to-go-transport-edit-message transport channel msg-id restore))))))

(add-hook 'agent-shell-to-go-reaction-hook
          #'agent-shell-to-go--handle-presentation-reaction)

; Generic WebSocket state machine
;;
;; Transports that speak WebSocket use this via `agent-shell-to-go--ws-connect'.
;; They pass a URL-FN (callable returning the current ws URL) plus frame and
;; close handlers.  Reconnect and backoff live here.

(cl-defstruct agent-shell-to-go--ws
  "State container for a transport's websocket connection."
  name
  url-fn
  on-frame
  on-close
  websocket
  reconnect-timer
  intentional-close
  (reconnect-backoff 5)
  (get-active-p (lambda () t)))

(defun agent-shell-to-go--ws-make (&rest args)
  "Create a new ws state struct from ARGS plist.
Required keys: :name :url-fn :on-frame.
Optional: :on-close :get-active-p :reconnect-backoff."
  (apply #'make-agent-shell-to-go--ws args))

(defun agent-shell-to-go--ws-connect (ws)
  "Open the websocket described by WS.
Closes any existing socket first."
  (when (agent-shell-to-go--ws-websocket ws)
    (setf (agent-shell-to-go--ws-intentional-close ws) t)
    (ignore-errors
      (websocket-close (agent-shell-to-go--ws-websocket ws)))
    (setf (agent-shell-to-go--ws-intentional-close ws) nil))
  (let ((url (funcall (agent-shell-to-go--ws-url-fn ws)))
        (frame-fn (agent-shell-to-go--ws-on-frame ws))
        (close-fn (agent-shell-to-go--ws-on-close ws)))
    (setf (agent-shell-to-go--ws-websocket ws)
          (websocket-open
           url
           :on-message (lambda (_w frame) (funcall frame-fn frame))
           :on-close
           (lambda (_w)
             (agent-shell-to-go--debug "ws[%s] closed" (agent-shell-to-go--ws-name ws))
             (when close-fn (funcall close-fn))
             (unless (agent-shell-to-go--ws-intentional-close ws)
               (agent-shell-to-go--ws-reconnect ws)))
           :on-error
           (lambda (_w _t err)
             (agent-shell-to-go--debug "ws[%s] error: %s"
                                       (agent-shell-to-go--ws-name ws) err))))))

(defun agent-shell-to-go--ws-reconnect (ws)
  "Schedule WS to reconnect after its backoff."
  (when (agent-shell-to-go--ws-reconnect-timer ws)
    (cancel-timer (agent-shell-to-go--ws-reconnect-timer ws)))
  (when (funcall (agent-shell-to-go--ws-get-active-p ws))
    (setf (agent-shell-to-go--ws-reconnect-timer ws)
          (run-with-timer
           (agent-shell-to-go--ws-reconnect-backoff ws)
           nil
           (lambda () (agent-shell-to-go--ws-connect ws))))))

(defun agent-shell-to-go--ws-disconnect (ws)
  "Disconnect WS and cancel any pending reconnect."
  (when (agent-shell-to-go--ws-reconnect-timer ws)
    (cancel-timer (agent-shell-to-go--ws-reconnect-timer ws))
    (setf (agent-shell-to-go--ws-reconnect-timer ws) nil))
  (when (agent-shell-to-go--ws-websocket ws)
    (setf (agent-shell-to-go--ws-intentional-close ws) t)
    (ignore-errors
      (websocket-close (agent-shell-to-go--ws-websocket ws)))
    (setf (agent-shell-to-go--ws-websocket ws) nil)
    (setf (agent-shell-to-go--ws-intentional-close ws) nil)))

(defun agent-shell-to-go--ws-connected-p (ws)
  "Return non-nil if WS has an open connection."
  (let ((sock (and ws (agent-shell-to-go--ws-websocket ws))))
    (and sock (websocket-openp sock))))

; Slash command arg schemas

(defconst agent-shell-to-go--slash-command-schemas
  '(("/new-agent" (:folder string :container-p nil))
    ("/new-agent-container" (:folder string :container-p t-literal))
    ("/new-project" (:project-name string))
    ("/projects" ()))
  "Per-command arg schemas for transports that need to parse text args.
Each entry is (COMMAND . SCHEMA).  Transports consult this when
converting raw text to a typed args plist for the slash-command hook.")

(defun agent-shell-to-go--parse-slash-args (command text)
  "Parse TEXT into a typed args plist for COMMAND using the schema.
Returns nil if no schema is found; the caller keeps :args-text either way."
  (let ((_schema (cadr (assoc command agent-shell-to-go--slash-command-schemas)))
        (text (and text (string-trim text))))
    (pcase command
      ("/new-agent"
       (list :folder (and text (not (string-empty-p text)) text) :container-p nil))
      ("/new-agent-container"
       (list :folder (and text (not (string-empty-p text)) text) :container-p t))
      ("/new-project" (list :project-name (and text (not (string-empty-p text)) text)))
      ("/projects" nil)
      (_ nil))))

(provide 'agent-shell-to-go-core)
;;; agent-shell-to-go-core.el ends here
