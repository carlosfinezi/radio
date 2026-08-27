#!/usr/bin/env bash
#
# Instalação do AzuraCast em Oracle Linux / RHEL / Alma / Rocky, com nginx puro.
#
# Diferenças em relação ao install.sh (Ubuntu + HestiaCP):
#   - dnf no lugar de apt
#   - arquivo em /etc/nginx/conf.d/ no lugar de template do Hestia
#   - certbot no lugar dos comandos v-*
#   - SELinux: exige liberar o booleano de proxy, senão o nginx é bloqueado
#     silenciosamente e devolve 502 sem explicação no log de erro comum
#
# Mantém intactas as três camadas de isolamento do original:
#   1. daemon.json publicando em 127.0.0.1 por padrão
#   2. `ports: !override` descartando as 150 portas do arquivo base
#   3. verificação pós-subida em docker ps + DNAT do netfilter
#
# Uso (no servidor de destino, com sudo):
#   DOMAIN=radio.1bit.net.br ./instalar-rhel.sh --check
#   DOMAIN=radio.1bit.net.br ./instalar-rhel.sh --apply

set -Eeuo pipefail

DOMAIN="${DOMAIN:-}"
AZC_DIR="${AZC_DIR:-/var/azuracast}"
MEDIA_MIN_GB=50
DISK_HEADROOM_GB=10
MODE="${1:---check}"
AQUI="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok(){ echo "${GRN}✓${RST} $*"; }
warn(){ echo "${YEL}⚠${RST} $*"; }
die(){ echo "${RED}✗ $*${RST}" >&2; exit 1; }
step(){ echo; echo "${BLD}── $* ──${RST}"; }

# ─────────────────────────────────────────────────────────────────────────
preflight() {
  step "Pré-voo"
  [[ $EUID -eq 0 ]] || die "precisa rodar como root (use sudo)"
  [[ -n "$DOMAIN" ]] || die "defina DOMAIN=radio.seudominio.br"

  command -v docker >/dev/null || die "docker não instalado"
  local cv; cv=$(docker compose version --short 2>/dev/null || echo 0)
   printf '2.24.0\n%s\n' "$cv" | sort -V -C \
    || die "Compose $cv não suporta a tag !override (precisa >= 2.24). Sem ela o override SOMA portas."
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) · Compose $cv"

  command -v nginx  >/dev/null || die "nginx não instalado"
  command -v certbot >/dev/null || die "certbot não instalado (dnf install certbot python3-certbot-nginx)"
  ok "nginx e certbot presentes"

  # Portas do AzuraCast livres
  for p in 8081 8005 8010; do
    ss -lnt 2>/dev/null | grep -q ":$p " && die "porta $p em uso" || ok "porta $p livre"
  done

  # Disco
  local avail needed
  avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  needed=$(( MEDIA_MIN_GB + DISK_HEADROOM_GB ))
  (( avail >= needed )) || die "disco insuficiente: ${avail} GB livres, necessário ${needed} GB"
  ok "disco: ${avail} GB livres"

  # DNS — sem ele o certbot falha e queima tentativa junto ao Let's Encrypt
  local ip dns
  ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  dns=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$dns" != "$ip" ]]; then
    warn "DNS de $DOMAIN aponta para '${dns:-nada}', mas este host é $ip"
    warn "O certificado NÃO será emitido enquanto isso não for corrigido."
  else
    ok "DNS de $DOMAIN resolve para este host ($ip)"
  fi

  # SELinux
  if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    if [[ "$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $3}')" == "on" ]]; then
      ok "SELinux: httpd_can_network_connect já liberado"
    else
      warn "SELinux Enforcing com httpd_can_network_connect DESLIGADO."
      warn "Sem liberar, o nginx é bloqueado ao fazer proxy para 127.0.0.1:8081"
      warn "e devolve 502 — o --apply libera automaticamente."
    fi
  fi

  # Firewall
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --list-ports 2>/dev/null | grep -qE '(^| )(80|443)/tcp' \
      && ok "firewalld: 80/443 liberados" \
      || warn "firewalld ativo sem 80/443 explícitos — verifique os serviços permitidos"
  fi
}

# ─────────────────────────────────────────────────────────────────────────
configurar_daemon() {
  step "Docker: publicação padrão em 127.0.0.1"
  mkdir -p /etc/docker
  local atual=""
  [[ -f /etc/docker/daemon.json ]] && atual=$(cat /etc/docker/daemon.json)

  if grep -q '"ip"[[:space:]]*:[[:space:]]*"127.0.0.1"' <<<"$atual"; then
    ok "daemon.json já publica em 127.0.0.1"
  else
    if [[ -n "$atual" ]]; then
      cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
      command -v jq >/dev/null || die "daemon.json existe e jq não está instalado; ajuste \"ip\":\"127.0.0.1\" à mão"
      jq '. + {ip:"127.0.0.1"}' <<<"$atual" > /etc/docker/daemon.json
      ok "daemon.json ajustado (backup criado)"
    else
      printf '{\n  "ip": "127.0.0.1",\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "50m", "max-file": "3" }\n}\n' \
        > /etc/docker/daemon.json
      ok "daemon.json criado"
    fi
    # if/else e não `cmd && {...}`: sob set -e uma lista AND-OR que falha na
    # última instrução da função derruba o script inteiro, em silêncio.
    if systemctl is-active --quiet docker; then
      systemctl restart docker
      ok "docker reiniciado"
    fi
  fi
}

