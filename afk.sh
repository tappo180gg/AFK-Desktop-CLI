#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════
#  afk.sh — Away From Keyboard manager for Linux
#  Usage: afk [reason] [minutes]     afk lunch
#         afk --status               afk --back
#         afk --cancel               afk --stats
#         afk --edit                 afk --clean [days]
#         afk --export               afk --update
#         afk --aliases              afk --config
# ═══════════════════════════════════════════════════════

VERSION="1.4.1"
REPO_RAW="https://github.com/tappo180gg/AFK-Desktop-CLI/blob/main/afk.sh"

CONFIG_DIR="${HOME}/.config/afk"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="${CONFIG_DIR}/history.log"
LOCK_FILE="${CONFIG_DIR}/current.afk"
SEMAPHORE="${CONFIG_DIR}/return.now"
CANCEL_FILE="${CONFIG_DIR}/cancelled"

# ── Default config ─────────────────────────────────────
DEFAULT_REASON="AFK"
DEFAULT_MINUTES=""

COLOR_BORDER="3"      # 0=black 1=red 2=green 3=yellow 4=blue 5=purple 6=cyan 7=white
COLOR_TITLE="6"
COLOR_TEXT="7"
COLOR_RETURN="2"
COLOR_TIMER="3"
SHOW_SLACK="1"
SHOW_DISCORD="0"
LOCK_SCREEN="0"
AUTO_AFK_MINUTES="0"  # 0 = disabled; e.g. 15 = auto-AFK after 15 min of idle

# Quick aliases: alias:Reason:Minutes  (separated by ;)
QUICK_REASONS="lunch:Lunch:60;coffee:Coffee:5;meeting:Meeting:;bathroom:Bathroom:5;phone:Phone:;break:Break:15"

# ── Load user config if exists ─────────────────────────
mkdir -p "$CONFIG_DIR"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Color helpers ──────────────────────────────────────
cc() { printf "\033[${1}m${2}\033[0m"; }
B()  { printf "\033[1m%s\033[0m" "$1"; }

border()    { cc "0;3${COLOR_BORDER}" "$1"; }
title()     { cc "1;3${COLOR_TITLE}" "$1"; }
text()      { cc "0;3${COLOR_TEXT}" "$1"; }
return_c()  { cc "1;3${COLOR_RETURN}" "$1"; }
timer_c()   { cc "1;3${COLOR_TIMER}" "$1"; }
red()       { cc "1;31" "$1"; }
green()     { cc "1;32" "$1"; }
yellow()    { cc "1;33" "$1"; }

# ── UI Functions ───────────────────────────────────────
clear_screen() {
  clear
  tput cup 0 0 2>/dev/null || true
}

draw_line()      { border "╔══════════════════════════════════════════════╗"; echo; }
draw_mid_line()  { border "╠══════════════════════════════════════════════╣"; echo; }
draw_bot_line()  { border "╚══════════════════════════════════════════════╝"; echo; }
draw_row()       { border "║"; printf "  %-44s" "$1"; border "║"; echo; }
draw_kv_row()    { border "║"; printf "  "; title "%-10s" "$1"; printf "%-34s" "$2"; border "║"; echo; }
draw_empty_row() { border "║"; printf "  %-44s" ""; border "║"; echo; }

show_afk_banner() {
  local time="$1" reason="$2" minutes="$3" message="${4:-}"
  clear_screen
  echo
  draw_line
  border "║"; printf "  "; title "💤  AFK — Away From Keyboard"; printf "%-18s" ""; border "║"; echo
  draw_mid_line
  draw_empty_row
  draw_kv_row "Reason:" "$reason"
  draw_kv_row "From:" "$time"
  if [[ -n "$minutes" ]]; then
    local return_time
    return_time=$(date -d "+${minutes} minutes" +"%H:%M" 2>/dev/null)
    draw_kv_row "Back:" "~$return_time (${minutes} min)"
  fi
  if [[ -n "$message" ]]; then
    draw_kv_row "Note:" "$message"
  fi
  draw_empty_row
  draw_bot_line
  echo
  printf "  "; text "Press "; B "Enter"; text " to report your return"; echo
  printf "  "; text "(or "; B "afk --back"; text " from another terminal)"; echo
  echo
}

# ── Desktop notifications ──────────────────────────────
notify() {
  command -v notify-send &>/dev/null || return
  notify-send --urgency="$1" --icon="$2" "$3" "$4" 2>/dev/null
}

