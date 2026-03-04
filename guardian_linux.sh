#!/usr/bin/env bash
# =============================================================================
# Guardian 360 - Linux Edition (Silent Console + Final API Status Only)
# - Cliente via parâmetro: -Cliente "Nome"
# - Varre automaticamente mounts em /mnt
# - SEMPRE faz reparo automático OFFLINE em ext2/3/4: umount -> e2fsck/fsck -> mount
# - Para Samba antes do fsck e volta depois (quando estava ativo)
# - NÃO imprime nada durante a execução no console
# - No FINAL, imprime apenas: API OK/FAIL (HTTP/curl_rc)
# - Tudo detalhado fica no LOG e no JSON local
# =============================================================================
set -euo pipefail
umask 077

CLIENTE=""
API_URL="https://guardian.it4you.com.br/api/insert-linux"

BASE_DIR="/root/guardian"
LOG_FILE="$BASE_DIR/guardian_linux.log"
LOCK_FILE="/var/lock/guardian_linux.lock"

mkdir -p "$BASE_DIR"
touch "$LOG_FILE"

# Evita execução simultânea
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# -------------------------
# Logging (somente arquivo)
# -------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(date '+%F %T')" "$level" "$msg" >> "$LOG_FILE"
}

# Impressão final mínima no console
final_ok() {
  # $1: mensagem
  echo "OK: $1"
}
final_fail() {
  # $1: mensagem
  echo "FAIL: $1"
}

die() {
  log ERROR "$*"
  final_fail "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Dependência ausente: $1"
}

safe_json() {
  # Retorna JSON válido ou [] (sem despejar erros no console)
  local output="${1:-}"
  if [[ -z "$output" ]]; then
    echo "[]"
    return
  fi
  if echo "$output" | jq -e . >/dev/null 2>&1; then
    echo "$output"
  else
    echo "[]"
  fi
}

# -------------------------
# PARSER
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -Cliente|--cliente)
      CLIENTE="${2:-}"
      shift 2
      ;;
    *)
      die "Parâmetro desconhecido: $1"
      ;;
  esac
done

[[ -n "$CLIENTE" ]] || die "-Cliente obrigatório"

# =============================================================================
# Garantir reboot semanal sábado 03:00 (Compatível Debian 10 e Debian 12)
# =============================================================================

REBOOT_SCHEDULE="0 3 * * 6"
CRON_TMP="/tmp/.guardian_cron.$$"

# Descobre binário válido de reboot
if command -v systemctl >/dev/null 2>&1; then
  REBOOT_CMD="/usr/bin/systemctl reboot"
else
  REBOOT_CMD="$(command -v reboot || true)"
fi

# Se não existir comando válido, aborta silenciosamente
if [[ -z "${REBOOT_CMD:-}" ]]; then
  rm -f "$CRON_TMP"
else
  # Obtém crontab atual (se existir)
  if ! crontab -l > "$CRON_TMP" 2>/dev/null; then
    : > "$CRON_TMP"
  fi

  # Verifica se já existe reboot sábado 03:00
  if ! grep -Eqs '^[[:space:]]*0[[:space:]]+3[[:space:]]+\*[[:space:]]+\*[[:space:]]+6[[:space:]]+.*(reboot|systemctl)' "$CRON_TMP"; then
    echo "$REBOOT_SCHEDULE $REBOOT_CMD" >> "$CRON_TMP"
    crontab "$CRON_TMP"
  fi

  rm -f "$CRON_TMP"
fi



# -------------------------
# DEPENDÊNCIAS
# -------------------------
need_cmd jq
need_cmd curl
need_cmd hostname
need_cmd date
need_cmd uname
need_cmd findmnt
need_cmd lsblk
need_cmd df
need_cmd ip
need_cmd mountpoint
need_cmd mount
need_cmd umount
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd cut
need_cmd xargs
need_cmd nproc
need_cmd free
need_cmd uptime
need_cmd who

FSCK_BIN=""
if command -v e2fsck >/dev/null 2>&1; then
  FSCK_BIN="e2fsck"
elif command -v fsck >/dev/null 2>&1; then
  FSCK_BIN="fsck"
else
  die "Nem e2fsck nem fsck encontrados"
fi

log INFO "Execução iniciada (cliente=$CLIENTE, fsck=$FSCK_BIN)"

