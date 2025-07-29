#!/bin/bash
# wg-monitor.sh – Monitora un singolo server WireGuard e logga ogni variazione di stato (connessione, cambio IP, offline/online) in modo strutturato
# Compatibile Debian, auto‑commentato con sanity-check sugli input, parsing del friendly name e debug.

# --- Controlli preliminari ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ Devi eseguire come root"
    exit 1
fi
if ! command -v wg &>/dev/null; then
    echo "❌ WireGuard ('wg') non installato. Installa con: apt update && apt install wireguard"
    exit 1
fi

# Percorsi e file
SCRIPT_PATH=$(realpath "$0")
LOG_DIR="/root/logwg"
STATE_DIR="/var/lib/wg-monitor"
PREV_CSV="$STATE_DIR/prev.csv"
CUR_CSV="$STATE_DIR/cur.csv"
CONFIG_FILE="$STATE_DIR/config"
SERVICE_UNIT="/etc/systemd/system/wg-monitor.service"
TIMER_UNIT="/etc/systemd/system/wg-monitor.timer"
DEBUG_LOG="$LOG_DIR/debug.log"
# soglia di inattivita' (secondi) oltre la quale un peer e' considerato offline
STALE_THRESHOLD_DEFAULT=120
if [[ -f "$CONFIG_FILE" ]]; then
    cfg_thr=$(sed -n '4p' "$CONFIG_FILE")
    [[ -n "$cfg_thr" ]] && STALE_THRESHOLD=$cfg_thr || STALE_THRESHOLD=$STALE_THRESHOLD_DEFAULT
else
    STALE_THRESHOLD=$STALE_THRESHOLD_DEFAULT
fi
PREV_TS_FILE="$STATE_DIR/prev_ts"
CUR_TS_FILE="$STATE_DIR/cur_ts"