notify_afk() {
  local body="Reason: $1 | From $2"
  [[ -n "$3" ]] && body+=" | Back in ${3} min"
  notify normal user-away "AFK — Away From Keyboard" "$body"
}

notify_return() {
  notify normal user-available "Welcome back!" "Returned at $1 (AFK since $2, duration $3)"
}

notify_timer_expired() {
  notify critical appointment-soon "AFK timer expired!" "It was $1 minutes — are you still away?"
}

# ── Lock screen ────────────────────────────────────────
lock_screen_if() {
  [[ "$LOCK_SCREEN" != "1" ]] && return
  if command -v loginctl &>/dev/null; then
    loginctl lock-session 2>/dev/null
  elif command -v xdg-screensaver &>/dev/null; then
    xdg-screensaver lock 2>/dev/null
  elif command -v xset &>/dev/null; then
    xset s activate 2>/dev/null
  fi
}

# ── App status (Slack) ─────────────────────────────────
set_slack_status() {
  local reason="$1"
  [[ "$SHOW_SLACK" != "1" ]] && return
  command -v xdotool &>/dev/null || return

  local slack_win
  slack_win=$(xdotool search --name "Slack" 2>/dev/null | head -1)
  [[ -z "$slack_win" ]] && return

  xdotool windowactivate --sync "$slack_win" 2>/dev/null
  sleep 0.3
  xdotool key --window "$slack_win" ctrl+shift+y 2>/dev/null
  sleep 0.5
  xdotool type --window "$slack_win" --delay 50 "$reason" 2>/dev/null
  sleep 0.3
  xdotool key --window "$slack_win" Return 2>/dev/null
}

# ── Idle detection (auto-AFK) ──────────────────────────
get_idle_ms() {
  if command -v xprintidle &>/dev/null; then
    xprintidle 2>/dev/null
    return
  fi
  local idle_file="/tmp/.X11-unix"
  if [[ -d "$idle_file" ]]; then
    local xdisplay="${DISPLAY:-:0}"
    local xss_info
    xss_info=$(xdotool getactivewindow getwindowfocus 2>/dev/null)
    if command -v xset &>/dev/null; then
      xset q 2>/dev/null | grep "timeout" | awk '{print $2}'
      return
    fi
  fi
  echo "0"
}

get_idle_min() {
  local idle_ms
  idle_ms=$(get_idle_ms)
  echo $(( idle_ms / 60000 ))
}

# ── Lock file (current AFK status) ────────────────────
write_lock() {
  echo "$$|$(date +%s)|$(date +%H:%M)|${1}|${2:-}|${3:-}" > "$LOCK_FILE"
}

read_lock() {
  [[ -f "$LOCK_FILE" ]] || return 1
  IFS='|' read -r LOCK_PID LOCK_EPOCH LOCK_START LOCK_REASON LOCK_MINUTES LOCK_TPID < "$LOCK_FILE" 2>/dev/null || return 1
}

is_lock_active() {
  read_lock || return 1
  kill -0 "$LOCK_PID" 2>/dev/null || { rm -f "$LOCK_FILE"; return 1; }
  return 0
}

remove_lock() {
  rm -f "$LOCK_FILE"
}

# ── Quick reasons ──────────────────────────────────────
expand_quick_reason() {
  local input="$1"
  local IFS=$';'
  local entries=($QUICK_REASONS)
  for entry in "${entries[@]}"; do
    IFS=':' read -r alias reason minutes <<< "$entry"
    if [[ "$input" == "$alias" ]]; then
      QUICK_REASON="$reason"
      QUICK_MINUTES="$minutes"
      return 0
    fi
  done
  return 1
}

# ── Log ────────────────────────────────────────────────
log_afk() {
  local reason="$1" start="$2" end="$3" duration="$4"
  local date
  date=$(date +"%Y-%m-%d")
  echo "${date}|${start}|${end}|${duration}|${reason}" >> "$LOG_FILE"
}

# ── Calculate duration ─────────────────────────────────
calculate_duration() {
  local t1 t2 diff h m
  t1=$(date -d "today $1" +%s 2>/dev/null) || { echo "?"; return; }
  t2=$(date -d "today $2" +%s 2>/dev/null) || { echo "?"; return; }
  diff=$(( t2 - t1 ))
  [[ $diff -lt 0 ]] && diff=$(( diff + 86400 ))
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  [[ $h -gt 0 ]] && echo "${h}h ${m}min" || echo "${m} min"
}

