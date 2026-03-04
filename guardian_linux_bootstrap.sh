#!/usr/bin/env bash
set -euo pipefail
umask 077

CORE_URL="https://raw.githubusercontent.com/IT4You-Scripts/Guardian360_Linux/main/guardian_linux.sh"
CORE_PATH="/root/scripts/guardian_linux.sh"
TMP_PATH="/root/scripts/.guardian_linux.tmp"

EXPECTED_JQ_VERSION="jq-1.6"
JQ_PATH="/usr/local/bin/jq"
JQ_URL="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"

mkdir -p /root/scripts

exec 9>/var/lock/guardian_linux_bootstrap.lock
flock -n 9 || exit 0

# ------------------------------------------------------------
# Validar jq
# ------------------------------------------------------------
validate_jq() {
    if ! command -v jq >/dev/null 2>&1; then return 1; fi
    if [[ "$(jq --version 2>/dev/null)" != "$EXPECTED_JQ_VERSION" ]]; then return 1; fi
    if [[ "$(echo '{"status":"ok"}' | jq -r '.status' 2>/dev/null)" != "ok" ]]; then return 1; fi
    return 0
}

install_jq() {
    if dpkg -l 2>/dev/null | grep -q "^ii  jq "; then
        apt remove jq -y >/dev/null 2>&1 || true
    fi

    curl -fsSL "$JQ_URL" -o "$JQ_PATH"
    chmod +x "$JQ_PATH"

    export PATH="/usr/local/bin:$PATH"
    hash -r
}

if ! validate_jq; then
    install_jq
fi

if ! validate_jq; then
    echo "Falha ao validar JSON Query (jq)"
    exit 1
fi

echo "JSON Query (jq) validado"

# ------------------------------------------------------------
# Baixar core
# ------------------------------------------------------------
curl -fsSL "$CORE_URL" -o "$TMP_PATH"
chmod +x "$TMP_PATH"
mv -f "$TMP_PATH" "$CORE_PATH"

echo "O script guardian-linux.sh foi devidamente atualizado"

# ------------------------------------------------------------
# Executar core
# ------------------------------------------------------------
echo "Executando o script principal..."

exec "$CORE_PATH" "$@"