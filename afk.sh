#!/usr/bin/env bash

# ═══════════════════════════════════════════════════════
#  afk.sh — Away From Keyboard manager per Ubuntu
#  Uso: afk [motivo] [minuti]     afk pranzo
#       afk --status              afk --back
#       afk --cancel              afk --stats
#       afk --edit                afk --clean [giorni]
#       afk --export              afk --update
#       afk --aliases             afk --config
# ═══════════════════════════════════════════════════════

VERSION="1.3.0"
REPO_RAW="https://raw.githubusercontent.com/NOMEUTENTE/afk/main/afk.sh"

CONFIG_DIR="${HOME}/.config/afk"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="${CONFIG_DIR}/history.log"
LOCK_FILE="${CONFIG_DIR}/current.afk"
SEMAPHORE="${CONFIG_DIR}/return.now"
CANCEL_FILE="${CONFIG_DIR}/cancelled"

# ── Config di default ──────────────────────────────────
DEFAULT_MOTIVO="AFK"
DEFAULT_MINUTI=""

COL_BORDO="3"        # 0=nero 1=rosso 2=verde 3=giallo 4=blu 5=viola 6=cyan 7=bianco
COL_TITOLO="6"
COL_TESTO="7"
COL_RITORNO="2"
COL_TIMER="3"
MOSTRA_SLACK="1"
MOSTRA_DISCORD="0"
LOCK_SCREEN="0"
AUTO_AFK_MINUTI="0"  # 0 = disabilitato; es. 15 = auto-AFK dopo 15 min di idle

# Alias rapidi: alias:Motivo:Minuti  (separati da ;)
QUICK_REASONS="pranzo:Pranzo:60;caffe:Caffè:5;riunione:Riunione:;bagno:Bagno:5;telefono:Telefono:;pausa:Pausa:15"

# ── Carica config utente se esiste ─────────────────────
mkdir -p "$CONFIG_DIR"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── Helpers colori ─────────────────────────────────────
cc() { printf "\033[${1}m${2}\033[0m"; }
B()  { printf "\033[1m%s\033[0m" "$1"; }

bordo()   { cc "0;3${COL_BORDO}" "$1"; }
titolo()  { cc "1;3${COL_TITOLO}" "$1"; }
testo()   { cc "0;3${COL_TESTO}" "$1"; }
ritorno() { cc "1;3${COL_RITORNO}" "$1"; }
timer_c() { cc "1;3${COL_TIMER}" "$1"; }
rosso()   { cc "1;31" "$1"; }
verde()   { cc "1;32" "$1"; }
giallo()  { cc "1;33" "$1"; }

# ── Funzioni UI ────────────────────────────────────────
pulisci_schermo() {
  clear
  tput cup 0 0 2>/dev/null || true
}

linea()      { bordo "╔══════════════════════════════════════════════╗"; echo; }
linea_mid()  { bordo "╠══════════════════════════════════════════════╣"; echo; }
linea_fine() { bordo "╚══════════════════════════════════════════════╝"; echo; }
riga()       { bordo "║"; printf "  %-44s" "$1"; bordo "║"; echo; }
riga_kv()    { bordo "║"; printf "  "; titolo "%-10s" "$1"; printf "%-34s" "$2"; bordo "║"; echo; }
riga_vuota() { bordo "║"; printf "  %-44s" ""; bordo "║"; echo; }

banner_afk() {
  local ora="$1" motivo="$2" minuti="$3" messaggio="${4:-}"
  pulisci_schermo
  echo
  linea
  bordo "║"; printf "  "; titolo "💤  AFK — Away From Keyboard"; printf "%-18s" ""; bordo "║"; echo
  linea_mid
  riga_vuota
  riga_kv "Motivo:" "$motivo"
  riga_kv "Dalle:" "$ora"
  if [[ -n "$minuti" ]]; then
    local ritorno_ora
    ritorno_ora=$(date -d "+${minuti} minutes" +"%H:%M" 2>/dev/null)
    riga_kv "Torno:" "~$ritorno_ora (${minuti} min)"
  fi
  if [[ -n "$messaggio" ]]; then
    riga_kv "Nota:" "$messaggio"
  fi
  riga_vuota
  linea_fine
  echo
  printf "  "; testo "Premi "; B "Invio"; testo " per segnalare il tuo ritorno"; echo
  printf "  "; testo "(oppure "; B "afk --back"; testo " da un altro terminale)"; echo
  echo
}