# =============================================================================
# SAMBA CONTROL (stop/start)
# =============================================================================
SAMBA_WAS_ACTIVE="false"
SAMBA_UNITS_ACTIVE=()

detect_samba_units() {
  SAMBA_UNITS_ACTIVE=()
  SAMBA_WAS_ACTIVE="false"

  command -v systemctl >/dev/null 2>&1 || return 0

  local candidates=(smbd nmbd samba smb winbind)
  local list
  list="$(systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' || true)"

  for u in "${candidates[@]}"; do
    if echo "$list" | grep -qx "${u}.service"; then
      if [[ "$(systemctl is-active "${u}.service" 2>/dev/null || true)" == "active" ]]; then
        SAMBA_UNITS_ACTIVE+=("${u}.service")
        SAMBA_WAS_ACTIVE="true"
      fi
    fi
  done
}

stop_samba_if_running() {
  detect_samba_units
  [[ "$SAMBA_WAS_ACTIVE" == "true" ]] || return 0

  log INFO "SAMBA: parando serviços: ${SAMBA_UNITS_ACTIVE[*]}"
  for unit in "${SAMBA_UNITS_ACTIVE[@]}"; do
    systemctl stop "$unit" 2>/dev/null || true
  done
}

start_samba_back_if_needed() {
  [[ "$SAMBA_WAS_ACTIVE" == "true" ]] || return 0

  log INFO "SAMBA: subindo serviços: ${SAMBA_UNITS_ACTIVE[*]}"
  for unit in "${SAMBA_UNITS_ACTIVE[@]}"; do
    systemctl start "$unit" 2>/dev/null || true
  done
}

# Garante tentativa de reativar Samba ao sair (inclusive em erro)
trap 'start_samba_back_if_needed' EXIT

# =============================================================================
# COLETORES (JSON) - sem saída no console
# =============================================================================
collect_hardware() {
  local distro kernel processador cores ram
  distro="$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")"
  kernel="$(uname -r 2>/dev/null || echo "unknown")"
  processador="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "unknown")"
  cores="$(nproc 2>/dev/null || echo 0)"
  ram="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)"

  jq -n \
    --arg distro "$distro" \
    --arg kernel "$kernel" \
    --arg processador "$processador" \
    --argjson cores "$cores" \
    --argjson ram "$ram" \
    '{distro:$distro,kernel:$kernel,processador:$processador,cores:$cores,ram_total_gb:$ram}'
}

collect_disks() {
  local virt="false"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --quiet && virt="true" || true
  fi

  local out
  out="$(
    lsblk -d -b -n -o NAME,SIZE,ROTA,MODEL 2>/dev/null |
      awk '
        $1 ~ /^(sd|vd|nvme)/ {
          name=$1; size=$2; rota=$3;
          model="";
          for (i=4;i<=NF;i++) model = model (i==4 ? "" : " ") $i;
          print name "|" size "|" rota "|" model
        }
      ' |
      while IFS="|" read -r name size rota model; do
        local tipo smart_status
        if [[ "$virt" == "true" ]]; then
          tipo="Virtual"; smart_status="VirtualDisk"
        else
          [[ "$rota" == "0" ]] && tipo="SSD" || tipo="HDD"
          smart_status="Unknown"
        fi

        jq -n \
          --arg device "/dev/$name" \
          --arg modelo "${model:-unknown}" \
          --arg tipo "$tipo" \
          --argjson capacidade_gb "$(( size / 1073741824 ))" \
          --arg smart_status "$smart_status" \
          '{device:$device,modelo:$modelo,tipo:$tipo,capacidade_gb:$capacidade_gb,smart_status:$smart_status}'
      done | jq -s '.'
  )"
  safe_json "$out"
}

collect_partitions() {
  local out
  out="$(
    df -T -BG -x tmpfs -x devtmpfs 2>/dev/null |
      awk 'NR>1 && $1 ~ "^/dev" {
        gsub("G","",$3); gsub("G","",$4); gsub("G","",$5);
        gsub("%","",$6);
        print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7
      }' |
      while IFS="|" read -r dev fstype size used avail pct mnt; do
        jq -n \
          --arg device "$dev" \
          --arg filesystem "$fstype" \
          --argjson tamanho_gb "$size" \
          --argjson usado_gb "$used" \
          --argjson livre_gb "$avail" \
          --argjson usado_pct "$pct" \
          --arg montado_em "$mnt" \
          '{device:$device,filesystem:$filesystem,tamanho_gb:$tamanho_gb,usado_gb:$usado_gb,livre_gb:$livre_gb,usado_pct:$usado_pct,montado_em:$montado_em}'
      done | jq -s '.'
  )"
  safe_json "$out"
}

