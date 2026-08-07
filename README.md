# tmux-dracula-docker

![AI-Generated License Badge](vibe-coded-badge.svg)

A custom "third-party" plugin for the [Dracula tmux](https://github.com/dracula/tmux) theme. It shows Docker state in your tmux status bar:

- The active pane's docker-compose project state (`● up`, `○ down`, or `◐ 3/5` partial)
- Total running container count (🐳)
- Aggregate container RAM usage (🧠)
- Aggregate Docker disk usage (💾)

The segment stays empty when there's nothing to report — no Docker installed, daemon not running, no containers, no compose project in the
active pane.

## Prerequisites

- **tmux** (>= 3.0 recommended)
- **[TPM](https://github.com/tmux-plugins/tpm)** (Tmux Plugin Manager), or another way of installing `dracula/tmux`
- **[dracula/tmux](https://github.com/dracula/tmux)** cloned into your tmux plugin directory (typically `~/.tmux/plugins/tmux` when using
  TPM — TPM names the clone dir after the repo, not the org)
- **Docker** (`docker` CLI + daemon reachable); **Docker Compose** (v2, the `docker compose` subcommand is required)

## Installation

1. Install `dracula/tmux` via TPM if you haven't already. In `~/.tmux.conf`:

   ```tmux
   set -g @plugin 'dracula/tmux'
   ```

   Then press `prefix + I` inside tmux to fetch it.

2. Copy `docker.sh` from this repo into the same directory as `dracula/tmux`'s `utils.sh` and `dracula.sh` — typically:

   ```bash
   git clone https://github.com/arthurlbrjc/tmux-dracula-docker.git
   cp tmux-dracula-docker/docker.sh ~/.tmux/plugins/tmux/scripts/docker.sh
   chmod +x ~/.tmux/plugins/tmux/scripts/docker.sh
   ```

   The script **must** be executable — `dracula.sh` only runs it if `[[ -x ... ]]`; otherwise the status bar shows `"docker.sh not found!"`
   in red.

3. Enable it as a custom plugin in `~/.tmux.conf`, alongside whatever other Dracula plugins you use:

   ```tmux
   set -g @dracula-plugins "custom:docker.sh ..."
   ```

4. Reload your tmux config:

   ```bash
   tmux source-file ~/.tmux.conf
   ```

You should now see the Docker segment in your status bar whenever there's something to report.

## Configuration

| Option                             | Default  | Description                                                     |
|------------------------------------|----------|-----------------------------------------------------------------|
| `@dracula-docker-show-compose`     | `"true"` | Show the compose-project indicator (`● up`, `○ down`, `◐ 3/5`). |
| `@dracula-docker-cache-ttl`        | `"300"`  | Cache TTL (seconds) for container count, RAM, and disk usage.   |
| `@dracula-docker-label-containers` | `"🐳"`   | Label for the running containers count.                         |
| `@dracula-docker-label-memory`     | `"🧠"`   | Label for aggregate RAM usage.                                  |
| `@dracula-docker-label-disk`       | `"💾"`   | Label for aggregate disk usage.                                 |

Everything else is fixed in `docker.sh`.

## How it works

- The compose-project indicator inspects the **active pane's** current directory for a `docker-compose.yml`/`.yaml` or `compose.yml`/`.yaml`
  file, and isn't cached — it's cheap to query and needs to reflect `cd`-ing between panes immediately.
- Container count, RAM, and disk usage come from `docker stats` / `docker system df`, which are slow (one daemon round-trip per container),
  so they're cached (5 minutes by default, see `@dracula-docker-cache-ttl` above) under `/tmp/dracula-docker-cache-${USER}`.
- Segments refresh on tmux's normal status-bar interval (`@dracula-refresh-rate`, default 5s).

## Testing changes locally

There's no test suite. To verify a change:

1. Symlink or copy `docker.sh` (and `utils.sh` from your `dracula/tmux` clone) into the same directory.
2. `chmod +x docker.sh`.
3. Set `@dracula-plugins "custom:docker.sh"` in `tmux.conf`.
4. Reload tmux config and visually confirm the status bar segment.

## 🤖 AI Transparency

This project is made with ai.

- **AI Model**: Claude Sonnet 5
- **License**: MIT

We believe in transparency about AI usage in software development.