# ── Notifiche desktop ──────────────────────────────────
notifica() {
  command -v notify-send &>/dev/null || return
  notify-send --urgency="$1" --icon="$2" "$3" "$4" 2>/dev/null
}

notifica_afk() {
  local corpo="Motivo: $1 | Dalle $2"
  [[ -n "$3" ]] && corpo+=" | Torno tra ${3} min"
  notifica normal user-away "AFK — Away From Keyboard" "$corpo"
}

notifica_ritorno() {
  notifica normal user-available "Bentornato!" "Tornato alle $1 (AFK dalle $2, durata $3)"
}

notifica_timer_scaduto() {
  notifica critical appointment-soon "Timer AFK scaduto!" "Erano $1 minuti — sei ancora via?"
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

# ── Stato app (Slack) ──────────────────────────────────
imposta_stato_slack() {
  local motivo="$1"
  [[ "$MOSTRA_SLACK" != "1" ]] && return
  command -v xdotool &>/dev/null || return

  local slack_win
  slack_win=$(xdotool search --name "Slack" 2>/dev/null | head -1)
  [[ -z "$slack_win" ]] && return

  xdotool windowactivate --sync "$slack_win" 2>/dev/null
  sleep 0.3
  xdotool key --window "$slack_win" ctrl+shift+y 2>/dev/null
  sleep 0.5
  xdotool type --window "$slack_win" --delay 50 "$motivo" 2>/dev/null
  sleep 0.3
  xdotool key --window "$slack_win" Return 2>/dev/null
}

# ── Idle detection (auto-AFK) ──────────────────────────
get_idle_ms() {
  # Prova xprintidle (più affidabile)
  if command -v xprintidle &>/dev/null; then
    xprintidle 2>/dev/null
    return
  fi
  # Fallback: leggi da /proc per X11
  local idle_file="/tmp/.X11-unix"
  if [[ -d "$idle_file" ]]; then
    local xdisplay="${DISPLAY:-:0}"
    local xss_info
    xss_info=$(xdotool getactivewindow getwindowfocus 2>/dev/null)
    # xdotool non dà idle, prova XScreenSaver
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

# ── Lock file (stato AFK corrente) ────────────────────
scrivi_lock() {
  echo "$$|$(date +%s)|$(date +%H:%M)|${1}|${2:-}|${3:-}" > "$LOCK_FILE"
}

leggi_lock() {
  [[ -f "$LOCK_FILE" ]] || return 1
  IFS='|' read -r LOCK_PID LOCK_EPOCH LOCK_START LOCK_MOTIVO LOCK_MINUTI LOCK_TPID < "$LOCK_FILE" 2>/dev/null || return 1
}

lock_attivo() {
  leggi_lock || return 1
  kill -0 "$LOCK_PID" 2>/dev/null || { rm -f "$LOCK_FILE"; return 1; }
  return 0
}

rimuovi_lock() {
  rm -f "$LOCK_FILE"
}

# ── Quick reasons ──────────────────────────────────────
espandi_quick_reason() {
  local input="$1"
  local IFS=$';'
  local entries=($QUICK_REASONS)
  for entry in "${entries[@]}"; do
    IFS=':' read -r alias motivo minuti <<< "$entry"
    if [[ "$input" == "$alias" ]]; then
      QUICK_MOTIVO="$motivo"
      QUICK_MINUTI="$minuti"
      return 0
    fi
  done
  return 1
}

# ── Log ────────────────────────────────────────────────
log_afk() {
  local motivo="$1" inizio="$2" fine="$3" durata="$4"
  local data
  data=$(date +"%Y-%m-%d")
  echo "${data}|${inizio}|${fine}|${durata}|${motivo}" >> "$LOG_FILE"
}

# ── Calcola durata ─────────────────────────────────────
calcola_durata() {
  local t1 t2 diff h m
  t1=$(date -d "today $1" +%s 2>/dev/null) || { echo "?"; return; }
  t2=$(date -d "today $2" +%s 2>/dev/null) || { echo "?"; return; }
  diff=$(( t2 - t1 ))
  [[ $diff -lt 0 ]] && diff=$(( diff + 86400 ))
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  [[ $h -gt 0 ]] && echo "${h}h ${m}min" || echo "${m} min"
}

# ── Conto alla rovescia ────────────────────────────────
timer_countdown() {
  local secs=$(( $1 * 60 ))
  trap 'return 0' TERM 2>/dev/null || true
  while [[ $secs -gt 0 ]]; do
    local mm=$(( secs / 60 ))
    local ss=$(( secs % 60 ))
    printf "\r  "; timer_c "$(printf 'Tempo rimanente: %02d:%02d' "$mm" "$ss")"; printf "   "
    sleep 1 || break
    (( secs-- ))
  done
  if [[ $secs -le 0 ]]; then
    printf "\r  "; rosso "⏰ Tempo scaduto!"; printf "                    \n"
    notifica_timer_scaduto "$1"
  fi
}

# ── Stato corrente (--status) ─────────────────────────
mostra_status() {
  if ! lock_attivo; then
    echo
    testo "  Non sei attualmente AFK."; echo
    # Mostra idle time se disponibile
    if [[ "$AUTO_AFK_MINUTI" != "0" ]] || command -v xprintidle &>/dev/null; then
      local idle_min
      idle_min=$(get_idle_min)
      if [[ "$idle_min" -gt 0 ]]; then
        testo "  Idle del PC: ${idle_min} min"; echo
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
  linea
  bordo "║"; printf "  "; titolo "📍  Stato AFK corrente"; printf "%-25s" ""; bordo "║"; echo
  linea_mid
  riga_vuota
  riga_kv "Motivo:" "$LOCK_MOTIVO"
  riga_kv "Dalle:" "$LOCK_START"
  riga_kv "Tempo:" "$elapsed_str"
  if [[ -n "$LOCK_MINUTI" && "$LOCK_MINUTI" =~ ^[0-9]+$ ]]; then
    local rimasti=$(( LOCK_MINUTI * 60 - elapsed ))
    if [[ $rimasti -gt 0 ]]; then
      local rm=$(( rimasti / 60 ))
      riga_kv "Mancano:" "${rm} min"
    else
      riga_kv "Timer:" "Scaduto"
    fi
  fi
  riga_vuota
  riga "afk --back    → segnala ritorno"
  riga "afk --cancel  → annulla senza log"
  riga_vuota
  linea_fine
  echo
}

# ── Segnala ritorno da altro terminale (--back) ────────
segnala_ritorno() {
  if ! lock_attivo; then
    echo; rosso "  Nessuna sessione AFK attiva."; echo; echo
    return 1
  fi
  touch "$SEMAPHORE"
  echo; verde "  ✓ Ritorno segnalato al processo AFK."; echo; echo
}

# ── Annulla AFK (--cancel) ────────────────────────────
annulla_afk() {
  if ! lock_attivo; then
    echo; rosso "  Nessuna sessione AFK attiva."; echo; echo
    return 1
  fi
  touch "$CANCEL_FILE"
  touch "$SEMAPHORE"
  echo; giallo "  ✗ Sessione AFK annullata (non loggata)."; echo; echo
}

# ── Statistiche ────────────────────────────────────────
mostra_stats() {
  pulisci_schermo
  echo
  linea
  bordo "║"; printf "  "; titolo "📊  Statistiche AFK"; printf "%-28s" ""; bordo "║"; echo
  linea_mid

  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    riga_vuota
    riga "Nessun dato registrato ancora."
    riga_vuota
    linea_fine
    echo
    return
  fi

  local totale_sessioni totale_min=0 oggi_min=0 sett_min=0 oggi_sessioni=0
  totale_sessioni=$(wc -l < "$LOG_FILE")
  local oggi
  oggi=$(date +"%Y-%m-%d")
  local sett_fa
  sett_fa=$(date -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || date -v-7d +"%Y-%m-%d" 2>/dev/null)

  declare -A motivo_min=()
  declare -A motivo_count=()

  while IFS='|' read -r data ora_i ora_f durata motivo; do
    local h=0 m=0 min_totali
    if [[ "$durata" =~ ([0-9]+)h ]]; then h="${BASH_REMATCH[1]}"; fi
    if [[ "$durata" =~ ([0-9]+)\ min ]]; then m="${BASH_REMATCH[1]}"; fi
    min_totali=$(( h * 60 + m ))
    totale_min=$(( totale_min + min_totali ))
    motivo_min["$motivo"]=$(( ${motivo_min["$motivo"]:-0} + min_totali ))
    motivo_count["$motivo"]=$(( ${motivo_count["$motivo"]:-0} + 1 ))

    if [[ "$data" == "$oggi" ]]; then
      oggi_min=$(( oggi_min + min_totali ))
      oggi_sessioni=$(( oggi_sessioni + 1 ))
    fi
    if [[ "$data" > "$sett_fa" || "$data" == "$sett_fa" ]]; then
      sett_min=$(( sett_min + min_totali ))
    fi
  done < "$LOG_FILE"

  local tot_h=$(( totale_min / 60 )) tot_m=$(( totale_min % 60 ))
  local ogg_h=$(( oggi_min / 60 ))   ogg_m=$(( oggi_min % 60 ))
  local set_h=$(( sett_min / 60 ))    set_m=$(( sett_min % 60 ))

  riga_vuota
  riga_kv "Totali:" "$totale_sessioni sessioni | ${tot_h}h ${tot_m}min"
  riga_kv "Oggi:" "$oggi_sessioni sessioni | ${ogg_h}h ${ogg_m}min"
  riga_kv "Settimana:" "${set_h}h ${set_m}min"
  riga_vuota

  # ── Per-motivo con grafico ASCII ──
  if [[ ${#motivo_min[@]} -gt 0 ]]; then
    linea_mid
    bordo "║"; printf "  "; titolo "Per motivo"; printf "%-37s" ""; bordo "║"; echo
    linea_mid

    local max_min=0
    for mot in "${!motivo_min[@]}"; do
      [[ ${motivo_min[$mot]} -gt $max_min ]] && max_min=${motivo_min[$mot]}
    done

    local sorted=()
    for mot in "${!motivo_min[@]}"; do
      sorted+=("${motivo_min[$mot]}:${mot}")
    done
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local mins="${entry%%:*}"
      local mot="${entry#*:}"
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

      riga_kv "$mot" "$bar $time_str (${motivo_count[$mot]}x)"
    done < <(printf '%s\n' "${sorted[@]}" | sort -rn)
  fi

  # ── Ultime 5 sessioni ──
  linea_mid
  bordo "║"; printf "  "; titolo "Ultime 5 sessioni"; printf "%-30s" ""; bordo "║"; echo
  linea_mid

  local count=0
  while IFS='|' read -r _; do count=$(( count + 1 )); done < "$LOG_FILE"
  local skip=$(( count > 5 ? count - 5 : 0 ))
  while IFS='|' read -r data ora_i ora_f durata motivo; do
    [[ $skip -gt 0 ]] && (( skip-- )) && continue
    riga_vuota
    riga_kv "Data:" "$data $ora_i → $ora_f"
    riga_kv "Durata:" "$durata"
    riga_kv "Motivo:" "$motivo"
  done < "$LOG_FILE"

  riga_vuota
  linea_fine
  echo
}

# ── Export CSV (--export) ──────────────────────────────
esporta_csv() {
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; testo "  Nessun dato da esportare."; echo; echo
    return
  fi

  local out_file="${1:-${HOME}/afk_export_$(date +%Y%m%d).csv}"

  {
    echo "Data,Inizio,Fine,Durata,Motivo"
    while IFS='|' read -r data ora_i ora_f durata motivo; do
      # Escape virgole nel motivo
      local mot_esc="${motivo//,/;}"
      echo "${data},${ora_i},${ora_f},${durata},${mot_esc}"
    done < "$LOG_FILE"
  } > "$out_file"

  echo; verde "  ✓ Esportato in $out_file"; echo
  testo "  ($(wc -l < "$LOG_FILE") righe)"; echo; echo
}

# ── Modifica ultima sessione (--edit) ──────────────────
modifica_ultima() {
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; testo "  Nessuna sessione da modificare."; echo; echo
    return
  fi

  local last_line data ora_i ora_f durata motivo_old
  last_line=$(tail -1 "$LOG_FILE")
  IFS='|' read -r data ora_i ora_f durata motivo_old <<< "$last_line"

  echo
  testo "  Ultima sessione:"; echo
  testo "    $data $ora_i → $ora_f ($durata) — $motivo_old"; echo
  echo
  printf "  "; testo "Nuovo motivo (Invio = mantieni): "; printf " "
  read -r nuovo_motivo

  if [[ -n "$nuovo_motivo" ]]; then
    head -n -1 "$LOG_FILE" > "${LOG_FILE}.tmp"
    echo "${data}|${ora_i}|${ora_f}|${durata}|${nuovo_motivo}" >> "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    echo; verde "  ✓ Motivo aggiornato: $nuovo_motivo"; echo; echo
  else
    echo; testo "  Nessuna modifica."; echo; echo
  fi
}

# ── Pulizia log (--clean) ─────────────────────────────
pulisci_log() {
  local giorni="${1:-90}"
  if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
    echo; testo "  Nessun log da pulire."; echo; echo
    return
  fi

  local limite
  limite=$(date -d "${giorni} days ago" +"%Y-%m-%d" 2>/dev/null || date -v-${giorni}d +"%Y-%m-%d" 2>/dev/null)

  local rimaste=0 rimosse=0
  while IFS='|' read -r data _; do
    if [[ "$data" > "$limite" || "$data" == "$limite" ]]; then
      rimaste=$(( rimaste + 1 ))
    else
      rimosse=$(( rimosse + 1 ))
    fi
  done < "$LOG_FILE"

  if [[ $rimosse -eq 0 ]]; then
    echo; testo "  Nessuna voce più vecchia di $giorni giorni."; echo; echo
    return
  fi

  echo
  testo "  Saranno rimosse $rimosse voci (più vecchie di $giorni giorni)."; echo
  testo "  Rimarranno $rimaste voci."; echo
  printf "  "; testo "Confermi? [s/N] "; printf " "
  read -r conferma
  if [[ "$conferma" =~ ^[sSyY]$ ]]; then
    local tmp="${LOG_FILE}.tmp"
    > "$tmp"
    while IFS= read -r line; do
      local data="${line%%|*}"
      if [[ "$data" > "$limite" || "$data" == "$limite" ]]; then
        echo "$line" >> "$tmp"
      fi
    done < "$LOG_FILE"
    mv "$tmp" "$LOG_FILE"
    verde "  ✓ $rimosse voci rimosse."; echo; echo
  else
    testo "  Annullato."; echo; echo
  fi
}

# ── Self-update (--update) ────────────────────────────
self_update() {
  echo
  testo "  Versione attuale: $VERSION"; echo

  local script_path
  script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

  if [[ ! -w "$script_path" ]]; then
    rosso "  ✗ Non ho i permessi per scrivere $script_path"; echo
    testo "    Prova: sudo afk --update"; echo; echo
    return 1
  fi

  testo "  Scarico ultima versione..."; echo
  local tmp
  tmp=$(mktemp)

  if command -v curl &>/dev/null; then
    curl -fsSL "$REPO_RAW" -o "$tmp" 2>/dev/null
  elif command -v wget &>/dev/null; then
    wget -qO "$tmp" "$REPO_RAW" 2>/dev/null
  else
    rosso "  ✗ Serve curl o wget"; echo; echo
    rm -f "$tmp"
    return 1
  fi

  # Verifica che il download sia valido
  if [[ ! -s "$tmp" ]] || ! head -1 "$tmp" | grep -q "bash"; then
    rosso "  ✗ Download fallito o file non valido"; echo; echo
    rm -f "$tmp"
    return 1
  fi

  # Estrai la versione nuova
  local new_ver
  new_ver=$(grep '^VERSION=' "$tmp" | head -1 | grep -oP '"[^"]+"' | tr -d '"')

  if [[ "$new_ver" == "$VERSION" ]]; then
    verde "  ✓ Già all'ultima versione ($VERSION)"; echo; echo
    rm -f "$tmp"
    return 0
  fi

  cp "$tmp" "$script_path"
  chmod +x "$script_path"
  rm -f "$tmp"

  verde "  ✓ Aggiornato: $VERSION → $new_ver"; echo
  testo "  Riavvia afk per usare la nuova versione."; echo; echo
}

# ── Auto-AFK daemon (--daemon) ────────────────────────
afk_daemon() {
  [[ "$AUTO_AFK_MINUTI" == "0" ]] && return

  command -v xprintidle &>/dev/null || return
  lock_attivo && return  # già AFK

  local idle_min
  idle_min=$(get_idle_min)

  if [[ "$idle_min" -ge "$AUTO_AFK_MINUTI" ]]; then
    # Auto-AFK!
    notifica normal user-away "Auto-AFK" "Idle da ${idle_min} min — avvio AFK automatico"
    log_afk "Auto-AFK (idle)" "$(date -d "-${idle_min} minutes" +"%H:%M" 2>/dev/null || date +"%H:%M")" "$(date +"%H:%M")" "${idle_min} min"
  fi
}

# ── Configurazione interattiva ─────────────────────────
wizard_config() {
  pulisci_schermo
  echo
  titolo "  ╔══ Configurazione afk.sh ══╗"; echo
  echo
  testo "  Lascia vuoto per mantenere il valore attuale."; echo
  echo

  read -r -p "  $(testo 'Motivo default')  [${DEFAULT_MOTIVO}]: " inp
  [[ -n "$inp" ]] && DEFAULT_MOTIVO="$inp"

  read -r -p "  $(testo 'Minuti default')  [${DEFAULT_MINUTI:-nessuno}]: " inp
  [[ -n "$inp" ]] && DEFAULT_MINUTI="$inp"

  echo
  titolo "  Colori (0=nero 1=rosso 2=verde 3=giallo 4=blu 5=viola 6=cyan 7=bianco)"; echo
  read -r -p "  $(testo 'Colore bordo')    [${COL_BORDO}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COL_BORDO="$inp"

  read -r -p "  $(testo 'Colore titolo')   [${COL_TITOLO}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COL_TITOLO="$inp"

  read -r -p "  $(testo 'Colore testo')    [${COL_TESTO}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COL_TESTO="$inp"

  read -r -p "  $(testo 'Colore ritorno')  [${COL_RITORNO}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COL_RITORNO="$inp"

  read -r -p "  $(testo 'Colore timer')    [${COL_TIMER}]: " inp
  [[ "$inp" =~ ^[0-7]$ ]] && COL_TIMER="$inp"

  echo
  read -r -p "  $(testo 'Lock screen automatico?') (1=sì 0=no) [${LOCK_SCREEN}]: " inp
  [[ "$inp" =~ ^[01]$ ]] && LOCK_SCREEN="$inp"

  read -r -p "  $(testo 'Imposta stato Slack?') (1=sì 0=no) [${MOSTRA_SLACK}]: " inp
  [[ "$inp" =~ ^[01]$ ]] && MOSTRA_SLACK="$inp"

  echo
  read -r -p "  $(testo 'Auto-AFK dopo X min idle') (0=disabilitato) [${AUTO_AFK_MINUTI}]: " inp
  [[ "$inp" =~ ^[0-9]+$ ]] && AUTO_AFK_MINUTI="$inp"

  cat > "$CONFIG_FILE" << EOF
# afk.sh — configurazione utente
DEFAULT_MOTIVO="${DEFAULT_MOTIVO}"
DEFAULT_MINUTI="${DEFAULT_MINUTI}"
COL_BORDO="${COL_BORDO}"
COL_TITOLO="${COL_TITOLO}"
COL_TESTO="${COL_TESTO}"
COL_RITORNO="${COL_RITORNO}"
COL_TIMER="${COL_TIMER}"
LOCK_SCREEN="${LOCK_SCREEN}"
MOSTRA_SLACK="${MOSTRA_SLACK}"
MOSTRA_DISCORD="${MOSTRA_DISCORD}"
AUTO_AFK_MINUTI="${AUTO_AFK_MINUTI}"
QUICK_REASONS="${QUICK_REASONS}"
EOF

  echo
  verde "  ✓ Configurazione salvata in ${CONFIG_FILE}"; echo
  echo
}

# ── Mostra quick reasons ──────────────────────────────
mostra_aliases() {
  echo
  testo "  Alias rapidi disponibili:"; echo
  local IFS=$';'
  local entries=($QUICK_REASONS)
  for entry in "${entries[@]}"; do
    IFS=':' read -r alias motivo minuti <<< "$entry"
    local min_str=""
    [[ -n "$minuti" ]] && min_str=" (${minuti} min)"
    printf "    "; B "$alias"; testo " → $motivo$min_str"; echo
  done
  echo
  testo "  Puoi aggiungerli in ${CONFIG_FILE} (QUICK_REASONS)"; echo
  echo
}

# ── Help ───────────────────────────────────────────────
mostra_help() {
  echo
  testo "  afk.sh v${VERSION} — Away From Keyboard manager"; echo
  echo
  testo "  Uso:"; echo
  printf "  %-35s %s\n" "afk [motivo] [minuti]" "avvia sessione AFK"
  printf "  %-35s %s\n" "afk 15" "15 min con motivo default"
  printf "  %-35s %s\n" "afk <alias>" "es. afk pranzo, afk caffe"
  printf "  %-35s %s\n" "afk --msg \"nota\"" "aggiunge nota alla sessione"
  echo
  testo "  Comandi:"; echo
  printf "  %-35s %s\n" "afk --status" "stato AFK corrente"
  printf "  %-35s %s\n" "afk --back" "segnala ritorno da altro terminale"
  printf "  %-35s %s\n" "afk --cancel" "annulla AFK senza loggare"
  printf "  %-35s %s\n" "afk --stats" "statistiche e storico"
  printf "  %-35s %s\n" "afk --export [file.csv]" "esporta log in CSV"
  printf "  %-35s %s\n" "afk --edit" "modifica motivo ultima sessione"
  printf "  %-35s %s\n" "afk --clean [giorni]" "pulisci log vecchi (default: 90)"
  printf "  %-35s %s\n" "afk --aliases" "mostra alias rapidi"
  printf "  %-35s %s\n" "afk --config" "configurazione interattiva"
  printf "  %-35s %s\n" "afk --update" "aggiorna all'ultima versione"
  printf "  %-35s %s\n" "afk --version" "mostra versione"
  echo
}

# ═══════════════════════════════════════════════════════
#  Parse argomenti
# ═══════════════════════════════════════════════════════
MSG_CUSTOM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status|-S)   mostra_status; exit 0 ;;
    --back|-b)     segnala_ritorno; exit 0 ;;
    --cancel|-x)   annulla_afk; exit 0 ;;
    --stats|-s)    mostra_stats; exit 0 ;;
    --export)      shift; esporta_csv "${1:-}"; exit 0 ;;
    --edit|-e)     modifica_ultima; exit 0 ;;
    --clean)       shift; pulisci_log "${1:-90}"; exit 0 ;;
    --config|-c)   wizard_config; exit 0 ;;
    --aliases|-a)  mostra_aliases; exit 0 ;;
    --update|-u)   self_update; exit 0 ;;
    --version|-v)  echo "  afk.sh v${VERSION}"; exit 0 ;;
    --help|-h)     mostra_help; exit 0 ;;
    --msg|-m)      shift; MSG_CUSTOM="${1:-}"; shift; continue ;;
    --daemon|-d)   afk_daemon; exit 0 ;;
    *)             break ;;
  esac
  shift