# ── Countdown timer ────────────────────────────────────
timer_countdown() {
  local secs=$(( $1 * 60 ))
  trap 'return 0' TERM 2>/dev/null || true
  while [[ $secs -gt 0 ]]; do
    local mm=$(( secs / 60 ))
    local ss=$(( secs % 60 ))
    printf "\r  "; timer_c "$(printf 'Time remaining: %02d:%02d' "$mm" "$ss")"; printf "   "
    sleep 1 || break
    (( secs-- ))
  done
  if [[ $secs -le 0 ]]; then
    printf "\r  "; red "⏰ Time's up!"; printf "                    \n"
    notify_timer_expired "$1"
  fi
}

# ── Current status (--status) ──────────────────────────
show_status() {
  if ! is_lock_active; then
    echo
    text "  You are not currently AFK."; echo
    if [[ "$AUTO_AFK_MINUTES" != "0" ]] || command -v xprintidle &>/dev/null; then
      local idle_min
      idle_min=$(get_idle_min)
      if [[ "$idle_min" -gt 0 ]]; then
        text "  PC idle: ${idle_min} min"; echo
      fi
    fi
    echo
    return
  fi

  local now elapsed h m elapsed_str
  now=$(date +%s)
  elapsed=$(( now - LOCK_EPOCH ))
  h=$(( elapsed / 3600 ))
  m=$(( (elapsed % 3600) / 60 ))
  [[ $h -gt 0 ]] && elapsed_str="${h}h ${m}min" || elapsed_str="${m} min"

  echo
  draw_line
  border "║"; printf "  "; title "📍  Current AFK Status"; printf "%-25s" ""; border "║"; echo
  draw_mid_line
  draw_empty_row
  draw_kv_row "Reason:" "$LOCK_REASON"
  draw_kv_row "From:" "$LOCK_START"
  draw_kv_row "Time:" "$elapsed_str"
  if [[ -n "$LOCK_MINUTES" && "$LOCK_MINUTES" =~ ^[0-9]+$ ]]; then
    local remaining=$(( LOCK_MINUTES * 60 - elapsed ))
    if [[ $remaining -gt 0 ]]; then
      local rm=$(( remaining / 60 ))
      draw_kv_row "Remaining:" "${rm} min"
    else
      draw_kv_row "Timer:" "Expired"
    fi
  fi
  draw_empty_row
  draw_row "afk --back    → report return"
  draw_row "afk --cancel  → cancel without logging"
  draw_empty_row
  draw_bot_line
  echo
}

# ── Report return from another terminal (--back) ───────
signal_return() {
  if ! is_lock_active; then
    echo; red "  No active AFK session."; echo; echo
    return 1
  fi
  touch "$SEMAPHORE"
  echo; green "  ✓ Return signaled to the AFK process."; echo; echo
}

# ── Cancel AFK (--cancel) ──────────────────────────────
cancel_afk() {
  if ! is_lock_active; then
    echo; red "  No active AFK session."; echo; echo
    return 1
  fi
  touch "$CANCEL_FILE"
  touch "$SEMAPHORE"
  echo; yellow "  ✗ AFK session canceled (not logged)."; echo; echo
}

