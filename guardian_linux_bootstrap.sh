#!/usr/bin/env bash
set -euo pipefail
umask 077

CORE_URL="https://raw.githubusercontent.com/IT4You-Scripts/Guardian360_Linux/main/guardian_linux.sh"
CORE_PATH="/root/scripts/guardian_linux.sh"
TMP_PATH="/root/scripts/guardian_linux.sh.tmp"

LOG_FILE="/root/scripts/guardian_bootstrap.log"

log() {
    echo "$(date '+%F %T') $1" >> "$LOG_FILE"
}

# Garante diretório
mkdir -p /root/scripts

log "Bootstrap iniciado"

# Baixa versão nova
if curl -fsSL "$CORE_URL" -o "$TMP_PATH"; then
    log "Download do core concluído"

    # Validação mínima (evita arquivo vazio ou HTML de erro)
    if grep -q "Guardian 360 - Linux Edition" "$TMP_PATH"; then
        chmod +x "$TMP_PATH"
        mv -f "$TMP_PATH" "$CORE_PATH"
        log "Core atualizado com sucesso"
    else
        log "Falha na validação do core. Mantendo versão atual."
        rm -f "$TMP_PATH"
    fi
else
    log "Falha no download do core"
fi

# Executa core existente
if [[ -x "$CORE_PATH" ]]; then
    exec "$CORE_PATH" "$@"
else
    log "Core não encontrado ou não executável"
    exit 1
fi