done

# ═══════════════════════════════════════════════════════
#  Risolvi motivo e minuti
# ═══════════════════════════════════════════════════════
MOTIVO="${1:-}"
MINUTI="${2:-}"

# Se il primo arg è un numero puro → è i minuti, usa motivo default
if [[ -n "$MOTIVO" && "$MOTIVO" =~ ^[0-9]+$ ]]; then
  MINUTI="$MOTIVO"
  MOTIVO="$DEFAULT_MOTIVO"
fi

# Se è un alias rapido, espandilo
QUICK_MOTIVO="" QUICK_MINUTI=""
if [[ -n "$MOTIVO" ]] && espandi_quick_reason "$MOTIVO"; then
  MOTIVO="$QUICK_MOTIVO"
  [[ -z "$MINUTI" && -n "$QUICK_MINUTI" ]] && MINUTI="$QUICK_MINUTI"
else
  MOTIVO="${MOTIVO:-$DEFAULT_MOTIVO}"
fi
MINUTI="${MINUTI:-$DEFAULT_MINUTI}"

# ── Se --msg senza testo, chiedi interattivamente ─────
if [[ -n "$MSG_CUSTOM" && -z "$MSG_CUSTOM" ]]; then
  echo
  testo "  Messaggio da lasciare (Invio per saltare): "; echo
  printf "  > "
  read -r MSG_CUSTOM
