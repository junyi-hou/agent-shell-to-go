# agent-shell-to-go

Emacs package that mirrors agent-shell conversations to remote messaging transports (Slack, Discord).

## Dependencies

This project depends on `agent-shell`. Look for the `agent-shell` library using `emacsclient -e '(locate-library "agent-shell")`.

Refrain from using internal functions (with prefix `agent-shell--`) as much as possible.

## Architecture

```
agent-shell-to-go-core.el          shared protocol: defcustoms, utilities, transport
                                   struct/generics, registry, hooks, storage, WS machine
agent-shell-to-go-slack.el         Slack transport implementation
agent-shell-to-go-discord.el       Discord transport implementation
agent-shell-to-go-bridge.el        agent-shell integration (transport-agnostic)
agent-shell-to-go.el               entry point: minor mode + public API
tests/mock-transport.el            mock transport implementation (no tests)
tests/agent-shell-to-go-test-core.el       ERT tests for agent-shell-to-go-core.el
tests/agent-shell-to-go-test-bridge.el     ERT tests for agent-shell-to-go-bridge.el
```

Load order: core → slack/discord/bridge → main.
Slave files `(require 'agent-shell-to-go-core)` directly, so there is no
circular dependency.  `agent-shell-to-go.el` is the user-facing entry point
and requires all four in the conventional top-of-file position.

### Transport protocol (cl-defgeneric in core)

All sends/reads/threads/formatting go through generics dispatched on a
`agent-shell-to-go-transport` struct (a `cl-defstruct`).  Slack and the
test transport each provide `cl-defmethod` implementations.

Key generics:
- Lifecycle: `transport-connect/disconnect/connected-p/authorized-p/bot-user-id`
- Send: `transport-send-text`, `transport-edit-message`, `transport-upload-file`
- Read: `transport-get-message-text`, `transport-get-reactions`, `transport-fetch-thread-replies`
- Threads: `transport-start-thread`, `transport-update-thread-header`, `transport-ensure-project-channel`
- Format: `transport-format-tool-call-start/result/diff/user-message/agent-message/markdown`
- Storage: `transport-storage-root` → `~/.agent-shell/{transport-name}/`

### Inbound hooks (in main)

Three hook variables; transports fire them with normalized plists:

- `agent-shell-to-go-message-hook` `:transport :channel :thread-id :user :text :msg-id`
- `agent-shell-to-go-reaction-hook` `:transport :channel :msg-id :user :action :raw-emoji :added-p`
- `agent-shell-to-go-slash-command-hook` `:transport :command :args :args-text :channel :user :interaction-token`

Reaction `:action` is a canonical symbol from:
`hide expand-truncated expand-full permission-allow permission-always permission-reject heart bookmark`

### Reaction canonicalization (Slack)

`agent-shell-to-go-slack-reaction-map` defcustom maps canonical action symbols
to lists of raw Slack emoji names.

### Hook handler registration

- **main** registers `agent-shell-to-go--handle-presentation-reaction` on the
  reaction hook first.  Presentation actions (hide/expand/collapse) are handled
  entirely here; bridge never sees them.
- **bridge** registers message/reaction/slash handlers.  Reaction handler only
  processes `heart`, `bookmark`, and `permission-*` actions.

## Key State

Buffer-local (in each agent-shell buffer with mirroring on):
- `agent-shell-to-go--transport` — transport struct in use
- `agent-shell-to-go--channel-id` — remote channel id
- `agent-shell-to-go--thread-id` — remote thread id
- `agent-shell-to-go--current-agent-message` — streaming accumulator
- `agent-shell-to-go--from-remote` — prevents echo on injected messages

Global:
- `agent-shell-to-go--active-buffers` — list of live mirrored buffers
- `agent-shell-to-go--pending-permissions` — alist keyed by `(transport-name channel msg-id)`
- `agent-shell-to-go--transports` — hash of registered transport structs

## Debugging

Enable debug logging:
```elisp
(setq agent-shell-to-go-debug t)
```

Debug lines are written to `*agent-shell-to-go-debug*` (timestamped, capped at `agent-shell-to-go-event-log-max-entries`).
Open it with `M-x agent-shell-to-go-show-debug-log`.

Check `*Agent Shell Events*` for the Slack inbound event log.

Use `!debug` in a thread to get session/channel/thread info.

Common issues:
- **Reaction not working**: Check `*agent-shell-to-go-debug*`. Slack emoji names have no colons (e.g. `eyes` not `:eyes:`).
- **Message not expanding**: Check `~/.agent-shell/slack/truncated/CHANNEL/MSG-ID.txt`.
- **UTF-8 issues**: Slack API calls use curl; fallback strips non-ASCII automatically.
- **Thread not found**: `--find-buffer-for-transport-channel-thread` matches transport + channel + thread.

## Running Tests

```shell
emacs -batch \
  -L ~/.emacs.d/elpaca/builds/shell-maker \
  -L ~/.emacs.d/elpaca/builds/acp \
  -L ~/.emacs.d/elpaca/builds/agent-shell \
  -L .
  -L tests/
  -f ert-run-tests-batch-and-exit
```
