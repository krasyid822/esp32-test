#!/usr/bin/env bash
set -euo pipefail

# === Deploy skrip ESP32 (build + flash + monitor) ===
# Jalankan dari folder proyek:  ./run-esp.sh [build|flash|monitor|menuconfig]
#
# Tanpa argumen  -> build + flash + monitor (default)
#   build        -> build saja
#   flash        -> build + flash (tanpa monitor)
#   monitor      -> buka serial monitor
#   menuconfig   -> konfigurasi menu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# --- Lokasi export.sh ESP-IDF ---
IDF_EXPORT="${IDF_EXPORT:-/opt/esp-idf/export.sh}"

# --- Baca opsional konfigurasi dari file .esp.env ---
# Format: VARIABEL=nilai (satu per baris), contoh:
#   ESP_PORT=/dev/ttyUSB0
#   ESP_TARGET=esp32
if [[ -f "$ROOT/.esp.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT/.esp.env"
    set +a
fi

# --- Target default dari sdkconfig bila belum diatur ---
if [[ -z "${ESP_TARGET:-}" && -f "$ROOT/sdkconfig" ]]; then
    ESP_TARGET="$(grep -E '^CONFIG_IDF_TARGET=' "$ROOT/sdkconfig" | head -1 | cut -d= -f2 | tr -d '"')"
fi
ESP_TARGET="${ESP_TARGET:-esp32}"

# --- Deteksi port serial otomatis bila belum diatur ---
detect_port() {
    for p in /dev/ttyUSB* /dev/ttyACM*; do
        [[ -e "$p" ]] || continue
        printf '%s' "$p"
        return 0
    done
    return 1
}
if [[ -z "${ESP_PORT:-}" ]]; then
    ESP_PORT="$(detect_port || true)"
fi

# --- Sumber environment ESP-IDF ---
ensure_idf() {
    if ! command -v idf.py >/dev/null 2>&1; then
        if [[ -f "$IDF_EXPORT" ]]; then
            # shellcheck disable=SC1090
            source "$IDF_EXPORT"
        else
            echo "ERROR: export.sh ESP-IDF tidak ditemukan di $IDF_EXPORT" >&2
            echo "Atur IDF_EXPORT atau export IDF_PATH di .esp.env" >&2
            exit 1
        fi
    fi
}

# --- Harmoniskan target dengan sdkconfig ---
ensure_target() {
    local current=""
    [[ -f "$ROOT/sdkconfig" ]] && current="$(grep -E '^CONFIG_IDF_TARGET=' "$ROOT/sdkconfig" | head -1 | cut -d= -f2 | tr -d '"' || true)"
    if [[ -n "$current" && "$current" != "$ESP_TARGET" ]]; then
        echo "==> Set target: $ESP_TARGET"
        idf.py set-target "$ESP_TARGET"
    fi
}

# --- Cek port diperlukan ---
require_port() {
    if [[ -z "$ESP_PORT" ]]; then
        echo "ERROR: port serial tidak terdeteksi." >&2
        echo "Pasang board (cek /dev/ttyUSB* / /dev/ttyACM*)" >&2
        echo "atau set ESP_PORT di file .esp.env" >&2
        exit 1
    fi
}

# --- Jalankan idf.py ---
run_idf() {
    ensure_idf
    ensure_target
    idf.py "$@"
}

ACTION="${1:-default}"

case "$ACTION" in
    build)
        run_idf build
        ;;
    flash)
        require_port
        run_idf -p "$ESP_PORT" build flash
        ;;
    monitor)
        require_port
        run_idf -p "$ESP_PORT" monitor
        ;;
    menuconfig)
        run_idf menuconfig
        ;;
    *)
        require_port
        run_idf -p "$ESP_PORT" flash monitor
        ;;
esac
