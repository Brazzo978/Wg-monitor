#!/bin/bash
# wg-monitor.sh - Monitor a single WireGuard server and log each state change (connection, IP change, offline/online) in a structured format.
# Compatible with Debian, with input sanity checks, friendly name parsing and debug support.

# --- Preliminary checks ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ You must run as root"
    exit 1
fi
if ! command -v wg &>/dev/null; then
    echo "❌ WireGuard ('wg') not installed. Install with: apt update && apt install wireguard"
    exit 1
fi

# Paths and files
SCRIPT_PATH=$(realpath "$0")
LOG_DIR="/root/logwg"
STATE_DIR="/var/lib/wg-monitor"
PREV_CSV="$STATE_DIR/prev.csv"
CUR_CSV="$STATE_DIR/cur.csv"
CONFIG_FILE="$STATE_DIR/config"
SERVICE_UNIT="/etc/systemd/system/wg-monitor.service"
TIMER_UNIT="/etc/systemd/system/wg-monitor.timer"
DEBUG_LOG="$LOG_DIR/debug.log"
# Debug mode (0=off, 1=on)
DEBUG_MODE=0
# inactivity threshold (seconds) after which a peer is considered offline
STALE_THRESHOLD_DEFAULT=120
if [[ -f "$CONFIG_FILE" ]]; then
    cfg_thr=$(sed -n '4p' "$CONFIG_FILE")
    [[ -n "$cfg_thr" ]] && STALE_THRESHOLD=$cfg_thr || STALE_THRESHOLD=$STALE_THRESHOLD_DEFAULT
    cfg_dbg=$(sed -n '5p' "$CONFIG_FILE")
    [[ -n "$cfg_dbg" ]] && DEBUG_MODE=$cfg_dbg
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
    [[ ${#ifs[@]} -eq 0 ]] && { echo "❌ No WireGuard interface found"; exit 1; }

    echo "Select the WireGuard interface to monitor:"
    PS3="Interface (number) > "
    unset iface conf_file
    until [[ -n "$iface" ]]; do
        select sel in "${ifs[@]}"; do
            if [[ -n "$sel" ]]; then
                iface="$sel"
                conf_file="/etc/wireguard/${iface}.conf"
                echo "$iface" > "$CONFIG_FILE"
                echo "$conf_file" >> "$CONFIG_FILE"
                echo "Selected interface: $iface"
            else
                echo "Invalid choice. Try again."
            fi
            break
        done
    done

    # Intervallo di controllo
    until [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; do
        read -rp "How many seconds between checks? " INTERVAL
        [[ ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]] && echo "❌ Invalid interval. Enter >0."
    done

    # Soglia offline
    until [[ "$THRESH" =~ ^[1-9][0-9]*$ ]]; do
        read -rp "After how many seconds without a handshake is the peer offline? [${STALE_THRESHOLD_DEFAULT}] " THRESH
        [[ -z "$THRESH" ]] && THRESH=$STALE_THRESHOLD_DEFAULT
        [[ ! "$THRESH" =~ ^[1-9][0-9]*$ ]] && { echo "❌ Invalid value."; THRESH=""; }
    done

    echo "$INTERVAL" >> "$CONFIG_FILE"
    echo "$THRESH" >> "$CONFIG_FILE"
    echo "0" >> "$CONFIG_FILE"  # debug off by default

    # Create systemd units
    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Monitor WireGuard peer ($iface)

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH monitor
EOF
    cat > "$TIMER_UNIT" <<EOF
[Unit]
Description=Timer for WireGuard monitor ($iface)

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SERVICE_UNIT" "$TIMER_UNIT"
    systemctl daemon-reload
    systemctl enable --now wg-monitor.timer
    echo "✅ Setup complete: monitoring '$iface' every $INTERVAL seconds"
}

# Load pubkey -> friendly name mapping from .conf file
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

# Parse state to CSV with friendly name and handshake timestamp
parse_state() {
    local file="$1" ts_file="$2"
    load_friendly
    [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG $(date '+%F %T')] parse_state start" >> "$DEBUG_LOG"

    read -r iface <"$CONFIG_FILE"
    if [[ $DEBUG_MODE -eq 1 ]]; then
        wg show "$iface" dump 2>>"$DEBUG_LOG" |
            while IFS=$'\t' read -r pub preshared endpoint allowed handshake rx tx keep; do
                IFS=, read -r local_ip _ <<< "$allowed"
                local name="${friendly_map[$pub]}"
                # CSV: pubkey,local_ip,endpoint,handshake_unix,friendly
                echo "$pub,$local_ip,$endpoint,$handshake,$name"
            done > "$file"
    else
        wg show "$iface" dump 2>/dev/null |
            while IFS=$'\t' read -r pub preshared endpoint allowed handshake rx tx keep; do
                IFS=, read -r local_ip _ <<< "$allowed"
                local name="${friendly_map[$pub]}"
                echo "$pub,$local_ip,$endpoint,$handshake,$name"
            done > "$file"
    fi
    date +%s > "$ts_file"
    [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG] wrote state $file" >> "$DEBUG_LOG"
}

# Monitoring
do_monitor() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG $(date '+%F %T')] do_monitor invoked" >> "$DEBUG_LOG"
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
        # Peer offline if previously online and now stale
        prev_stale=$(( prev_now - prev_hsh[$pub] > STALE_THRESHOLD ))
        curr_stale=$(( now - hsh > STALE_THRESHOLD ))
        if [[ -n "${prev_hsh[$pub]}" && $prev_stale -eq 0 && $curr_stale -eq 1 ]]; then
            echo "[$timestamp] Client $label offline (no handshake >${STALE_THRESHOLD}s)" >> "$LOG_DIR/$(date +%F).log"
        fi
        # Connections and IP changes
        if [[ -z "${prev_end[$pub]}" ]]; then
            echo "[$timestamp] New connection for client $label from remote IP $end" >> "$LOG_DIR/$(date +%F).log"
        elif [[ "${prev_end[$pub]}" != "$end" ]]; then
            echo "[$timestamp] New remote IP for client $label: $end" >> "$LOG_DIR/$(date +%F).log"
        fi
        unset prev_end["$pub"] prev_loc["$pub"] prev_name["$pub"] prev_hsh["$pub"]
    done < "$CUR_CSV"

    # Disconnections (peer removal)
    for pub in "${!prev_end[@]}"; do
        timestamp="$(date '+%F %T')"
        loc="${prev_loc[$pub]}"; name="${prev_name[$pub]}"
        label="$loc"; [[ -n "$name" ]] && label="$name ($loc)"
        echo "[$timestamp] Client $label disconnected" >> "$LOG_DIR/$(date +%F).log"
    done

    mv "$CUR_CSV" "$PREV_CSV"
    mv "$CUR_TS_FILE" "$PREV_TS_FILE"
}

# Menu and main
show_menu() {
    PS3="Choose an option: "
    local options=("Service status" "Restart service" "Enable/Disable" "Clean logs >1 month" "Toggle debug" "Remove everything" "Exit")
    select opt in "${options[@]}"; do
        case $REPLY in
            1) systemctl status wg-monitor.timer --no-pager;;
            2) systemctl restart wg-monitor.timer; echo "Service restarted";;
            3) if systemctl is-enabled wg-monitor.timer &>/dev/null; then systemctl disable --now wg-monitor.timer; echo "Disabled"; else systemctl enable --now wg-monitor.timer; echo "Enabled"; fi;;
            4) find "$LOG_DIR" -type f -mtime +30 -delete; echo "Logs older than 1 month deleted";;
            5) if [[ $DEBUG_MODE -eq 1 ]]; then DEBUG_MODE=0; else DEBUG_MODE=1; fi; sed -i "5c$DEBUG_MODE" "$CONFIG_FILE"; echo "Debug $([[ $DEBUG_MODE -eq 1 ]] && echo 'enabled' || echo 'disabled')";;
            6) systemctl disable --now wg-monitor.timer; rm -f "$SERVICE_UNIT" "$TIMER_UNIT"; systemctl daemon-reload; rm -r "$STATE_DIR" "$LOG_DIR"; echo "Everything removed"; exit;;
            7) exit;;
            *) echo "Invalid option";;
        esac
    done
}

# Entry point
case "$1" in
    install) setup_install ;;  
    monitor) do_monitor ;;  
    *) [[ -f "$CONFIG_FILE" ]] && show_menu || { echo "First start: running setup..."; setup_install; } ;;
esac
