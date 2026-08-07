#!/usr/bin/env bash
# Custom dracula plugin: shows the active pane's docker-compose project state
# (up/down/partial), plus aggregate Docker container count, RAM usage and
# disk usage. Hides itself (no output) when Docker isn't installed, the
# daemon isn't reachable, or there's simply nothing to report.

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$current_dir/utils.sh"

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || exit 0

# Report whether the active pane's directory is a docker-compose project,
# and if so whether it's fully up, fully down, or partially up. Not cached
# like the stats below: `compose ps` only touches one project, so it's
# cheap, and caching it would show stale state after `cd`-ing between panes.
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

compose_indicator=""
if docker compose version >/dev/null 2>&1; then
  pane_dir="$(getActivePaneDir)"
  if [[ -n "$pane_dir" ]] && compose_file="$(findComposeFile "$pane_dir")"; then
    # grep -c . (not wc -l): compose prints a single blank line, not zero
    # bytes, when a --services query matches nothing, which wc -l counts
    # as 1 line.
    service_count="$(docker compose -f "$compose_file" config --services 2>/dev/null | grep -c .)"
    running_count="$(docker compose -f "$compose_file" ps --services --filter status=running 2>/dev/null | grep -c .)"

    if [[ "$service_count" -gt 0 ]]; then
      # Dracula palette fg colors; reset matches @dracula-custom-plugin-colors'
      # fg (dark_gray, #282a36) so text returns to the segment's normal color.
      if [[ "$running_count" -eq 0 ]]; then
        compose_indicator="#[fg=#ff5555]○ down#[fg=#282a36]"
      elif [[ "$running_count" -eq "$service_count" ]]; then
        compose_indicator="#[fg=#50fa7b]● up#[fg=#282a36]"
      else
        compose_indicator="#[fg=#ffb86c]◐ ${running_count}/${service_count}#[fg=#282a36]"
      fi
    fi
  fi
fi

# `docker stats` and `docker system df` are both slow (100s of ms, one
# daemon round-trip per container for stats), so cache them together
# for 5 minutes.
cache_ttl="300"
cache_dir="/tmp/dracula-docker-cache-${USER}"
mkdir -p "$cache_dir" 2>/dev/null
cache_file="$cache_dir/stats"
now="$(date +%s)"
cache_mtime="$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)"

if [[ -f "$cache_file" && $((now - cache_mtime)) -lt "$cache_ttl" ]]; then
  read -r running_containers memory_usage_gb disk_usage_gb <"$cache_file"
else
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
fi

parts=()
[[ -n "$compose_indicator" ]] && parts+=("$compose_indicator")
[[ "$running_containers" -gt 0 ]] && parts+=("🐳 ${running_containers}")
awk -v v="$memory_usage_gb" 'BEGIN{exit !(v>0)}' && parts+=("🧠 ${memory_usage_gb}GB")

# Disk usage isn't actionable on its own (cached images/volumes persist
# regardless of what's running) -- only show it alongside 🐳/🧠.
if [[ ${#parts[@]} -gt 0 ]]; then
  awk -v v="$disk_usage_gb" 'BEGIN{exit !(v>0)}' && parts+=("💾 ${disk_usage_gb}GB")
fi

[[ ${#parts[@]} -eq 0 ]] && exit 0

output="${parts[0]}"
for part in "${parts[@]:1}"; do
  output+=" · ${part}"
done
echo "$output"