fi

# ═══════════════════════════════════════════════════════
#  Controlla se già AFK
# ═══════════════════════════════════════════════════════
if lock_attivo; then
  echo
  rosso "  ⚠ Sei già AFK!"; echo
  echo
  now_elapsed=$(( $(date +%s) - LOCK_EPOCH ))
  eh=$(( now_elapsed / 3600 )); em=$(( (now_elapsed % 3600) / 60 ))
  if [[ $eh -gt 0 ]]; then el_str="${eh}h ${em}min"; else el_str="${em} min"; fi
  testo "  Motivo: $LOCK_MOTIVO | Dalle: $LOCK_START | Tempo: $el_str"; echo
  echo
  printf "  "; testo "Sostituire la sessione? [s/N] "; printf " "
  read -r conferma
  if [[ ! "$conferma" =~ ^[sSyY]$ ]]; then
    exit 0
  fi
  # Uccidi la vecchia sessione
  kill "$LOCK_PID" 2>/dev/null
  [[ -n "$LOCK_TPID" ]] && kill "$LOCK_TPID" 2>/dev/null
  rimuovi_lock
  rm -f "$SEMAPHORE" "$CANCEL_FILE"
  sleep 0.5
fi

# ═══════════════════════════════════════════════════════
#  Main — avvia sessione AFK
# ═══════════════════════════════════════════════════════
ora_inizio=$(date +"%H:%M")

