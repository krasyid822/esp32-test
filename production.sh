#!/usr/bin/env bash
set -euo pipefail

# === Production packager — proyek ESP32 + Flutter ===
# Membuat .zip berisi source code bersih (tanpa artefak build/cache/git),
# siap dikirim atau diserahkan. Tidak melakukan build apa pun.
#
# Jalankan dari root proyek:  ./production.sh
#
# Opsional: sertakan folder build/ bila diinginkan (arsip besar).
#   PRODUCTION_WITH_BUILD=1 ./production.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# --- Prasyarat ---
for bin in rsync zip; do
    command -v "$bin" >/dev/null || { echo "ERROR: $bin tidak ditemukan." >&2; exit 1; }
done

STAMP="$(date +%Y%m%d.%H%M)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# --- Daftar pengecualian (folder/berkas yang tidak masuk zip) ---
EXCLUDE_FILE="$STAGE/.pack_exclude"
cat > "$EXCLUDE_FILE" <<'EOF'
/.git
/.gitignore
.gitignore
build
/.dart_tool
.dart_tool
.cache
node_modules
.idea
.vscode
.agents
/.clangd
compile_commands.json
esp32_test.iml
dependencies.lock
*.log
sdkconfig.old
skills-lock.json
production.sh
esp32_test-*.zip
.esp.env
EOF

echo
echo "==> Menyusun staging source di $STAGE"

# Salin seluruh source, lalu bersihkan yang tidak perlu
rsync -a --exclude-from "$STAGE/.pack_exclude" ./ "$STAGE/"
rm -f "$STAGE/.pack_exclude"

# --- Bersihkan file default flutter yang bukan source ---
rm -rf "$STAGE"/web/icons 2>/dev/null || true
rm -f "$STAGE"/.metadata 2>/dev/null || true

# --- Opsional: masukkan folder build/ yang sudah ada ---
if [[ "${PRODUCTION_WITH_BUILD:-0}" == "1" ]]; then
    echo "==> Menyertakan folder build/ (arsip besar)..."
    rsync -a build/ "$STAGE/build/" 2>/dev/null || echo "   (build/ kosong/tidak ada — dilewati)"
fi

# --- Zip ---
ZIP="$ROOT/esp32_test-$STAMP.zip"
ZIP_TMP_DIR="$(mktemp -d)"
ZIP_TMP="$ZIP_TMP_DIR/esp32_test-$STAMP.zip"
echo
echo "==> Membuat $ZIP ..."
( cd "$STAGE" && zip -r -q "$ZIP_TMP" . )
mv -f "$ZIP_TMP" "$ZIP"
rm -rf "$ZIP_TMP_DIR"

echo
echo "Selesai:"
echo "  $ZIP"
echo
echo "Isi: source ESP-IDF (main/) + Flutter (lib/, android/, web/) bersih tanpa build/cache."
if [[ "${PRODUCTION_WITH_BUILD:-0}" == "1" ]]; then
    echo "Catatan: build/ disertakan (arsip besar)."
else
    echo "Catatan: build/ tidak disertakan. Jalankan 'flutter pub get' & 'idf.py build' di sisi penerima."
fi
