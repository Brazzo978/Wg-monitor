#!/bin/bash
# wg-monitor.sh – Monitora un singolo server WireGuard e logga ogni variazione di stato in modo strutturato
# Compatibile Debian, auto‑commentato con sanity-check sugli input e parsing del friendly name.

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
CONF_FILE=""  # Percorso al file .conf di WireGuard

# --- Funzioni ---
setup_install() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"

    # Elenco interfacce WireGuard e config file
    mapfile -t ifs < <(wg show interfaces)
    if [[ ${#ifs[@]} -eq 0 ]]; then
        echo "❌ Nessuna interfaccia WireGuard trovata"
        exit 1
    fi

    echo "Seleziona l'interfaccia WireGuard da monitorare:"
    PS3="Interfaccia (numero) > "
    iface=""
    until [[ -n "$iface" ]]; do
        select sel in "${ifs[@]}"; do
            if [[ -n "$sel" ]]; then
                iface="$sel"
                CONF_FILE="/etc/wireguard/${iface}.conf"
                echo "$iface" > "$CONFIG_FILE"
                echo "$CONF_FILE" >> "$CONFIG_FILE"
                echo "Interfaccia selezionata: $iface"
            else
                echo "Scelta non valida. Riprova."
            fi
            break
        done
    done

    # Intervallo di controllo (in secondi)
    INTERVAL=""
    until [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; do
        read -rp "Ogni quanti secondi vuoi eseguire il controllo? " INTERVAL
        if ! [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
            echo "❌ Intervallo non valido. Inserisci un numero intero > 0."
        fi
    done

    # Scrivo unit systemd
    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Monitor WireGuard peer ($iface)

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH monitor
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
n   local current_name=""
    while IFS= read -r line; do
        if [[ $line =~ ^###\ begin\ (.+)\ ### ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ $line =~ ^PublicKey\ =\ ([A-Za-z0-9+/=]+) ]]; then
            pubkey="${BASH_REMATCH[1]}"
            if [[ -n "$current_name" ]]; then
                friendly_map["$pubkey"]="$current_name"
            fi
            current_name=""
        fi
    done < "$CONF_FILE"
}

# Parsaggio stato in CSV con eventuale friendly name
parse_state() {
    local file="$1"
    local iface pubkey allowed endpoint local_ip name
    # Carico friendly names
    load_friendly
    iface=$(<"$CONFIG_FILE")
    iface=$(echo "$iface" | head -n1)
    wg show "$iface" dump | while IFS=$'\t' read -r dev pubkey preshared endpoint allowed local rx tx keep; do
        IFS=, read -r local_ip _ <<< "$allowed"
        name="${friendly_map[$pubkey]}"
        # output CSV: pubkey,local_ip,endpoint,name
        echo "$pubkey,$local_ip,$endpoint,$name"
    done > "$file"
}

# Funzione principale di monitoraggio
do_monitor() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    parse_state "$CUR_CSV"
    [[ ! -f "$PREV_CSV" ]] && mv "$CUR_CSV" "$PREV_CSV" && exit 0

    declare -A prev_endpoint prev_local prev_name
    # Carico precedente
    while IFS=, read -r pub loc end name; do
        prev_endpoint["$pub"]="$end"
        prev_local["$pub"]="$loc"
        prev_name["$pub"]="$name"
    done < "$PREV_CSV"

    # Verifico correnti
    while IFS=, read -r pub loc end name; do
        timestamp="$(date '+%F %T')"
        label="$loc"
        [[ -n "$name" ]] && label="$name ($loc)"
        if [[ -z "${prev_endpoint[$pub]}" ]]; then
            echo "[$timestamp] Nuova connessione per client $label da ip remoto $end" >> "$LOG_DIR/$(date +%F).log"
        elif [[ "${prev_endpoint[$pub]}" != "$end" ]]; then
            echo "[$timestamp] Nuovo ip remoto per client $label: $end" >> "$LOG_DIR/$(date +%F).log"
        fi
        unset prev_endpoint["$pub"] prev_local["$pub"] prev_name["$pub"]
    done < "$CUR_CSV"

    # Rimanenti = disconnessioni
    for pub in "${!prev_endpoint[@]}"; do
        timestamp="$(date '+%F %T')"
        loc="${prev_local[$pub]}"
        name="${prev_name[$pub]}"
        label="$loc"
        [[ -n "$name" ]] && label="$name ($loc)"
        echo "[$timestamp] Client $label disconnesso" >> "$LOG_DIR/$(date +%F).log"
    done

    mv "$CUR_CSV" "$PREV_CSV"
}

# Menu e main
show_menu() {
    PS3="Scegli un'opzione: "
    local options=("Stato servizio" "Riavvia servizio" "Abilita/Disabilita" "Pulisci log >1 mese" "Rimuovi tutto" "Esci")
    select opt in "${options[@]}"; do
        case $REPLY in
            1) systemctl status wg-monitor.timer --no-pager;;
            2) systemctl restart wg-monitor.timer; echo "Servizio riavviato";;
            3)
                if systemctl is-enabled wg-monitor.timer &>/dev/null; then
                    systemctl disable --now wg-monitor.timer; echo "Servizio disabilitato"
                else
                    systemctl enable --now wg-monitor.timer; echo "Servizio abilitato"
                fi;;
            4) find "$LOG_DIR" -type f -mtime +30 -delete; echo "Log più vecchi di 1 mese cancellati";;
            5)
                systemctl disable --now wg-monitor.timer
                rm -f "$SERVICE_UNIT" "$TIMER_UNIT"
                systemctl daemon-reload
                rm -r "$STATE_DIR" "$LOG_DIR"
                echo "Tutto rimosso"; exit 0;;
            6) exit 0;;
            *) echo "Opzione non valida";;
        esac
    done
}

if [[ "$1" == "install" ]]; then
    setup_install
elif [[ "$1" == "monitor" ]]; then
    do_monitor
else
    [[ -f "$CONFIG_FILE" ]] && show_menu || { echo "Primo avvio: procedo con setup..."; setup_install; }
fi