# --- Funzioni ---
setup_install() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod +x "$SCRIPT_PATH"

    # Interfacce WireGuard
    mapfile -t ifs < <(wg show interfaces)
    [[ ${#ifs[@]} -eq 0 ]] && { echo "❌ Nessuna interfaccia WireGuard trovata"; exit 1; }

    echo "Seleziona l'interfaccia WireGuard da monitorare:"
    PS3="Interfaccia (numero) > "
    unset iface conf_file
    until [[ -n "$iface" ]]; do
        select sel in "${ifs[@]}"; do
            if [[ -n "$sel" ]]; then
                iface="$sel"
                conf_file="/etc/wireguard/${iface}.conf"
                echo "$iface" > "$CONFIG_FILE"
                echo "$conf_file" >> "$CONFIG_FILE"
                echo "Interfaccia selezionata: $iface"
            else
                echo "Scelta non valida. Riprova."
            fi
            break
        done
    done

    # Intervallo di controllo
    until [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; do
        read -rp "Ogni quanti secondi vuoi eseguire il controllo? " INTERVAL
        [[ ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]] && echo "❌ Intervallo non valido. Inserisci >0."
    done

    # Soglia offline
    until [[ "$THRESH" =~ ^[1-9][0-9]*$ ]]; do
        read -rp "Dopo quanti secondi senza handshake il peer è offline? [${STALE_THRESHOLD_DEFAULT}] " THRESH
        [[ -z "$THRESH" ]] && THRESH=$STALE_THRESHOLD_DEFAULT
        [[ ! "$THRESH" =~ ^[1-9][0-9]*$ ]] && { echo "❌ Valore non valido."; THRESH=""; }
    done

    echo "$INTERVAL" >> "$CONFIG_FILE"
    echo "$THRESH" >> "$CONFIG_FILE"

    # Creazione unità systemd
    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Monitor WireGuard peer ($iface)

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH monitor
EOF
    cat > "$TIMER_UNIT" <<EOF
[Unit]
Description=Timer per monitor WireGuard peer ($iface)

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SERVICE_UNIT" "$TIMER_UNIT"
    systemctl daemon-reload
    systemctl enable --now wg-monitor.timer
    echo "✅ Setup completato: monitoraggio di '$iface' ogni $INTERVAL secondi"
}

# Carica mapping pubkey -> friendly name da file .conf
load_friendly() {
    declare -gA friendly_map
    local current_name=""
    read -r iface <"$CONFIG_FILE"
    local conf_file
    conf_file=$(sed -n '2p' "$CONFIG_FILE")
    [[ ! -f "$conf_file" ]] && return 0

    while IFS= read -r line; do
        if [[ $line =~ ^###[[:space:]]begin[[:space:]](.+)[[:space:]]### ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^PublicKey[[:space:]]*=[[:space:]]*([A-Za-z0-9+/=]+) ]]; then
            local pubkey="${BASH_REMATCH[1]}"
            [[ -n "$current_name" ]] && friendly_map["$pubkey"]="$current_name"
            current_name=""
        fi
    done < "$conf_file"
}

# Parsaggio stato in CSV con friendly name e timestamp handshake
parse_state() {
    local file="$1" ts_file="$2"
    load_friendly
    echo "[DEBUG $(date '+%F %T')] parse_state start" >> "$DEBUG_LOG"

    read -r iface <"$CONFIG_FILE"
    wg show "$iface" dump 2>>"$DEBUG_LOG" | while IFS=$'\t' read -r pub preshared endpoint allowed handshake rx tx keep; do
        IFS=, read -r local_ip _ <<< "$allowed"
        local name="${friendly_map[$pub]}"
        # CSV: pubkey,local_ip,endpoint,handshake_unix,friendly
        echo "$pub,$local_ip,$endpoint,$handshake,$name"
    done > "$file"
    date +%s > "$ts_file"
    echo "[DEBUG] wrote state $file" >> "$DEBUG_LOG"
}

# Monitoraggio
do_monitor() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    echo "[DEBUG $(date '+%F %T')] do_monitor invoked" >> "$DEBUG_LOG"
    parse_state "$CUR_CSV" "$CUR_TS_FILE"
    [[ ! -f "$PREV_CSV" ]] && { mv "$CUR_CSV" "$PREV_CSV"; mv "$CUR_TS_FILE" "$PREV_TS_FILE"; exit 0; }

    local now=$(cat "$CUR_TS_FILE")
    local prev_now=$(cat "$PREV_TS_FILE")
    declare -A prev_hsh prev_end prev_loc prev_name
    while IFS=, read -r pub loc end hsh name; do
        prev_hsh["$pub"]=$hsh
        prev_end["$pub"]="$end"
        prev_loc["$pub"]="$loc"
        prev_name["$pub"]="$name"
    done < "$PREV_CSV"

    while IFS=, read -r pub loc end hsh name; do
        timestamp="$(date '+%F %T')"
        label="$loc"; [[ -n "$name" ]] && label="$name ($loc)"
        # Stato offline se era online e ora stale
        prev_stale=$(( prev_now - prev_hsh[$pub] > STALE_THRESHOLD ))
        curr_stale=$(( now - hsh > STALE_THRESHOLD ))
        if [[ -n "${prev_hsh[$pub]}" && $prev_stale -eq 0 && $curr_stale -eq 1 ]]; then
            echo "[$timestamp] Client $label offline (nessun handshake >${STALE_THRESHOLD}s)" >> "$LOG_DIR/$(date +%F).log"
        fi
        # Connessioni e cambio ip
        if [[ -z "${prev_end[$pub]}" ]]; then
            echo "[$timestamp] Nuova connessione per client $label da ip remoto $end" >> "$LOG_DIR/$(date +%F).log"
        elif [[ "${prev_end[$pub]}" != "$end" ]]; then
            echo "[$timestamp] Nuovo ip remoto per client $label: $end" >> "$LOG_DIR/$(date +%F).log"
        fi
        unset prev_end["$pub"] prev_loc["$pub"] prev_name["$pub"] prev_hsh["$pub"]
    done < "$CUR_CSV"

    # Disconnessioni (rimozione peer)
    for pub in "${!prev_end[@]}"; do
        timestamp="$(date '+%F %T')"
        loc="${prev_loc[$pub]}"; name="${prev_name[$pub]}"
        label="$loc"; [[ -n "$name" ]] && label="$name ($loc)"
        echo "[$timestamp] Client $label disconnesso" >> "$LOG_DIR/$(date +%F).log"
    done

    mv "$CUR_CSV" "$PREV_CSV"
    mv "$CUR_TS_FILE" "$PREV_TS_FILE"
}

# Menu e main
show_menu() {
    PS3="Scegli un'opzione: "
    local options=("Stato servizio" "Riavvia servizio" "Abilita/Disabilita" "Pulisci log >1 mese" "Rimuovi tutto" "Esci")
    select opt in "${options[@]}"; do
        case $REPLY in
            1) systemctl status wg-monitor.timer --no-pager;;
            2) systemctl restart wg-monitor.timer; echo "Servizio riavviato";;
            3) if systemctl is-enabled wg-monitor.timer &>/dev/null; then systemctl disable --now wg-monitor.timer; echo "Disabilitato"; else systemctl enable --now wg-monitor.timer; echo "Abilitato"; fi;;
            4) find "$LOG_DIR" -type f -mtime +30 -delete; echo "Log >1 mese cancellati";;
            5) systemctl disable --now wg-monitor.timer; rm -f "$SERVICE_UNIT" "$TIMER_UNIT"; systemctl daemon-reload; rm -r "$STATE_DIR" "$LOG_DIR"; echo "Tutto rimosso"; exit;;
            6) exit;;
            *) echo "Opzione non valida";;
        esac
    done
}

# Entry point
case "$1" in
    install) setup_install ;;  
    monitor) do_monitor ;;  
    *) [[ -f "$CONFIG_FILE" ]] && show_menu || { echo "Primo avvio: setup..."; setup_install; } ;;
esac