collect_network() {
  local gw dns1 dns2
  gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}' || true)"
  dns1="$(awk '/nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
  dns2="$(awk '/nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | sed -n '2p' || true)"

  local out
  out="$(
    ip -o -4 addr show 2>/dev/null |
      while read -r line; do
        local iface ipaddr mac status speed
        iface="$(echo "$line" | awk '{print $2}')"
        [[ "$iface" == "lo" ]] && continue
        ipaddr="$(echo "$line" | awk '{print $4}' | cut -d/ -f1)"
        mac="$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo "")"
        status="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")"
        speed="unknown"
        if command -v ethtool >/dev/null 2>&1; then
          speed="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {print $2; exit}' || echo "unknown")"
        fi

        jq -n \
          --arg interface "$iface" \
          --arg ip "$ipaddr" \
          --arg mac "$mac" \
          --arg gateway "$gw" \
          --arg dns_primario "$dns1" \
          --arg dns_secundario "$dns2" \
          --arg status "$status" \
          --arg velocidade "$speed" \
          '{interface:$interface,ip:$ip,mac:$mac,gateway:$gateway,dns_primario:$dns_primario,dns_secundario:$dns_secundario,status:$status,velocidade:$velocidade}'
      done | jq -s '.'
  )"
  safe_json "$out"
}

collect_cron() {
  local out
  out="$(
    { crontab -l 2>/dev/null || true; } |
      sed '/^\s*#/d;/^\s*$/d' |
      while IFS= read -r line; do
        local sched cmd
        if [[ "$line" == @* ]]; then
          sched="${line%% *}"
          cmd="${line#* }"
        else
          sched="$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')"
          cmd="$(echo "$line" | cut -d' ' -f6-)"
        fi
        jq -n --arg usuario "root" --arg schedule "$sched" --arg comando "$cmd" \
          '{usuario:$usuario,schedule:$schedule,comando:$comando}'
      done | jq -s '.'
  )"
  safe_json "$out"
}

collect_services() {
  local out
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[]"
    return
  fi

  out="$(
    for s in smbd nmbd winbind ssh sshd cron crond apache2 nginx mysql mariadb postgresql docker; do
      local status enabled
      status="$(systemctl is-active "$s" 2>/dev/null || true)"
      [[ -z "$status" || "$status" == "unknown" ]] && continue
      enabled="$(systemctl is-enabled "$s" 2>/dev/null || echo "unknown")"
      jq -n --arg nome "$s" --arg status "$status" --arg enabled "$enabled" \
        '{nome:$nome,status:$status,enabled:$enabled}'
    done | jq -s '.'
  )"
  safe_json "$out"
}

collect_users() {
  local out
  out="$(
    awk -F: '($3>=1000 || $3==0) {print $1":"$3":"$4":"$6":"$7}' /etc/passwd 2>/dev/null |
      while IFS=: read -r u uid gid home shell; do
        jq -n \
          --arg usuario "$u" \
          --argjson uid "$uid" \
          --argjson gid "$gid" \
          --arg home "$home" \
          --arg shell "$shell" \
          '{usuario:$usuario,uid:$uid,gid:$gid,home:$home,shell:$shell,ultimo_login:"Unknown"}'
      done | jq -s '.'
  )"
  safe_json "$out"
}