# ── Statistics ─────────────────────────────────────────
show_stats() {
  clear_screen
  echo
  draw_line
  border "║"; printf "  "; title "📊  AFK Statistics"; printf "%-28s" ""; border "║"; echo
  draw_mid_line

  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    draw_empty_row
    draw_row "No data recorded yet."
    draw_empty_row
    draw_bot_line
    echo
    return
  fi

  local total_sessions total_min=0 today_min=0 week_min=0 today_sessions=0
  total_sessions=$(wc -l < "$LOG_FILE")
  local today
  today=$(date +"%Y-%m-%d")
  local week_ago
  week_ago=$(date -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || date -v-7d +"%Y-%m-%d" 2>/dev/null)

  declare -A reason_min=()
  declare -A reason_count=()

  while IFS='|' read -r date time_i time_f duration reason; do
    local h=0 m=0 total_m
    if [[ "$duration" =~ ([0-9]+)h ]]; then h="${BASH_REMATCH[1]}"; fi
    if [[ "$duration" =~ ([0-9]+)\ min ]]; then m="${BASH_REMATCH[1]}"; fi
    total_m=$(( h * 60 + m ))
    total_min=$(( total_min + total_m ))
    reason_min["$reason"]=$(( ${reason_min["$reason"]:-0} + total_m ))
    reason_count["$reason"]=$(( ${reason_count["$reason"]:-0} + 1 ))

    if [[ "$date" == "$today" ]]; then
      today_min=$(( today_min + total_m ))
      today_sessions=$(( today_sessions + 1 ))
    fi
    if [[ "$date" > "$week_ago" || "$date" == "$week_ago" ]]; then
      week_min=$(( week_min + total_m ))
    fi
  done < "$LOG_FILE"

  local tot_h=$(( total_min / 60 )) tot_m=$(( total_min % 60 ))
  local tod_h=$(( today_min / 60 )) tod_m=$(( today_min % 60 ))
  local wk_h=$(( week_min / 60 ))   wk_m=$(( week_min % 60 ))

  draw_empty_row
  draw_kv_row "Totals:" "$total_sessions sessions | ${tot_h}h ${tot_m}min"
  draw_kv_row "Today:" "$today_sessions sessions | ${tod_h}h ${tod_m}min"
  draw_kv_row "Week:" "${wk_h}h ${wk_m}min"
  draw_empty_row

  # ── Per-reason with ASCII chart ──
  if [[ ${#reason_min[@]} -gt 0 ]]; then
    draw_mid_line
    border "║"; printf "  "; title "By reason"; printf "%-37s" ""; border "║"; echo
    draw_mid_line

    local max_min=0
    for rsn in "${!reason_min[@]}"; do
      [[ ${reason_min[$rsn]} -gt $max_min ]] && max_min=${reason_min[$rsn]}
    done

    local sorted=()
    for rsn in "${!reason_min[@]}"; do
      sorted+=("${reason_min[$rsn]}:${rsn}")
    done
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local mins="${entry%%:*}"
      local rsn="${entry#*:}"
      local bar_len=0
      if [[ $max_min -gt 0 ]]; then
        bar_len=$(( mins * 15 / max_min ))
        [[ $bar_len -eq 0 && $mins -gt 0 ]] && bar_len=1
      fi
      local bar=""
      for (( i=0; i<bar_len; i++ )); do bar+="█"; done
      for (( i=bar_len; i<15; i++ )); do bar+="░"; done

      local eh=$(( mins / 60 )) em=$(( mins % 60 ))
      local time_str
      [[ $eh -gt 0 ]] && time_str="${eh}h${em}m" || time_str="${em}m"

      draw_kv_row "$rsn" "$bar $time_str (${reason_count[$rsn]}x)"
    done < <(printf '%s\n' "${sorted[@]}" | sort -rn)
  fi

  # ── Last 5 sessions ──
  draw_mid_line
  border "║"; printf "  "; title "Last 5 sessions"; printf "%-30s" ""; border "║"; echo
  draw_mid_line

  local count=0
  while IFS='|' read -r _; do count=$(( count + 1 )); done < "$LOG_FILE"
  local skip=$(( count > 5 ? count - 5 : 0 ))
  while IFS='|' read -r date time_i time_f duration reason; do
    [[ $skip -gt 0 ]] && (( skip-- )) && continue
    draw_empty_row
    draw_kv_row "Date:" "$date $time_i → $time_f"
    draw_kv_row "Duration:" "$duration"
    draw_kv_row "Reason:" "$reason"
  done < "$LOG_FILE"

  draw_empty_row
  draw_bot_line
  echo
}

# ── Export CSV (--export) ──────────────────────────────
export_csv() {
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; text "  No data to export."; echo; echo
    return
  fi

  local out_file="${1:-${HOME}/afk_export_$(date +%Y%m%d).csv}"

  {
    echo "Date,Start,End,Duration,Reason"
    while IFS='|' read -r date time_i time_f duration reason; do
      local rsn_esc="${reason//,/;}"
      echo "${date},${time_i},${time_f},${duration},${rsn_esc}"
    done < "$LOG_FILE"
  } > "$out_file"

  echo; green "  ✓ Exported to $out_file"; echo
  text "  ($(wc -l < "$LOG_FILE") rows)"; echo; echo
}

# ── Edit last session (--edit) ─────────────────────────
edit_last() {
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; text "  No session to edit."; echo; echo
    return
  fi

  local last_line date time_i time_f duration reason_old
  last_line=$(tail -1 "$LOG_FILE")
  IFS='|' read -r date time_i time_f duration reason_old <<< "$last_line"

  echo
  text "  Last session:"; echo
  text "    $date $time_i → $time_f ($duration) — $reason_old"; echo
  echo
  printf "  "; text "New reason (Enter = keep): "; printf " "
  read -r new_reason

  if [[ -n "$new_reason" ]]; then
    head -n -1 "$LOG_FILE" > "${LOG_FILE}.tmp"
    echo "${date}|${time_i}|${time_f}|${duration}|${new_reason}" >> "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    echo; green "  ✓ Reason updated: $new_reason"; echo; echo
  else
    echo; text "  No changes."; echo; echo
  fi
}

# ── Clean logs (--clean) ──────────────────────────────
clean_logs() {
  local days="${1:-90}"
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; text "  No logs to clean."; echo; echo
    return
  fi

  local limit
  limit=$(date -d "${days} days ago" +"%Y-%m-%d" 2>/dev/null || date -v-${days}d +"%Y-%m-%d" 2>/dev/null)

  local kept=0 removed=0
  while IFS='|' read -r date _; do
    if [[ "$date" > "$limit" || "$date" == "$limit" ]]; then
      kept=$(( kept + 1 ))
    else
      removed=$(( removed + 1 ))
    fi
  done < "$LOG_FILE"

  if [[ $removed -eq 0 ]]; then
    echo; text "  No entries older than $days days."; echo; echo
    return
  fi

  echo
  text "  $removed entries will be removed (older than $days days)."; echo
  text "  $kept entries will remain."; echo
  printf "  "; text "Confirm? [y/N] "; printf " "
  read -r confirm
  if [[ "$confirm" =~ ^[yY]$ ]]; then
    local tmp="${LOG_FILE}.tmp"
    > "$tmp"
    while IFS= read -r line; do
      local date="${line%%|*}"
      if [[ "$date" > "$limit" || "$date" == "$limit" ]]; then
        echo "$line" >> "$tmp"
      fi
    done < "$LOG_FILE"
    mv "$tmp" "$LOG_FILE"
    green "  ✓ $removed entries removed."; echo; echo
  else
    text "  Canceled."; echo; echo
  fi
}

# ── Self-update (--update) ────────────────────────────
self_update() {
  echo
  text "  Current version: $VERSION"; echo

  local script_path
  script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

  if [[ ! -w "$script_path" ]]; then
    red "  ✗ No write permissions for $script_path"; echo
    text "    Try: sudo afk --update"; echo; echo
    return 1
  fi

  text "  Downloading latest version..."; echo
  local tmp
  tmp=$(mktemp)

  if command -v curl &>/dev/null; then
    curl -fsSL "$REPO_RAW" -o "$tmp" 2>/dev/null
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp" "$REPO_RAW" 2>/dev/null
  else
    red "  ✗ curl or wget required"; echo; echo
    rm -f "$tmp"
    return 1
  fi

  if [[ ! -s "$tmp" ]] || ! head -1 "$tmp" | grep -q "bash"; then
    red "  ✗ Download failed or invalid file"; echo; echo
    rm -f "$tmp"
    return 1
  fi

  local new_ver
  new_ver=$(grep '^VERSION=' "$tmp" | head -1 | grep -oP '"[^"]+"' | tr -d '"')

  if [[ "$new_ver" == "$VERSION" ]]; then
    green "  ✓ Already up to date ($VERSION)"; echo; echo
    rm -f "$tmp"
    return 0
  fi

  cp "$tmp" "$script_path"
  chmod +x "$script_path"
  rm -f "$tmp"

  green "  ✓ Updated: $VERSION → $new_ver"; echo
  text "  Restart afk to use the new version."; echo; echo
}

# ── Auto-AFK daemon (--daemon) ────────────────────────
afk_daemon() {
  [[ "$AUTO_AFK_MINUTES" == "0" ]] && return

  command -v xprintidle &>/dev/null || return
  is_lock_active && return

  local idle_min
  idle_min=$(get_idle_min)

  if [[ "$idle_min" -ge "$AUTO_AFK_MINUTES" ]]; then
    notify normal user-away "Auto-AFK" "Idle for ${idle_min} min — starting auto-AFK"
    log_afk "Auto-AFK (idle)" "$(date -d "-${idle_min} minutes" +"%H:%M" 2>/dev/null || date +"%H:%M")" "$(date +"%H:%M")" "${idle_min} min"
  fi
}
# ── Install Auto-AFK daemon (--install-daemon) ────────
install_daemon() {
  if ! command -v xprintidle &>/dev/null; then
    echo; red "  ✗ xprintidle is required for auto-AFK."; echo
    text "    Install it with: sudo apt install xprintidle"; echo; echo
    return 1
  fi

  if [[ "$AUTO_AFK_MINUTES" == "0" ]]; then
    echo; yellow "  ⚠ Auto-AFK is set to 0 (disabled)."; echo
    text "    Run 'afk --config' to set 'Auto-AFK after X min idle' first."; echo; echo
    return 1
  fi

  local systemd_dir="${HOME}/.config/systemd/user"
  mkdir -p "$systemd_dir"

  cat > "$systemd_dir/afk-daemon.service" << EOF
[Unit]
Description=AFK Auto-Daemon Check

[Service]
Type=oneshot
ExecStart=%h/.local/bin/afk --daemon
EOF

  cat > "$systemd_dir/afk-daemon.timer" << EOF
[Unit]
Description=Run AFK Auto-Daemon every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now afk-daemon.timer 2>/dev/null

  if systemctl --user is-active afk-daemon.timer &>/dev/null; then
    echo; green "  ✓ Auto-AFK daemon installed and running!"; echo
    text "  It will check idle time every 5 minutes."; echo
    text "  Check status: systemctl --user status afk-daemon.timer"; echo; echo
  else
    echo; yellow "  ⚠ Timer installed but may not be running."; echo
    text "  Try manually: systemctl --user enable --now afk-daemon.timer"; echo; echo
  fi
}

# ── Interactive configuration ──────────────────────────
config_wizard() {
  clear_screen
  echo
  title "  ╔══ afk.sh Configuration ══╗"; echo
  echo
  text "  Leave empty to keep current value."; echo
  echo

  read -r -p "  $(text 'Default reason')  [${DEFAULT_REASON}]: " inp
  [[ -n "$inp" ]] && DEFAULT_REASON="$inp"

  read -r -p "  $(text 'Default minutes')  [${DEFAULT_MINUTES:-none}]: " inp
  [[ -n "$inp" ]] && DEFAULT_MINUTES="$inp"

  echo
  title "  Colors (0=black 1=red 2=green 3=yellow 4=blue 5=purple 6=cyan 7=white)"; echo
  read -r -p "  $(text 'Border color')    [${COLOR_BORDER}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COLOR_BORDER="$inp"

  read -r -p "  $(text 'Title color')   [${COLOR_TITLE}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COLOR_TITLE="$inp"

  read -r -p "  $(text 'Text color')    [${COLOR_TEXT}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COLOR_TEXT="$inp"

  read -r -p "  $(text 'Return color')  [${COLOR_RETURN}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COLOR_RETURN="$inp"

  read -r -p "  $(text 'Timer color')    [${COLOR_TIMER}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COLOR_TIMER="$inp"

  echo
  read -r -p "  $(text 'Auto lock screen?') (1=yes 0=no) [${LOCK_SCREEN}]: " inp
  [[ "$inp" =~ ^[01]$ ]] && LOCK_SCREEN="$inp"

  read -r -p "  $(text 'Set Slack status?') (1=yes 0=no) [${SHOW_SLACK}]: " inp
  [[ "$inp" =~ ^[01]$ ]] && SHOW_SLACK="$inp"

  echo
  read -r -p "  $(text 'Auto-AFK after X min idle') (0=disabled) [${AUTO_AFK_MINUTES}]: " inp
  [[ "$inp" =~ ^[0-9]+$ ]] && AUTO_AFK_MINUTES="$inp"

  cat > "$CONFIG_FILE" << EOF
# afk.sh — user configuration
DEFAULT_REASON="${DEFAULT_REASON}"
DEFAULT_MINUTES="${DEFAULT_MINUTES}"
COLOR_BORDER="${COLOR_BORDER}"
COLOR_TITLE="${COLOR_TITLE}"
COLOR_TEXT="${COLOR_TEXT}"
COLOR_RETURN="${COLOR_RETURN}"
COLOR_TIMER="${COLOR_TIMER}"
LOCK_SCREEN="${LOCK_SCREEN}"
SHOW_SLACK="${SHOW_SLACK}"
SHOW_DISCORD="${SHOW_DISCORD}"
AUTO_AFK_MINUTES="${AUTO_AFK_MINUTES}"
QUICK_REASONS="${QUICK_REASONS}"
EOF

  echo
  green "  ✓ Configuration saved in ${CONFIG_FILE}"; echo
  echo
}

# ── Show quick aliases ─────────────────────────────────
show_aliases() {
  echo
  text "  Available quick aliases:"; echo
  local IFS=$';'
  local entries=($QUICK_REASONS)
  for entry in "${entries[@]}"; do
    IFS=':' read -r alias reason minutes <<< "$entry"
    local min_str=""
    [[ -n "$minutes" ]] && min_str=" (${minutes} min)"
    printf "    "; B "$alias"; text " → $reason$min_str"; echo
  done
  echo
  text "  You can add them in ${CONFIG_FILE} (QUICK_REASONS)"; echo
  echo
}

# ── Help ───────────────────────────────────────────────
show_help() {
  echo
  text "  afk.sh v${VERSION} — Away From Keyboard manager — By @tappo_180gg"; echo
  echo
  text "  Usage:"; echo
  printf "  %-35s %s\n" "afk [reason] [minutes]" "start AFK session"
  printf "  %-35s %s\n" "afk 15" "15 min with default reason"
  printf "  %-35s %s\n" "afk <alias>" "e.g. afk lunch, afk coffee"
  printf "  %-35s %s\n" "afk --msg \"note\"" "add note to session"
  echo
  text "  Commands:"; echo
  printf "  %-35s %s\n" "afk --status" "current AFK status"
  printf "  %-35s %s\n" "afk --back" "report return from another terminal"
  printf "  %-35s %s\n" "afk --cancel" "cancel AFK without logging"
  printf "  %-35s %s\n" "afk --stats" "statistics and history"
  printf "  %-35s %s\n" "afk --export [file.csv]" "export log to CSV"
  printf "  %-35s %s\n" "afk --edit" "edit last session reason"
  printf "  %-35s %s\n" "afk --clean [days]" "clean old logs (default: 90)"
  printf "  %-35s %s\n" "afk --aliases" "show quick aliases"
  printf "  %-35s %s\n" "afk --config" "interactive configuration"
  printf "  %-35s %s\n" "afk --update" "update to latest version"
  printf "  %-35s %s\n" "afk --version" "show version"
  printf "  %-35s %s\n" "afk --install-daemon" "setup auto-AFK background timer"
  echo
}

# ═══════════════════════════════════════════════════════
#  Parse arguments
# ═══════════════════════════════════════════════════════
MSG_CUSTOM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status|-S)   show_status; exit 0 ;;
    --back|-b)     signal_return; exit 0 ;;
    --cancel|-x)   cancel_afk; exit 0 ;;
    --stats|-s)    show_stats; exit 0 ;;
    --export)      shift; export_csv "${1:-}"; exit 0 ;;
    --edit|-e)     edit_last; exit 0 ;;
    --clean)       shift; clean_logs "${1:-90}"; exit 0 ;;
    --config|-c)   config_wizard; exit 0 ;;
    --aliases|-a)  show_aliases; exit 0 ;;
    --update|-u)   self_update; exit 0 ;;
    --version|-v)  echo "  afk.sh v${VERSION}"; exit 0 ;;
    --help|-h)     show_help; exit 0 ;;
    --msg|-m)      shift; MSG_CUSTOM="${1:-}"; shift; continue ;;
    --daemon|-d)   afk_daemon; exit 0 ;;
    --install-daemon) install_daemon; exit 0 ;;
    *)             break ;;
  esac
  shift
