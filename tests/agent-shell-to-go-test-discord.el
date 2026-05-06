;;; agent-shell-to-go-test-discord.el --- Tests for agent-shell-to-go-discord.el -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for functions defined in agent-shell-to-go-discord.el.
;; Tests cover pure helpers, formatting methods, and hook-firing normalization
;; paths without requiring a real Discord backend or WebSocket connection.
;;
;; Run:
;;   emacsclient -e '(load-file "tests/agent-shell-to-go-test-discord.el")'
;;   emacsclient -e '(ert-run-tests-batch "^agent-shell-to-go-test-discord-")'

;;; Code:

(require 'ert)

(let ((root (expand-file-name ".." (file-name-directory
                                    (or load-file-name buffer-file-name ".")))))
  (add-to-list 'load-path root))

(require 'agent-shell-to-go-discord)

;; ---------------------------------------------------------------------------
;; Helpers

(defun agent-shell-to-go-test-discord--make ()
  "Return a fresh Discord transport with a known bot-user-id cached."
  (let ((tr (agent-shell-to-go--make-discord-transport :name 'discord)))
    (setf (agent-shell-to-go-discord-transport-bot-user-id-cache tr) "BOT123")
    tr))

;; ---------------------------------------------------------------------------
;; Emoji-to-action mapping

(ert-deftest agent-shell-to-go-test-discord-emoji-to-action-known ()
  "Registered emoji names map to the correct canonical action."
  (should (eq 'hide (agent-shell-to-go--discord-emoji-to-action "see_no_evil")))
  (should (eq 'hide (agent-shell-to-go--discord-emoji-to-action "no_bell")))
  (should (eq 'expand-truncated (agent-shell-to-go--discord-emoji-to-action "eyes")))
  (should (eq 'expand-full (agent-shell-to-go--discord-emoji-to-action "open_book")))
  (should (eq 'expand-full (agent-shell-to-go--discord-emoji-to-action "green_book")))
  (should (eq 'permission-allow (agent-shell-to-go--discord-emoji-to-action "white_check_mark")))
  (should (eq 'permission-allow (agent-shell-to-go--discord-emoji-to-action "thumbsup")))
  (should (eq 'permission-always (agent-shell-to-go--discord-emoji-to-action "unlock")))
  (should (eq 'permission-always (agent-shell-to-go--discord-emoji-to-action "star")))
  (should (eq 'permission-reject (agent-shell-to-go--discord-emoji-to-action "x")))
  (should (eq 'permission-reject (agent-shell-to-go--discord-emoji-to-action "thumbsdown")))
  (should (eq 'bookmark (agent-shell-to-go--discord-emoji-to-action "bookmark"))))

(ert-deftest agent-shell-to-go-test-discord-emoji-to-action-unknown ()
  "Unregistered emoji names return nil."
  (should (null (agent-shell-to-go--discord-emoji-to-action "unknown_emoji")))
  (should (null (agent-shell-to-go--discord-emoji-to-action "")))
  (should (null (agent-shell-to-go--discord-emoji-to-action nil))))

;; ---------------------------------------------------------------------------
;; Content truncation

(ert-deftest agent-shell-to-go-test-discord-truncate-content-short ()
  "Short text passes through unchanged."
  (should (equal "hello world"
                 (agent-shell-to-go--discord-truncate-content "hello world")))
  (should (equal ""
                 (agent-shell-to-go--discord-truncate-content ""))))

(ert-deftest agent-shell-to-go-test-discord-truncate-content-long ()
  "Text exceeding 2000 chars is truncated with a note appended."
  (let* ((text (make-string 2100 ?a))
         (result (agent-shell-to-go--discord-truncate-content text)))
    (should (<= (length result) agent-shell-to-go--discord-max-content-length))
    (should (string-match-p "truncated" result))))

(ert-deftest agent-shell-to-go-test-discord-truncate-content-exactly-at-limit ()
  "Text exactly at limit is not truncated."
  (let ((text (make-string agent-shell-to-go--discord-max-content-length ?b)))
    (should (equal text (agent-shell-to-go--discord-truncate-content text)))))

;; ---------------------------------------------------------------------------
;; Deduplication

(ert-deftest agent-shell-to-go-test-discord-message-seen-first-time ()
  "A message ID is not seen on first call."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (should (null (agent-shell-to-go--discord-message-seen-p tr "msg-1")))))

(ert-deftest agent-shell-to-go-test-discord-message-seen-second-time ()
  "The same message ID returns t on the second call."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (agent-shell-to-go--discord-message-seen-p tr "msg-dup")
    (should (eq t (agent-shell-to-go--discord-message-seen-p tr "msg-dup")))))

(ert-deftest agent-shell-to-go-test-discord-message-seen-different-ids ()
  "Different IDs are tracked independently."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (agent-shell-to-go--discord-message-seen-p tr "msg-a")
    (should (null (agent-shell-to-go--discord-message-seen-p tr "msg-b")))
    (should (eq t (agent-shell-to-go--discord-message-seen-p tr "msg-a")))))

;; ---------------------------------------------------------------------------
;; Channel resolution

(ert-deftest agent-shell-to-go-test-discord-resolve-channel-top-level ()
  "A channel with no registered parent resolves as top-level."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((result (agent-shell-to-go--discord-resolve-channel tr "CHAN1")))
      (should (equal "CHAN1" (car result)))
      (should (null (cdr result))))))

(ert-deftest agent-shell-to-go-test-discord-resolve-channel-forum-post ()
  "A thread channel whose parent is registered resolves to (parent . thread)."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (puthash "THREAD1" "FORUM1"
             (agent-shell-to-go-discord-transport-thread-parents tr))
    (let ((result (agent-shell-to-go--discord-resolve-channel tr "THREAD1")))
      (should (equal "FORUM1" (car result)))
      (should (equal "THREAD1" (cdr result))))))

;; ---------------------------------------------------------------------------
;; Authorization

(ert-deftest agent-shell-to-go-test-discord-authorized-p-in-list ()
  "A user in the authorized list is authorized."
  (let ((agent-shell-to-go-discord-authorized-users '("U1" "U2")))
    (let ((tr (agent-shell-to-go-test-discord--make)))
      (should (agent-shell-to-go-transport-authorized-p tr "U1"))
      (should (agent-shell-to-go-transport-authorized-p tr "U2")))))

(ert-deftest agent-shell-to-go-test-discord-authorized-p-not-in-list ()
  "A user not in the authorized list is not authorized."
  (let ((agent-shell-to-go-discord-authorized-users '("U1")))
    (let ((tr (agent-shell-to-go-test-discord--make)))
      (should (null (agent-shell-to-go-transport-authorized-p tr "STRANGER"))))))

(ert-deftest agent-shell-to-go-test-discord-authorized-p-empty-list ()
  "When the authorized list is nil, no one is authorized."
  (let ((agent-shell-to-go-discord-authorized-users nil))
    (let ((tr (agent-shell-to-go-test-discord--make)))
      (should (null (agent-shell-to-go-transport-authorized-p tr "U1"))))))

;; ---------------------------------------------------------------------------
;; Formatting methods

(ert-deftest agent-shell-to-go-test-discord-format-tool-call-start ()
  "Tool call start uses a clock emoji and backtick-quoted title."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-tool-call-start tr "read_file")))
      (should (string-match-p "read_file" s))
      (should (string-match-p "⏳" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-tool-call-result-completed ()
  "Completed tool call result uses checkmark."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-tool-call-result
              tr "bash" 'completed "output here")))
      (should (string-match-p "✅" s))
      (should (string-match-p "bash" s))
      (should (string-match-p "output here" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-tool-call-result-failed ()
  "Failed tool call result uses X emoji."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-tool-call-result
              tr "bash" 'failed "error msg")))
      (should (string-match-p "❌" s))
      (should (string-match-p "error msg" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-tool-call-result-no-output ()
  "Tool call result with no output omits the code block."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-tool-call-result
              tr "bash" 'completed nil)))
      (should (string-match-p "bash" s))
      (should (not (string-match-p "```" s))))))

(ert-deftest agent-shell-to-go-test-discord-format-user-message ()
  "User message format includes the person emoji and text."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-user-message tr "hello there")))
      (should (string-match-p "👤" s))
      (should (string-match-p "hello there" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-agent-message ()
  "Agent message format includes the robot emoji and text."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-agent-message tr "I am a robot")))
      (should (string-match-p "🤖" s))
      (should (string-match-p "I am a robot" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-markdown-passthrough ()
  "Markdown formatter returns the input unchanged (Discord uses CommonMark)."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (should (equal "**bold** _italic_"
                   (agent-shell-to-go-transport-format-markdown tr "**bold** _italic_")))))

(ert-deftest agent-shell-to-go-test-discord-format-diff-empty ()
  "When old and new are identical, the diff block is empty."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-diff tr "same" "same")))
      (should (equal "" s)))))

(ert-deftest agent-shell-to-go-test-discord-format-diff-has-changes ()
  "When text differs, a diff block with ```diff fences is returned."
  (let ((tr (agent-shell-to-go-test-discord--make)))
    (let ((s (agent-shell-to-go-transport-format-diff tr "old line" "new line")))
      (should (string-match-p "```diff" s))
      (should (string-match-p "```" s)))))

;; ---------------------------------------------------------------------------
;; normalize-message hook firing

(ert-deftest agent-shell-to-go-test-discord-normalize-message-fires-hook ()
  "normalize-message fires agent-shell-to-go-message-hook for authorized users."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-message-hook
          (list (lambda (plist)
                  (setq received plist)))))
    (agent-shell-to-go--discord-normalize-message
     tr `((id . "M1") (channel_id . "C1")
          (author . ((id . "USER1") (bot . :json-false)))
          (content . "hello")))
    (should received)
    (should (equal "USER1" (plist-get received :user)))
    (should (equal "hello" (plist-get received :text)))
    (should (equal "M1" (plist-get received :msg-id)))))

(ert-deftest agent-shell-to-go-test-discord-normalize-message-ignores-bot ()
  "normalize-message ignores messages from bots."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-message-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-message
     tr `((id . "M1") (channel_id . "C1")
          (author . ((id . "USER1") (bot . t)))
          (content . "bot message")))
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-message-ignores-own-bot-id ()
  "normalize-message ignores messages from the transport's own bot user."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("BOT123"))
         (received nil)
         (agent-shell-to-go-message-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-message
     tr `((id . "M1") (channel_id . "C1")
          (author . ((id . "BOT123") (bot . :json-false)))
          (content . "echo")))
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-message-ignores-unauthorized ()
  "normalize-message ignores messages from unauthorized users."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("ALLOWED"))
         (received nil)
         (agent-shell-to-go-message-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-message
     tr `((id . "M1") (channel_id . "C1")
          (author . ((id . "STRANGER") (bot . :json-false)))
          (content . "intruder")))
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-message-deduplicates ()
  "normalize-message fires the hook only once for a given message ID."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (count 0)
         (agent-shell-to-go-message-hook
          (list (lambda (_plist) (setq count (1+ count))))))
    (let ((payload `((id . "DUP-ID") (channel_id . "C1")
                     (author . ((id . "USER1") (bot . :json-false)))
                     (content . "dup"))))
      (agent-shell-to-go--discord-normalize-message tr payload)
      (agent-shell-to-go--discord-normalize-message tr payload))
    (should (= 1 count))))

(ert-deftest agent-shell-to-go-test-discord-normalize-message-resolves-thread ()
  "normalize-message uses the parent forum channel when message is in a thread."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-message-hook
          (list (lambda (plist) (setq received plist)))))
    (puthash "THREAD1" "FORUM1"
             (agent-shell-to-go-discord-transport-thread-parents tr))
    (agent-shell-to-go--discord-normalize-message
     tr `((id . "M2") (channel_id . "THREAD1")
          (author . ((id . "USER1") (bot . :json-false)))
          (content . "in thread")))
    (should (equal "FORUM1" (plist-get received :channel)))
    (should (equal "THREAD1" (plist-get received :thread-id)))))

;; ---------------------------------------------------------------------------
;; normalize-reaction hook firing

(ert-deftest agent-shell-to-go-test-discord-normalize-reaction-fires-hook ()
  "normalize-reaction fires the reaction hook for authorized users."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-reaction-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-reaction
     tr `((channel_id . "C1") (message_id . "M1")
          (user_id . "USER1")
          (emoji . ((name . "eyes"))))
     t)
    (should received)
    (should (eq 'expand-truncated (plist-get received :action)))
    (should (equal "eyes" (plist-get received :raw-emoji)))
    (should (eq t (plist-get received :added-p)))))

(ert-deftest agent-shell-to-go-test-discord-normalize-reaction-removed ()
  "normalize-reaction passes added-p nil for reaction remove events."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-reaction-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-reaction
     tr `((channel_id . "C1") (message_id . "M1")
          (user_id . "USER1")
          (emoji . ((name . "bookmark"))))
     nil)
    (should (null (plist-get received :added-p)))))

(ert-deftest agent-shell-to-go-test-discord-normalize-reaction-ignores-bot ()
  "normalize-reaction ignores reactions from the bot's own user ID."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("BOT123"))
         (received nil)
         (agent-shell-to-go-reaction-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-reaction
     tr `((channel_id . "C1") (message_id . "M1")
          (user_id . "BOT123")
          (emoji . ((name . "heart"))))
     t)
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-reaction-unknown-emoji ()
  "normalize-reaction still fires hook with nil action for unmapped emoji."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-reaction-hook
          (list (lambda (plist) (setq received plist)))))
    (agent-shell-to-go--discord-normalize-reaction
     tr `((channel_id . "C1") (message_id . "M1")
          (user_id . "USER1")
          (emoji . ((name . "dancing_penguin"))))
     t)
    (should received)
    (should (null (plist-get received :action)))
    (should (equal "dancing_penguin" (plist-get received :raw-emoji)))))

;; ---------------------------------------------------------------------------
;; normalize-interaction hook firing

(ert-deftest agent-shell-to-go-test-discord-normalize-interaction-fires-hook ()
  "normalize-interaction fires slash-command hook for authorized users."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-slash-command-hook
          (list (lambda (plist) (setq received plist)))))
    ;; Stub acknowledge so it does not hit the network
    (cl-letf (((symbol-function 'agent-shell-to-go-transport-acknowledge-interaction)
               (lambda (&rest _) nil)))
      (agent-shell-to-go--discord-normalize-interaction
       tr `((id . "INT1") (token . "TOK1") (type . 2)
            (channel_id . "C1")
            (member . ((user . ((id . "USER1")))))
            (data . ((name . "new-agent")
                     (options . [((name . "folder") (value . "~/code"))]))))))
    (should received)
    (should (equal "/new-agent" (plist-get received :command)))
    (should (equal "~/code" (plist-get received :args-text)))))

(ert-deftest agent-shell-to-go-test-discord-normalize-interaction-ignores-unauthorized ()
  "normalize-interaction does not fire hook for unauthorized users."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("ALLOWED"))
         (received nil)
         (agent-shell-to-go-slash-command-hook
          (list (lambda (plist) (setq received plist)))))
    (cl-letf (((symbol-function 'agent-shell-to-go-transport-acknowledge-interaction)
               (lambda (&rest _) nil)))
      (agent-shell-to-go--discord-normalize-interaction
       tr `((id . "INT2") (token . "TOK2") (type . 2)
            (channel_id . "C1")
            (member . ((user . ((id . "STRANGER")))))
            (data . ((name . "new-agent") (options . []))))))
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-interaction-ignores-non-command ()
  "normalize-interaction ignores non-APPLICATION_COMMAND interaction types."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (received nil)
         (agent-shell-to-go-slash-command-hook
          (list (lambda (plist) (setq received plist)))))
    (cl-letf (((symbol-function 'agent-shell-to-go-transport-acknowledge-interaction)
               (lambda (&rest _) nil)))
      (agent-shell-to-go--discord-normalize-interaction
       tr `((id . "INT3") (token . "TOK3") (type . 3) ; component interaction, not slash
            (channel_id . "C1")
            (member . ((user . ((id . "USER1")))))
            (data . ((name . "new-agent") (options . []))))))
    (should (null received))))

(ert-deftest agent-shell-to-go-test-discord-normalize-interaction-acknowledges ()
  "normalize-interaction calls acknowledge within the 3-second window."
  (let* ((tr (agent-shell-to-go-test-discord--make))
         (agent-shell-to-go-discord-authorized-users '("USER1"))
         (acknowledged nil)
         (agent-shell-to-go-slash-command-hook nil))
    (cl-letf (((symbol-function 'agent-shell-to-go-transport-acknowledge-interaction)
               (lambda (_tr token &rest _opts)
                 (setq acknowledged token))))
      (agent-shell-to-go--discord-normalize-interaction
       tr `((id . "INT4") (token . "TOK4") (type . 2)
            (channel_id . "C1")
            (member . ((user . ((id . "USER1")))))
            (data . ((name . "projects") (options . []))))))
    (should (equal "INT4:TOK4" acknowledged))))

(provide 'agent-shell-to-go-test-discord)
;;; agent-shell-to-go-test-discord.el ends here
