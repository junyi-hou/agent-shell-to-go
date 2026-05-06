# Slack Setup

Steps to set up the Slack transport for `agent-shell-to-go`.

## Security

No one can interact with your agents until you explicitly set an allowlist. Limit workspace membership to just you and your agents.

### Authorized Users (required)

You **must** set an allowlist of Slack user IDs who can interact with your agents:

```elisp
(setq agent-shell-to-go-slack-authorized-users '("U01234567" "U89ABCDEF"))
```

Without this, all Slack interactions are silently ignored. To find your user ID: click your profile → three dots → "Copy member ID".

Unauthorized users cannot send messages, use reactions, or run slash commands.

### What authorized users can do

- Send prompts to agents running on your machine
- Approve permission requests (file edits, command execution, etc.)
- Start new agent sessions via slash commands

### Additional recommendations

- **Run in a VM** — limits blast radius if an agent is tricked into running malicious commands
- **Run risky agents in containers** — use `/new-agent-container` for untrusted code
- **Limit workspace membership** — only invite trusted people; the allowlist protects you, but defense in depth is wise
- **Opt out of Slack's ML training** — Workspace Owners can email `feedback@slack.com` with subject "Slack Global model opt-out request" and your workspace URL. See [Slack's privacy principles](https://slack.com/trust/data-management/privacy-principles).
- Keep your Slack tokens secure (treat them like SSH keys)

## 1. Create a Slack App

### Quick setup (recommended)

1. Go to https://api.slack.com/apps
2. Click "Create New App" → "From an app manifest"
3. Select your workspace
4. Paste the contents of [`slack-app-manifest.yaml`](slack-app-manifest.yaml)
5. Click "Create"
6. Go to "OAuth & Permissions" → "Install to Workspace" → copy the Bot Token (`xoxb-...`)
7. Go to "Basic Information" → "App-Level Tokens" → "Generate Token" with `connections:write` scope → copy it (`xapp-...`)
8. Get your channel ID (right-click channel → "View channel details" → scroll to bottom)
9. Invite the bot to your channel: `/invite @agent-shell-to-go`

Skip to [Configure credentials](#2-configure-credentials).

### Manual setup

<details>
<summary>Click to expand step-by-step guide</summary>

1. **Create the app**
   - Go to https://api.slack.com/apps
   - Click "Create New App" → "From scratch"
   - Name it something like "agent-shell-to-go"
   - Select your workspace

2. **Enable Socket Mode**
   - In the sidebar, click "Socket Mode"
   - Toggle "Enable Socket Mode" ON
   - When prompted, create an app-level token named "websocket" with the `connections:write` scope
   - **Save this token** (starts with `xapp-`)

3. **Add Bot Token Scopes**
   - In the sidebar, click "OAuth & Permissions" → "Scopes" → "Bot Token Scopes"
   - Add: `chat:write`, `channels:history`, `channels:read`, `reactions:read`

4. **Subscribe to Events**
   - In the sidebar, click "Event Subscriptions" → toggle "Enable Events" ON
   - Under "Subscribe to bot events", add:
     - `message.channels`
     - `reaction_added`
     - `reaction_removed`
   - Click "Save Changes"

5. **Add Slash Commands**
   - In the sidebar, click "Slash Commands" and create:
     - `/new-project` — "Create a new project and start an agent"
     - `/new-agent` — "Start new agent in a folder"
     - `/new-agent-container` — "Start new agent in a container"
     - `/projects` — "List open projects from Emacs"

6. **Install the App**
   - Click "Install App" → "Install to Workspace" → "Allow"
   - Copy the **Bot User OAuth Token** (starts with `xoxb-`)

7. **Set up your channel**
   - Create or use an existing channel (e.g., `#agent-shell`)
   - Invite the bot: `/invite @your-bot-name`
   - Get the channel ID: right-click the channel → "View channel details" → scroll to bottom (starts with `C`)

</details>

## 2. Configure credentials

**These credentials are extremely sensitive.** Anyone with these tokens can send messages to your Slack workspace — and your Emacs will execute them as agent-shell prompts. Treat them like SSH keys.

### Option A: Using pass (recommended)

```elisp
(setq agent-shell-to-go-slack-bot-token
      (string-trim (shell-command-to-string "pass slack/agent-shell-bot-token")))
(setq agent-shell-to-go-slack-channel-id
      (string-trim (shell-command-to-string "pass slack/agent-shell-channel-id")))
(setq agent-shell-to-go-slack-app-token
      (string-trim (shell-command-to-string "pass slack/agent-shell-app-token")))
```

### Option B: Using macOS Keychain

```elisp
(defun my/keychain-get (service account)
  (string-trim (shell-command-to-string
                (format "security find-generic-password -s '%s' -a '%s' -w" service account))))

(setq agent-shell-to-go-slack-bot-token     (my/keychain-get "agent-shell-to-go" "bot-token"))
(setq agent-shell-to-go-slack-channel-id    (my/keychain-get "agent-shell-to-go" "channel-id"))
(setq agent-shell-to-go-slack-app-token     (my/keychain-get "agent-shell-to-go" "app-token"))
(setq agent-shell-to-go-slack-user-id       (my/keychain-get "agent-shell-to-go" "user-id"))
```

To add credentials to Keychain:
```bash
security add-generic-password -s "agent-shell-to-go" -a "bot-token" -w "xoxb-your-token"
security add-generic-password -s "agent-shell-to-go" -a "channel-id" -w "C0123456789"
security add-generic-password -s "agent-shell-to-go" -a "app-token" -w "xapp-your-token"
security add-generic-password -s "agent-shell-to-go" -a "user-id" -w "U0123456789"
```

### Option C: Using .env file (less secure)

Create a `.env` file (default: `~/.doom.d/.env`):

```
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_CHANNEL_ID=C0123456789
SLACK_APP_TOKEN=xapp-your-app-token
```

Make sure this file is gitignored if your config is in a repository.

## 3. Add to your Emacs config

```elisp
(use-package agent-shell-to-go
  :load-path "~/code/agent-shell-to-go"
  :after agent-shell
  :config
  (setq agent-shell-to-go-slack-authorized-users '("U01234567"))
  (agent-shell-to-go-setup))
```

Requires the `websocket` package (available on MELPA).

## Usage

Once set up, every new agent-shell session automatically creates a Slack thread and mirrors your conversation bidirectionally.

### In-thread commands

Send these in the Slack thread to control the session:

| Command | Description |
|---------|-------------|
| `!yolo` | Bypass all permissions (dangerous!) |
| `!safe` | Accept edits mode |
| `!plan` | Plan mode |
| `!mode` | Show current mode |
| `!stop` | Interrupt the agent |
| `!restart` | Kill and restart agent with transcript |
| `!queue` | Show pending queued messages |
| `!clearqueue` | Clear all pending queued messages |
| `!latest` | Jump to bottom of thread |
| `!debug` | Show session debug info |
| `!help` | Show available commands |

### Slash commands

Use these in the channel (not in threads):

| Command | Description |
|---------|-------------|
| `/new-project <name>` | Create a new project folder and start an agent |
| `/new-agent [folder]` | Start a new agent |
| `/new-agent-container [folder]` | Start a new agent in a container |
| `/projects` | List open projects from Emacs |

### Reactions

**Permission requests:**

| Emoji | Action |
|-------|--------|
| ✅ or 👍 | Allow once |
| 🔓 or ⭐ | Always allow |
| ❌ or 👎 | Reject |

**Message visibility:**

| Emoji | Action |
|-------|--------|
| 🙈 or 🔕 | Hide message (remove to unhide) |
| 👀 | Show ~500 chars (remove to collapse) |
| 📖 | Show full output (remove to collapse) |

**Feedback:**

| Emoji | Action |
|-------|--------|
| 🔖 | Create an org-mode TODO from the message |

Long messages are automatically truncated to 500 characters. Add 👀 to see more, 📖 for the full text.

## Customization

```elisp
;; Change the .env file location
(setq agent-shell-to-go-slack-env-file "~/.config/agent-shell/.env")

;; Default folder for /new-agent when no folder is specified
(setq agent-shell-to-go-default-folder "~/code")

;; Custom function to start agents
(setq agent-shell-to-go-start-agent-function #'my/start-claude-code)

;; Custom function to set up new projects
;; Called with (PROJECT-NAME BASE-DIR CALLBACK), should call CALLBACK with project-dir when done
(setq agent-shell-to-go-new-project-function #'my/new-python-project)

;; Directory for bookmark TODOs (default: ~/org/todo/)
(setq agent-shell-to-go-todo-directory "~/org/todo/")

;; Hide tool call outputs by default (just show ✅/❌)
(setq agent-shell-to-go-show-tool-output nil)
```

## Troubleshooting

### WebSocket keeps disconnecting

If you see repeated `WebSocket closed` / reconnecting messages, Slack is rejecting the connection. Common causes:

1. **Events not enabled** — Slack app settings → "Event Subscriptions" → toggle "Enable Events" ON
2. **Missing event subscriptions** — verify `message.channels`, `reaction_added`, `reaction_removed` are subscribed
3. **App token expired** — regenerate in "Basic Information" → "App-Level Tokens"

Enable debug logging to investigate:
```elisp
(setq agent-shell-to-go-debug t)
```
Check the `*agent-shell-to-go-debug*` buffer (`M-x agent-shell-to-go-show-debug-log`).

### Slack disabled the app / events not arriving

1. Go to Slack app settings → "Event Subscriptions" → re-enable events
2. Reconnect the websocket in Emacs:
   ```elisp
   (agent-shell-to-go-transport-connect (agent-shell-to-go-get-transport 'slack))
   ```

The existing connection becomes stale when Slack disables/re-enables events.

### Claude Code: OAuth token expired

If agents show `Authentication required` errors, the Claude CLI's OAuth token needs refreshing. Run `claude setup-token` in a terminal to get a long-lived token:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

Or persist it for Emacs:
```elisp
(setenv "CLAUDE_CODE_OAUTH_TOKEN"
        (string-trim (with-temp-buffer
                       (insert-file-contents "~/.ssh/claude-oauth-token")
                       (buffer-string))))
```

### Agent gets stuck when writing to new directories

Doom Emacs prompts `y-or-n-p` before creating missing directories. Override it:

```elisp
(advice-add 'doom-create-missing-directories-h :override
            (lambda ()
              (unless (file-remote-p buffer-file-name)
                (let ((parent-directory (file-name-directory buffer-file-name)))
                  (when (and parent-directory (not (file-directory-p parent-directory)))
                    (make-directory parent-directory 'parents)
                    t)))))
```

## Message Limits

Slack's free tier keeps 90 days of message history. Consider a paid workspace to avoid losing history.

Bulk message deletion is not supported by the Slack API. Use `M-x agent-shell-to-go-cleanup-old-threads` to delete old threads one by one.
