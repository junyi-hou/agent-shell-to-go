# agent-shell-to-go

> **Note:** This project is no longer actively developed. It has been superseded by:
>
> - [acp-mobile](https://github.com/ElleNajt/acp-mobile) - Mobile frontend
> - [acp-multiplex](https://github.com/ElleNajt/acp-multiplex) - Multiplexer backend
>
> There's an [RFD for multiplexing ACP](https://github.com/agentclientprotocol/agent-client-protocol/pull/533); acp-multiplex is an unofficial vibed-out version of it.
>
> The Slack integration (see commit [`28cc372`](https://github.com/ElleNajt/agent-shell-to-go/tree/28cc372)) should probably be ported to an ACP frontend that integrates with the multiplexer; but it makes the most sense to do that after the RFD is merged and protocol fixed.

Take your [agent-shell](https://github.com/xenodium/agent-shell) sessions anywhere. Chat with your AI agents from your phone or any device.

Pairs well with [meta-agent-shell](https://github.com/ElleNajt/meta-agent-shell) for monitoring and coordinating multiple agents.

| Emacs | Slack (message from phone) | Slack (follow-up from Emacs) |
|-------|---------------------------|------------------------------|
| ![Emacs](assets/screenshot-emacs.png) | ![Slack 1](assets/screenshot-slack-1.png) | ![Slack 2](assets/screenshot-slack-2.png) |

## Overview

agent-shell-to-go mirrors your agent-shell conversations to external messaging platforms, enabling bidirectional communication. Send messages from your phone, approve permissions on the go, and monitor your AI agents from anywhere.

Currently supported:
- **Slack** (via Socket Mode)

Planned/possible integrations:
- Matrix
- Discord
- Telegram

## Features

- **Per-project channels** - each project gets its own Slack channel automatically
- Each agent-shell session gets its own thread within the project channel
- Messages flow bidirectionally (Emacs ↔ messaging platform)
- Real-time updates via WebSocket
- **Message queuing** - messages sent while the agent is busy are queued and processed automatically
- Permission requests with reaction-based approval
- Mode switching via commands (`!yolo`, `!safe`, `!plan`)
- Start new agents remotely via slash commands
- **Image uploads** - images created anywhere in the project are automatically uploaded to Slack (requires `fswatch`)
- **Error forwarding** - agent startup failures and API errors are automatically reported to the Slack thread
- Works with any agent-shell agent (Claude Code, Gemini, etc.)

## Setup

- [Slack setup](docs/slack-setup.md) — app creation, credentials, usage, reactions, troubleshooting
- [Discord setup](docs/discord-bot-setup.md) — bot creation, permissions, forum channels, custom emojis

## Roadmap

- [x] Image uploads - images written by the agent are automatically uploaded to Slack
- [x] Bookmarks - bookmark reaction creates org-mode TODO scheduled for today
- [x] Better UTF-8 and unicode handling (now uses curl)
- [x] Per-project channels - each project gets its own Slack channel automatically
- [x] Message queuing - messages sent while agent is busy are queued automatically
- [x] Three-state message expansion - collapsed (icon only), glance (👀, ~500 chars), full read (📖)
- [ ] Cloudflare Worker relay - Slack's Socket Mode requires your laptop to be online; when it sleeps or loses WiFi, Slack accumulates delivery failures and eventually disables the app. A Cloudflare Worker relay would maintain the Slack Socket Mode connection 24/7, queue messages while you're offline, and forward them when Emacs reconnects.
- [ ] Matrix integration
- [ ] Discord integration
- [ ] Telegram integration

## Related Projects

**Pairs well with [meta-agent-shell](https://github.com/ElleNajt/meta-agent-shell)** - A supervisory agent that monitors all your sessions. Search across agents, send messages between them, and manage your fleet of AI agents from Slack.

## License

GPL-3.0