done

# ═══════════════════════════════════════════════════════
#  Resolve reason and minutes
# ═══════════════════════════════════════════════════════
REASON="${1:-}"
MINUTES="${2:-}"

# If first arg is a pure number → those are the minutes, use default reason
if [[ -n "$REASON" && "$REASON" =~ ^[0-9]+$ ]]; then
  MINUTES="$REASON"
  REASON="$DEFAULT_REASON"
fi

# If it's a quick alias, expand it
QUICK_REASON="" QUICK_MINUTES=""
if [[ -n "$REASON" ]] && expand_quick_reason "$REASON"; then
  REASON="$QUICK_REASON"
  [[ -z "$MINUTES" && -n "$QUICK_MINUTES" ]] && MINUTES="$QUICK_MINUTES"
else
  REASON="${REASON:-$DEFAULT_REASON}"
fi
MINUTES="${MINUTES:-$DEFAULT_MINUTES}"

# ── If --msg without text, ask interactively ───────────
if [[ -n "$MSG_CUSTOM" && -z "$MSG_CUSTOM" ]]; then
  echo
  text "  Message to leave (Enter to skip): "; echo
  printf "  > "
  read -r MSG_CUSTOM
fi

# ═══════════════════════════════════════════════════════
#  Check if already AFK
# ═══════════════════════════════════════════════════════
if is_lock_active; then
  echo
  red "  ⚠ You are already AFK!"; echo
  echo
  now_elapsed=$(( $(date +%s) - LOCK_EPOCH ))
  eh=$(( now_elapsed / 3600 )); em=$(( (now_elapsed % 3600) / 60 ))
  if [[ $eh -gt 0 ]]; then el_str="${eh}h ${em}min"; else el_str="${em} min"; fi
  text "  Reason: $LOCK_REASON | From: $LOCK_START | Time: $el_str"; echo
  echo
  printf "  "; text "Replace the session? [y/N] "; printf " "
  read -r confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    exit 0
  fi
  kill "$LOCK_PID" 2>/dev/null
  [[ -n "$LOCK_TPID" ]] && kill "$LOCK_TPID" 2>/dev/null
  remove_lock
  rm -f "$SEMAPHORE" "$CANCEL_FILE"
  sleep 0.5
