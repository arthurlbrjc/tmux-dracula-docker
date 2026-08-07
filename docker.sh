#!/usr/bin/env bash
# Custom dracula plugin: shows the active pane's docker-compose project state
# (up/down/partial), plus aggregate Docker container count, RAM usage and
# disk usage. Hides itself (no output) when Docker isn't installed, the
# daemon isn't reachable, or there's simply nothing to report.

export LC_ALL=en_US.UTF-8

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$current_dir/utils.sh"

main() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || exit 0

  local compose_indicator
  if isComposeIndicatorEnabled; then
    compose_indicator="$(getComposeIndicator)"
  fi

  local running_containers memory_usage_gb disk_usage_gb
  read -r running_containers memory_usage_gb disk_usage_gb <<<"$(getDockerStats)"

  printSegment "$running_containers" "$compose_indicator" "$memory_usage_gb" "$disk_usage_gb"
}

# Lets users opt out of the compose-project indicator, e.g. if they don't
# use docker-compose or don't want a per-pane `docker compose` query on
# every status-bar refresh.
isComposeIndicatorEnabled() {
  [[ "$(get_tmux_option "@dracula-docker-show-compose" "true")" == "true" ]]
}

# Report whether the active pane's directory is a docker-compose project,
# and if so whether it's fully up, fully down, or partially up. Not cached
# like the stats below: `compose ps` only touches one project, so it's
# cheap, and caching it would show stale state after `cd`-ing between panes.
getComposeIndicator() {
  docker compose version >/dev/null 2>&1 || return 0

  local pane_dir compose_file
  pane_dir="$(getActivePaneDir)"
  [[ -n "$pane_dir" ]] || return 0
  compose_file="$(findComposeFile "$pane_dir")" || return 0

  # grep -c . (not wc -l): compose prints a single blank line, not zero
  # bytes, when a --services query matches nothing, which wc -l counts
  # as 1 line.
  local service_count running_count
  service_count="$(docker compose -f "$compose_file" config --services 2>/dev/null | grep -c .)"
  running_count="$(docker compose -f "$compose_file" ps --services --filter status=running 2>/dev/null | grep -c .)"
  [[ "$service_count" -gt 0 ]] || return 0

  local reset_fg
  reset_fg="$(getResetFg)"

  if [[ "$running_count" -eq 0 ]]; then
    echo "#[fg=#ff5555]○ down#[fg=${reset_fg}]"
  elif [[ "$running_count" -eq "$service_count" ]]; then
    echo "#[fg=#50fa7b]● up#[fg=${reset_fg}]"
  else
    echo "#[fg=#ffb86c]◐ ${running_count}/${service_count}#[fg=${reset_fg}]"
  fi
}

# `docker stats` and `docker system df` are both slow (100s of ms, one
# daemon round-trip per container for stats), so cache them together
# for 5 minutes. Prints "running_containers memory_usage_gb disk_usage_gb".
getDockerStats() {
  local cache_ttl
  cache_ttl="$(get_tmux_option "@dracula-docker-cache-ttl" "300")"
  local cache_dir="/tmp/dracula-docker-cache-${USER}"
  mkdir -p "$cache_dir" 2>/dev/null
  local cache_file="$cache_dir/stats"
  local now cache_mtime
  now="$(date +%s)"
  cache_mtime="$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)"

  if [[ -f "$cache_file" && $((now - cache_mtime)) -lt "$cache_ttl" ]]; then
    cat "$cache_file"
    return 0
  fi

  local running_containers memory_usage_gb disk_usage_gb
  running_containers="$(docker ps -q | wc -l | tr -d ' ')"

  memory_usage_gb="$(docker stats --no-stream --format "{{.MemUsage}}" 2>/dev/null | awk -F'/' '{
    memory = $1
    if (memory ~ /GiB/) {
      gsub(/GiB/, "", memory)
      sum += memory
    } else if (memory ~ /MiB/) {
      gsub(/MiB/, "", memory)
      sum += memory/1024
    } else if (memory ~ /KiB/) {
      gsub(/KiB/, "", memory)
      sum += memory/1024/1024
    }
  } END {printf "%.1f", sum}')"

  disk_usage_gb="$(docker system df --format "{{.Size}}" 2>/dev/null | awk '{
    if ($0 ~ /GB/) {
      gsub(/GB/, "", $0)
      sum += $0
    } else if ($0 ~ /MB/) {
      gsub(/MB/, "", $0)
      sum += $0/1024
    } else if ($0 ~ /KB/) {
      gsub(/KB/, "", $0)
      sum += $0/1024/1024
    }
  } END {printf "%.1f", sum}')"

  echo "$running_containers $memory_usage_gb $disk_usage_gb" >"$cache_file"
  echo "$running_containers $memory_usage_gb $disk_usage_gb"
}

printSegment() {
  local running_containers="$1" compose_indicator="$2" memory_usage_gb="$3" disk_usage_gb="$4"

  local parts=()
  if [[ "$running_containers" -gt 0 ]]; then
    parts+=("🐳 ${running_containers}")
  elif [[ -n "$compose_indicator" ]]; then
    parts+=("🐳")
  fi
  [[ -n "$compose_indicator" ]] && parts+=("$compose_indicator")
  isPositive "$memory_usage_gb" && parts+=("🧠 ${memory_usage_gb}GB")

  # Disk usage isn't actionable on its own (cached images/volumes persist
  # regardless of what's running) -- only show it alongside 🐳/🧠/compose state.
  if [[ ${#parts[@]} -gt 0 ]]; then
    isPositive "$disk_usage_gb" && parts+=("💾 ${disk_usage_gb}GB")
  fi

  [[ ${#parts[@]} -eq 0 ]] && exit 0

  local output="${parts[0]}"
  for part in "${parts[@]:1}"; do
    output+=" · ${part}"
  done
  echo "$output"
}

getActivePaneDir() {
  tmux display-message -p "#{pane_current_path}"
}

findComposeFile() {
  local dir="$1"
  for name in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$dir/$name" ]] && echo "$dir/$name" && return 0
  done
  return 1
}

# Resolve the reset color the same way dracula.sh does: start from its
# default palette, apply the user's @dracula-colors override (if any) with
# the same eval mechanism, then look up @dracula-custom-plugin-colors' fg
# (default "dark_gray") by name. A hardcoded #282a36 reset would fight a
# themed @dracula-colors override (Catppuccin/Gruvbox/etc).
getResetFg() {
  local white="#f8f8f2" gray="#44475a" dark_gray="#282a36" light_purple="#bd93f9"
  local dark_purple="#6272a4" cyan="#8be9fd" green="#50fa7b" orange="#ffb86c"
  local red="#ff5555" purple="#b166cc" pink="#ff79c6" yellow="#f1fa8c"
  local user_colors
  user_colors="$(get_tmux_option "@dracula-colors" "")"
  [[ -n "$user_colors" ]] && eval "$user_colors"
  local plugin_colors
  IFS=' ' read -r -a plugin_colors <<<"$(get_tmux_option "@dracula-custom-plugin-colors" "cyan dark_gray")"
  echo "${!plugin_colors[1]}"
}

isPositive() {
  awk -v v="$1" 'BEGIN{exit !(v>0)}'
}

main "$@"
