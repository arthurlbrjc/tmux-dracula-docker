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

  local order
  order="$(resolveOrder "$(get_tmux_option "@dracula-docker-order" "containers compose memory disk")")"

  local compose_indicator=""
  if isComposeIndicatorEnabled && orderHas "$order" "compose"; then
    compose_indicator="$(getComposeIndicator)"
  fi

  local want_containers=0 want_memory=0 want_disk=0
  orderHas "$order" "containers" && want_containers=1
  orderHas "$order" "memory" && want_memory=1
  orderHas "$order" "disk" && want_disk=1

  local running_containers memory_usage_mb disk_usage_mb
  read -r running_containers memory_usage_mb disk_usage_mb \
    <<<"$(getDockerStats "$want_containers" "$want_memory" "$want_disk")"

  printSegment "$order" "$running_containers" "$compose_indicator" "$memory_usage_mb" "$disk_usage_mb"
}

# @dracula-docker-order doubles as an allow-list
resolveOrder() {
  local raw="$1" key seen="" result=()
  for key in $raw; do
    case "$key" in
      containers | compose | memory | disk) ;;
      *) continue ;;
    esac
    [[ " $seen " == *" $key "* ]] && continue
    seen+=" $key"
    result+=("$key")
  done
  echo "${result[@]}"
}

isComposeIndicatorEnabled() {
  [[ "$(get_tmux_option "@dracula-docker-show-compose" "true")" == "true" ]]
}

orderHas() {
  local order="$1" key="$2"
  [[ " $order " == *" $key "* ]]
}

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
# daemon round-trip per container for stats), so results are cached
# together for @dracula-docker-cache-ttl seconds.
getDockerStats() {
  local want_containers="$1" want_memory="$2" want_disk="$3"
  local cache_ttl
  cache_ttl="$(get_tmux_option "@dracula-docker-cache-ttl" "300")"
  local cache_dir="/tmp/dracula-docker-cache-${USER}"
  mkdir -p "$cache_dir" 2>/dev/null
  local cache_file="$cache_dir/stats"
  local now cache_mtime
  now="$(date +%s)"
  cache_mtime="$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)"

  if [[ -f "$cache_file" && $((now - cache_mtime)) -lt "$cache_ttl" ]]; then
    local cached_containers cached_memory cached_disk
    read -r cached_containers cached_memory cached_disk <"$cache_file"
    if isStatSatisfied "$want_containers" "$cached_containers" &&
      isStatSatisfied "$want_memory" "$cached_memory" &&
      isStatSatisfied "$want_disk" "$cached_disk"; then
      echo "$cached_containers $cached_memory $cached_disk"
      return 0
    fi
  fi

  local running_containers="-" memory_usage_mb="-" disk_usage_mb="-"
  [[ "$want_containers" -eq 1 ]] && running_containers="$(countRunningContainers)"
  [[ "$want_memory" -eq 1 ]] && memory_usage_mb="$(sumContainerMemoryMb)"
  [[ "$want_disk" -eq 1 ]] && disk_usage_mb="$(sumDockerDiskMb)"

  echo "$running_containers $memory_usage_mb $disk_usage_mb" >"$cache_file"
  echo "$running_containers $memory_usage_mb $disk_usage_mb"
}

printSegment() {
  local order="$1" running_containers="$2" compose_indicator="$3" memory_usage_mb="$4" disk_usage_mb="$5"

  local main_label containers_label memory_label disk_label
  main_label="$(get_tmux_option "@dracula-docker-main-label" "🐳")"
  containers_label="$(get_tmux_option "@dracula-docker-label-containers" "📦")"
  memory_label="$(get_tmux_option "@dracula-docker-label-memory" "🧠")"
  disk_label="$(get_tmux_option "@dracula-docker-label-disk" "💾")"

  local containers_part="" memory_part="" disk_part=""
  [[ "$running_containers" != "-" && "$running_containers" -gt 0 ]] && containers_part="$running_containers"
  [[ "$memory_usage_mb" != "-" && "$memory_usage_mb" -gt 0 ]] && memory_part="${memory_label} $(formatSize "$memory_usage_mb")"

  # Disk usage isn't actionable on its own (cached images/volumes persist
  # regardless of what's running) -- only show it alongside containers/memory/compose state.
  if [[ -n "$containers_part" || -n "$compose_indicator" || -n "$memory_part" ]]; then
    [[ "$disk_usage_mb" != "-" && "$disk_usage_mb" -gt 0 ]] && disk_part="${disk_label} $(formatSize "$disk_usage_mb")"
  fi

  # main_label (the whale, by default) always leads so the segment
  # reads as Docker's regardless of @dracula-docker-order.
  # containers_label only decorates the count when something else already
  # leads
  local parts=() first_part_added=0 containers_leads=0
  local key part
  for key in $order; do
    part=""
    case "$key" in
      containers)
        if [[ -n "$containers_part" ]]; then
          if [[ "$first_part_added" -eq 0 ]]; then
            part="$containers_part"
            containers_leads=1
          else
            part="${containers_label} ${containers_part}"
          fi
        fi
        ;;
      compose) part="$compose_indicator" ;;
      memory) part="$memory_part" ;;
      disk) part="$disk_part" ;;
    esac
    [[ -z "$part" ]] && continue
    parts+=("$part")
    first_part_added=1
  done

  [[ ${#parts[@]} -eq 0 ]] && exit 0

  local output rest=("${parts[@]}")
  if [[ "$containers_leads" -eq 1 ]]; then
    output="${main_label} ${parts[0]}"
    rest=("${parts[@]:1}")
  else
    output="$main_label"
  fi

  for part in "${rest[@]}"; do
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

# Resolve the reset color the same way dracula.sh does
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

isStatSatisfied() {
  local wanted="$1" cached_value="$2"
  [[ "$wanted" -eq 0 || "$cached_value" != "-" ]]
}

countRunningContainers() {
  docker ps -q | wc -l | tr -d ' '
}

sumContainerMemoryMb() {
  docker stats --no-stream --format "{{.MemUsage}}" 2>/dev/null | awk -F'/' '{
    memory = $1
    if (memory ~ /GiB/) {
      gsub(/GiB/, "", memory)
      sum += memory*1024
    } else if (memory ~ /MiB/) {
      gsub(/MiB/, "", memory)
      sum += memory
    } else if (memory ~ /KiB/) {
      gsub(/KiB/, "", memory)
      sum += memory/1024
    }
  } END {printf "%.0f", sum}'
}

sumDockerDiskMb() {
  docker system df --format "{{.Size}}" 2>/dev/null | awk '{
    if ($0 ~ /GB/) {
      gsub(/GB/, "", $0)
      sum += $0*1024
    } else if ($0 ~ /MB/) {
      gsub(/MB/, "", $0)
      sum += $0
    } else if ($0 ~ /KB/) {
      gsub(/KB/, "", $0)
      sum += $0/1024
    }
  } END {printf "%.0f", sum}'
}

formatSize() {
  local value_mb="$1"
  awk -v mb="$value_mb" 'BEGIN {
    if (mb >= 1024) {
      printf "%.1fGB", mb/1024
    } else {
      printf "%.0fMB", mb
    }
  }'
}

main "$@"