fi

# ═══════════════════════════════════════════════════════
#  Main — Start AFK session
# ═══════════════════════════════════════════════════════
start_time=$(date +"%H:%M")

# Cleanup on forced exit
cleanup_trap() {
  [[ -f "$CANCEL_FILE" ]] && return 0
  remove_lock
  rm -f "$SEMAPHORE"
  [[ -n "${TIMER_PID:-}" ]] && kill "$TIMER_PID" 2>/dev/null
}
trap cleanup_trap INT TERM

# Write lock
write_lock "$REASON" "$MINUTES" ""

# Show banner
show_afk_banner "$start_time" "$REASON" "$MINUTES" "$MSG_CUSTOM"

# Desktop notification
notify_afk "$REASON" "$start_time" "$MINUTES"

# Slack
set_slack_status "$REASON"

# Lock screen
lock_screen_if

# Countdown timer in background
TIMER_PID=""
if [[ -n "$MINUTES" && "$MINUTES" =~ ^[0-9]+$ ]]; then
  timer_countdown "$MINUTES" &
  TIMER_PID=$!
  write_lock "$REASON" "$MINUTES" "$TIMER_PID"
fi

# ── Wait for return (Enter / --back / --cancel) ───────
rm -f "$SEMAPHORE" "$CANCEL_FILE"
while true; do
  if read -r -s -t 1 2>/dev/null; then
    break
  fi
  if [[ -f "$SEMAPHORE" ]]; then
    rm -f "$SEMAPHORE"
    break
  fi