configurar_selinux() {
  [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]] || return 0
  step "SELinux"
  # Sem isto o nginx NÃO consegue abrir conexão para 127.0.0.1:8081. O sintoma
  # é 502 com o backend saudável — e o motivo real só aparece no audit.log,
  # não no error.log do nginx, o que faz perder horas.
  setsebool -P httpd_can_network_connect 1
  ok "httpd_can_network_connect liberado (persistente)"
}

instalar_azuracast() {
  step "AzuraCast"
  mkdir -p "$AZC_DIR"; cd "$AZC_DIR"

  [[ -f docker-compose.yml ]] || {
    curl -fsSL https://raw.githubusercontent.com/AzuraCast/AzuraCast/main/docker-compose.sample.yml \
      -o docker-compose.yml
    ok "docker-compose.yml obtido"
  }
  cp "$AQUI/docker-compose.override.yml" ./docker-compose.override.yml

  # `.env` alimenta a INTERPOLAÇÃO do compose (monta a lista ports).
  # HTTPS_PORT não pode ser 0: viraria '0:0' e o compose recusa a config.
  cat > .env <<ENVEOF
AZURACAST_HTTP_PORT=8081
AZURACAST_HTTPS_PORT=8443
AZURACAST_SFTP_PORT=2022
ENVEOF

  if [[ ! -f azuracast.env ]]; then
    local senha; senha=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
    cat > azuracast.env <<ENVEOF
APPLICATION_ENV=production
COMPOSER_PLUGIN_MODE=false
SHOW_DETAILED_ERRORS=false
LANG=pt_BR.UTF-8

AZURACAST_BASE_URL=https://${DOMAIN}
ENABLE_ADVANCED_FEATURES=true

# Faixa de portas atribuíveis às estações. Precisa casar EXATAMENTE com o
# que o override publica: estação em porta não publicada fica inalcançável.
AUTO_ASSIGN_PORT_MIN=8005
AUTO_ASSIGN_PORT_MAX=8010

# Sem estas duas o entrypoint do MariaDB recusa inicializar e entra em
# loop de reinício, deixando só o esqueleto InnoDB.
MYSQL_PASSWORD=${senha}
MYSQL_RANDOM_ROOT_PASSWORD=yes
ENVEOF
    chmod 600 azuracast.env
    ok "azuracast.env criado"
  else
    ok "azuracast.env preservado"
  fi

  step "Conferindo a configuração resolvida"
  local err
  if ! err=$(docker compose config 2>&1 >/dev/null); then
    echo "$err" | head -5
    die "o compose não resolve a configuração. NÃO subimos às cegas."
  fi
  local fora
  fora=$(docker compose config --format json \
    | jq -r '.services.web.ports[]? | select((.host_ip // "0.0.0.0") != "127.0.0.1") | .published')
  [[ -z "$fora" ]] || { echo "$fora" | head; die "override sem efeito: portas fora do loopback"; }
  ok "todas as portas resolvidas para 127.0.0.1"

  docker compose pull -q
  docker compose up -d
  ok "contêineres no ar"

  step "Verificação de isolamento"
  local vaz
  vaz=$(docker ps --format '{{.Ports}}' \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+|\[::\]:[0-9]+' \
        | grep -v '^127\.0\.0\.1:' || true)
  if [[ -n "$vaz" ]]; then
    echo "$vaz" | sort -u | head
    docker compose down
    die "VAZAMENTO: portas fora do loopback. Stack derrubada."
  fi
  ok "nenhuma porta fora de 127.0.0.1"

  iptables -t nat -S DOCKER 2>/dev/null | grep -qE '\-\-dport (80|443) ' \
    && { docker compose down; die "DNAT do Docker para 80/443 — stack derrubada"; }
  ok "nenhum DNAT para 80/443"
}

configurar_nginx() {
  step "nginx: $DOMAIN"
  # O template fica em arquivo separado para poder ser revisado e versionado.
  sed "s/__DOMINIO__/$DOMAIN/g" "$AQUI/nginx-radio.conf.tpl" \
    > "/etc/nginx/conf.d/${DOMAIN}.conf"
  nginx -t || die "configuração do nginx inválida"
  systemctl reload nginx
  ok "site publicado em HTTP (certificado ainda não emitido)"
}

emitir_certificado() {
  step "Certificado TLS"
  local ip dns
  ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  dns=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ "$dns" != "$ip" ]]; then
    warn "DNS de $DOMAIN ainda não aponta para $ip — pulando emissão."
    warn "Depois de corrigir o DNS, rode:  certbot --nginx -d $DOMAIN"
    return 0
  fi
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    -m "atendimento@1bit.net.br" --redirect \
    || die "certbot falhou — verifique o DNS e /var/log/letsencrypt/"
  ok "certificado emitido"
}

# ─────────────────────────────────────────────────────────────────────────
case "$MODE" in
  --check) preflight; echo; echo "${GRN}${BLD}Pré-voo concluído. Nada foi alterado.${RST}" ;;
  --apply)
    preflight
    echo; read -r -p "${BLD}Aplicar em $(hostname)? (digite CONFIRMO): ${RST}" a
    [[ "$a" == "CONFIRMO" ]] || die "abortado pelo operador"
    configurar_daemon
    configurar_selinux
    instalar_azuracast
    configurar_nginx
    emitir_certificado
    echo; echo "${GRN}${BLD}Pronto.${RST} https://$DOMAIN"
    echo "Rollback: cd $AZC_DIR && docker compose down && rm /etc/nginx/conf.d/${DOMAIN}.conf && systemctl reload nginx"
    ;;
  *) die "uso: $0 [--check|--apply]" ;;
esac