# Cleanup su uscita forzata
cleanup_trap() {
  [[ -f "$CANCEL_FILE" ]] && return 0
  rimuovi_lock
  rm -f "$SEMAPHORE"
  [[ -n "${TIMER_PID:-}" ]] && kill "$TIMER_PID" 2>/dev/null
}
trap cleanup_trap INT TERM

# Scrivi lock
scrivi_lock "$MOTIVO" "$MINUTI" ""

# Mostra banner
banner_afk "$ora_inizio" "$MOTIVO" "$MINUTI" "$MSG_CUSTOM"

# Notifica desktop
notifica_afk "$MOTIVO" "$ora_inizio" "$MINUTI"

# Slack
imposta_stato_slack "$MOTIVO"

# Lock screen
lock_screen_if

# Timer countdown in background
TIMER_PID=""
if [[ -n "$MINUTI" && "$MINUTI" =~ ^[0-9]+$ ]]; then
  timer_countdown "$MINUTI" &
  TIMER_PID=$!
  scrivi_lock "$MOTIVO" "$MINUTI" "$TIMER_PID"
fi

# ── Aspetta ritorno (Invio / --back / --cancel) ───────
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

# ── Controlla se è stato annullato ────────────────────
if [[ -f "$CANCEL_FILE" ]]; then
  rm -f "$CANCEL_FILE"
  [[ -n "${TIMER_PID:-}" ]] && kill "$TIMER_PID" 2>/dev/null
  rimuovi_lock
  pulisci_schermo
  echo
  giallo "  ✗ Sessione AFK annullata (non loggata)."; echo
  echo
  exit 0
fi

# Ferma timer
if [[ -n "${TIMER_PID:-}" ]]; then
  kill "$TIMER_PID" 2>/dev/null
  wait "$TIMER_PID" 2>/dev/null
fi

ora_fine=$(date +"%H:%M")
durata=$(calcola_durata "$ora_inizio" "$ora_fine")

# Notifica ritorno
notifica_ritorno "$ora_fine" "$ora_inizio" "$durata"

# Salva log
log_afk "$MOTIVO" "$ora_inizio" "$ora_fine" "$durata"

# Rimuovi lock
rimuovi_lock

# ── Schermata di ritorno ──────────────────────────────
pulisci_schermo
echo
linea
bordo "║"; printf "  "; ritorno "✓  Bentornato!"; printf "%-36s" ""; bordo "║"; echo
linea_mid
riga_vuota
riga_kv "Tornato:" "$ora_fine"
riga_kv "Durata:" "$durata"
riga_kv "Motivo:" "$MOTIVO"
if [[ -n "$MSG_CUSTOM" ]]; then
  riga_kv "Nota:" "$MSG_CUSTOM"
fi
riga_vuota
linea_fine
echo