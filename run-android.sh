#!/usr/bin/env bash
set -euo pipefail

# === Deploy skrip Flutter Android (build + pasang ke device) ===
# Jalankan dari folder proyek:  ./run-android.sh [run|build|apk|install|logs]
#
# Tanpa argumen   -> flutter run (default, debug)
#   run           -> flutter run (debug)
#   run-remote    -> flutter run + hot reload dari remote (emulator/device)
#   build         -> flutter build apk (release)
#   build-debug   -> flutter build apk --debug
#   install       -> build release + install ke device
#   logs          -> logcat (filter flutter)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# --- Baca konfigurasi opsional dari file .android.env ---
# Format: VARIABEL=nilai, contoh:
#   FLUTTER_DEVICE=<device-id>
#   FLUTTER_MODE=release
if [[ -f "$ROOT/.android.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT/.android.env"
    set +a
fi

# --- Prasyarat ---
for bin in flutter; do
    command -v "$bin" >/dev/null || { echo "ERROR: $bin tidak ditemukan." >&2; exit 1; }
done

# --- Deteksi perangkat Android (untuk install/logs) ---
detect_device() {
    if ! command -v adb >/dev/null 2>&1; then
        return 1
    fi
    adb devices | awk 'NR>1 && $2=="device" {print $1; exit}'
}

# --- Jalankan flutter dengan argumen ---
run_flutter() {
    local args=("$@")
    if [[ -n "${FLUTTER_DEVICE:-}" ]]; then
        args+=(-d "$FLUTTER_DEVICE")
    fi
    flutter "${args[@]}"
}

ACTION="${1:-run}"

case "$ACTION" in
    run)
        run_flutter run
        ;;
    run-remote)
        run_flutter run --web-port 8080
        ;;
    build)
        run_flutter build apk
        ;;
    build-debug)
        run_flutter build apk --debug
        ;;
    install)
        DEVICE="$(detect_device || true)"
        if [[ -z "$DEVICE" ]]; then
            echo "ERROR: tidak ada perangkat Android yang terhubung." >&2
            echo "Nyalakan debugging USB atau emulator, lalu cek 'adb devices'." >&2
            exit 1
        fi
        echo "==> Membuild APK release..."
        flutter build apk --release
        echo "==> Memasang ke $DEVICE ..."
        adb -s "$DEVICE" install -r build/app/outputs/flutter-apk/app-release.apk
        ;;
    logs)
        if ! command -v adb >/dev/null 2>&1; then
            echo "ERROR: adb tidak ditemukan." >&2
            exit 1
        fi
        adb logcat -s flutter
        ;;
    *)
        echo "Perintah tidak dikenal: $ACTION" >&2
        echo "Gunakan: run | run-remote | build | build-debug | install | logs" >&2
        exit 1
        ;;
esac