# =============================================================================
# CRASHPLAN CONTROL (stop/clear cache/start) - silencioso no console (log only)
# =============================================================================
if [[ -x "/usr/local/crashplan/bin/service.sh" ]]; then
  log INFO "CRASHPLAN: parando serviço"
  /usr/local/crashplan/bin/./service.sh stop >/dev/null 2>&1 || true

  log INFO "CRASHPLAN: limpando cache (/usr/local/crashplan/cache/*)"
  rm -fr /usr/local/crashplan/cache/* >/dev/null 2>&1 || true

  log INFO "CRASHPLAN: iniciando serviço"
  /usr/local/crashplan/bin/./service.sh start >/dev/null 2>&1 || true
else
  log INFO "CRASHPLAN: service.sh não encontrado/executável, pulando"
fi

# =============================================================================
# REPARO AUTOMÁTICO OFFLINE em /mnt
# =============================================================================
repair_mnt_filesystems() {
  log INFO "FS_REPAIR: iniciando (/mnt, auto-reparo offline)"
  stop_samba_if_running

  mapfile -t lines < <(
    findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null |
      awk '$1 ~ "^/mnt/" {print $1 "|" $2 "|" $3 "|" $4}' |
      awk -F'|' '{ print length($1) "|" $0 }' |
      sort -t'|' -k1,1nr |
      cut -d'|' -f2-
  )

  local out
  out="$(
    for entry in "${lines[@]:-}"; do
      IFS='|' read -r mp dev fstype opts <<< "$entry"
      mp="${mp:-}"; dev="${dev:-}"; fstype="${fstype:-}"; opts="${opts:-}"

      if [[ -z "$mp" || -z "$dev" || -z "$fstype" ]]; then
        jq -n --arg mount "$mp" --arg device "$dev" --arg fstype "$fstype" \
          '{mountpoint:$mount,device:$device,fstype:$fstype,status:"FAIL_META",details:"metadados incompletos do findmnt"}'
        continue
      fi

      case "$fstype" in
        ext2|ext3|ext4) ;;
        *)
          jq -n --arg mount "$mp" --arg device "$dev" --arg fstype "$fstype" \
            '{mountpoint:$mount,device:$device,fstype:$fstype,status:"SKIPPED",details:"fstype não suportado para fsck offline automático"}'
          continue
          ;;
      esac

      if ! mountpoint -q "$mp"; then
        jq -n --arg mount "$mp" --arg device "$dev" --arg fstype "$fstype" \
          '{mountpoint:$mount,device:$device,fstype:$fstype,status:"UNMOUNTED",details:"não estava montado"}'
        continue
      fi

      log INFO "FS_REPAIR: umount $mp ($dev)"
      busy_info=""
      if ! umount "$mp" 2>/dev/null; then
        if command -v fuser >/dev/null 2>&1; then
          busy_info="$(fuser -vm "$mp" 2>&1 || true)"
        fi
        log ERROR "FS_REPAIR: falha umount $mp"
        jq -n --arg mount "$mp" --arg device "$dev" --arg fstype "$fstype" --arg busy "$busy_info" \
          '{mountpoint:$mount,device:$device,fstype:$fstype,status:"FAIL_UMOUNT",busy_processes:$busy}'
        continue
      fi

      log INFO "FS_REPAIR: fsck offline $dev"
      rc1=0; rc2=0
      mode=""

      if [[ "$FSCK_BIN" == "e2fsck" ]]; then
        mode="e2fsck -p -f"
        if ! e2fsck -p -f "$dev" >/dev/null 2>&1; then rc1=$?; fi
        if (( (rc1 & 4) != 0 )); then
          mode="e2fsck -p -f + e2fsck -y -f"
          if ! e2fsck -y -f "$dev" >/dev/null 2>&1; then rc2=$?; fi
        fi
      else
        mode="fsck -p -f"
        if ! fsck -p -f "$dev" >/dev/null 2>&1; then rc1=$?; fi
        if (( (rc1 & 4) != 0 )); then
          mode="fsck -p -f + fsck -y -f"
          if ! fsck -y -f "$dev" >/dev/null 2>&1; then rc2=$?; fi
        fi
      fi

      log INFO "FS_REPAIR: mount $mp"
      remount_ok=true
      if ! mount "$mp" 2>/dev/null; then
        if [[ -n "$opts" ]]; then
          if ! mount -t "$fstype" -o "$opts" "$dev" "$mp" 2>/dev/null; then remount_ok=false; fi
        else
          if ! mount -t "$fstype" "$dev" "$mp" 2>/dev/null; then remount_ok=false; fi
        fi
      fi

      status="OK"
      details="reparo concluído"

      # fsck exit code bitmask: 4=erros não corrigidos, 8=erro operacional
      if (( (rc1 & 8) != 0 || (rc2 & 8) != 0 )); then
        status="FAIL_FSCK_OPERROR"
        details="fsck retornou erro operacional"
      elif (( (rc2 & 4) != 0 )); then
        status="FAIL_FSCK_UNCORRECTED"
        details="erros permaneceram mesmo após -y"
      fi

      if [[ "$remount_ok" != "true" ]]; then
        status="FAIL_REMOUNT"
        details="não foi possível remontar após fsck"
      fi

      jq -n \
        --arg mount "$mp" \
        --arg device "$dev" \
        --arg fstype "$fstype" \
        --arg status "$status" \
        --arg fsck_mode "$mode" \
        --argjson fsck_rc_stage1 "$rc1" \
        --argjson fsck_rc_stage2 "$rc2" \
        --arg details "$details" \
        '{
          mountpoint:$mount, device:$device, fstype:$fstype,
          status:$status, fsck_mode:$fsck_mode,
          fsck_rc_stage1:$fsck_rc_stage1, fsck_rc_stage2:$fsck_rc_stage2,
          details:$details
        }'
    done | jq -s '.'
  )"

  start_samba_back_if_needed
  log INFO "FS_REPAIR: finalizado"

  safe_json "$out"
}

# =============================================================================
# EXECUÇÃO PRINCIPAL (silenciosa no console)
# =============================================================================
HARDWARE="$(collect_hardware)"
DISCOS="$(collect_disks)"
PARTICOES="$(collect_partitions)"
REDES="$(collect_network)"
SERVICOS="$(collect_services)"
CRONJOBS="$(collect_cron)"
USUARIOS="$(collect_users)"
FS_REPAIR="$(repair_mnt_filesystems)"

HOSTNAME="$(hostname)"
UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo unknown)"
DATA="$(date '+%Y-%m-%d %H:%M:%S')"
UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //')"
ULTIMO_BOOT="$(who -b 2>/dev/null | awk '{print $3" "$4}' || echo "")"

JSON="$(
  jq -n \
    --arg cliente "$CLIENTE" \
    --arg hostname "$HOSTNAME" \
    --arg tipo "fileserver" \
    --arg uuid "$UUID" \
    --arg data_coleta "$DATA" \
    --arg uptime "$UPTIME" \
    --arg ultimo_boot "$ULTIMO_BOOT" \
    --argjson hardware "$HARDWARE" \
    --argjson discos "$DISCOS" \
    --argjson particoes "$PARTICOES" \
    --argjson redes "$REDES" \
    --argjson servicos "$SERVICOS" \
    --argjson cron "$CRONJOBS" \
    --argjson usuarios "$USUARIOS" \
    --argjson fs_repair "$FS_REPAIR" \
    '{
      cliente:$cliente, hostname:$hostname, tipo:$tipo, uuid:$uuid,
      data_coleta:$data_coleta, uptime:$uptime, ultimo_boot:$ultimo_boot,
      hardware:$hardware, discos:$discos, particoes:$particoes, redes:$redes,
      servicos:$servicos, cron:$cron, usuarios:$usuarios,
      fs_repair:$fs_repair, smart:[]
    }'
)"

echo "$JSON" | jq -e . >/dev/null 2>&1 || die "JSON inválido"

FILE="$BASE_DIR/${HOSTNAME}_$(date +%Y%m%d_%H%M%S).json"
echo "$JSON" > "$FILE"
log INFO "JSON salvo: $FILE"

# =============================================================================
# ENVIO PARA API (somente resultado final no console)
# =============================================================================
API_OK="false"
LAST_HTTP="(sem)"
LAST_CURL_RC="(sem)"
LAST_BODY_SNIP=""

for i in 1 2 3; do
  log INFO "API: tentativa $i"

  set +e
  RESPONSE="$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$JSON")"
  CURL_RC=$?
  set -e

  HTTP_CODE="$(echo "$RESPONSE" | tail -n1)"
  BODY="$(echo "$RESPONSE" | sed '$d')"

  LAST_HTTP="$HTTP_CODE"
  LAST_CURL_RC="$CURL_RC"
  LAST_BODY_SNIP="$(echo "$BODY" | tr '\n' ' ' | cut -c1-200)"

  if [[ $CURL_RC -eq 0 && "$HTTP_CODE" == "200" ]]; then
    API_OK="true"
    log INFO "API OK (HTTP 200). Body(trecho): $LAST_BODY_SNIP"
    break
  else
    log WARNING "API falhou (curl_rc=$CURL_RC HTTP=$HTTP_CODE). Body(trecho): $LAST_BODY_SNIP"
    sleep 3
  fi
done

if [[ "$API_OK" == "true" ]]; then
  final_ok "API OK (HTTP 200). JSON local: $FILE"
  exit 0
else
  final_fail "API FALHOU (curl_rc=$LAST_CURL_RC HTTP=$LAST_HTTP). JSON local: $FILE"
  exit 1
fi