done

# ── Check if it was canceled ───────────────────────────
if [[ -f "$CANCEL_FILE" ]]; then
  rm -f "$CANCEL_FILE"
  [[ -n "${TIMER_PID:-}" ]] && kill "$TIMER_PID" 2>/dev/null
  remove_lock
  clear_screen
  echo
  yellow "  ✗ AFK session canceled (not logged)."; echo
  echo
  exit 0
fi

# Stop timer
if [[ -n "${TIMER_PID:-}" ]]; then
  kill "$TIMER_PID" 2>/dev/null
  wait "$TIMER_PID" 2>/dev/null
fi

end_time=$(date +"%H:%M")
duration=$(calculate_duration "$start_time" "$end_time")

# Return notification
notify_return "$end_time" "$start_time" "$duration"

# Save log
log_afk "$REASON" "$start_time" "$end_time" "$duration"

# Remove lock
remove_lock

# ── Return screen ──────────────────────────────────────
clear_screen
echo
draw_line
border "║"; printf "  "; return_c "✓  Welcome back!"; printf "%-36s" ""; border "║"; echo
draw_mid_line
draw_empty_row
draw_kv_row "Returned:" "$end_time"
draw_kv_row "Duration:" "$duration"
draw_kv_row "Reason:" "$REASON"
if [[ -n "$MSG_CUSTOM" ]]; then
  draw_kv_row "Note:" "$MSG_CUSTOM"
fi
draw_empty_row
draw_bot_line
echo