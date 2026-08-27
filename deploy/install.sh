#!/usr/bin/env bash
#
# Instalação isolada do AzuraCast — Web Rádio Porto do Capim
#
# Desenho: AzuraCast roda em Docker, amarrado a 127.0.0.1. O acesso público
# vem de um SITE NOVO E SEPARADO no HestiaCP, que faz proxy reverso e termina
# o TLS. O nginx do Hestia continua dono exclusivo das portas 80 e 443.
#
# Este script é IDEMPOTENTE e para no primeiro erro.
# Não roda nada destrutivo sem confirmação explícita.
#
# Uso:
#   DOMAIN=radio.exemplo.br HESTIA_USER=carlosfinezi ./install.sh --check
#   DOMAIN=radio.exemplo.br HESTIA_USER=carlosfinezi ./install.sh --apply

set -Eeuo pipefail

DOMAIN="${DOMAIN:-}"
HESTIA_USER="${HESTIA_USER:-carlosfinezi}"
AZC_DIR="${AZC_DIR:-/var/azuracast}"
MEDIA_MIN_GB=50            # alínea (e) do edital
DISK_HEADROOM_GB=25        # folga além da mídia, para não repetir incidentes de disco cheio
MODE="${1:---check}"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok()   { echo "${GRN}✓${RST} $*"; }
warn() { echo "${YEL}⚠${RST} $*"; }
die()  { echo "${RED}✗ $*${RST}" >&2; exit 1; }
step() { echo; echo "${BLD}── $* ──${RST}"; }

# ─────────────────────────────────────────────────────────────────────────
# Pré-voo: tudo que pode dar errado, verificado ANTES de mudar qualquer coisa
# ─────────────────────────────────────────────────────────────────────────
preflight() {
  step "Pré-voo"
  [[ $EUID -eq 0 ]] || die "precisa rodar como root"
  [[ -n "$DOMAIN" ]] || die "defina DOMAIN=radio.seudominio.br"

  # 1. As portas 80/443 são do Hestia e assim devem permanecer.
  local port_owner
  port_owner=$(ss -lntp 2>/dev/null | awk '$4 ~ /:(80|443)$/ {print $6}' | head -1)
  if [[ "$port_owner" == *nginx* ]]; then
    ok "80/443 pertencem ao nginx do Hestia — o AzuraCast não vai encostar neles"
  else
    warn "não identifiquei o nginx do Hestia em 80/443: '$port_owner'"
  fi

  # 2. Portas de loopback que vamos usar precisam estar livres.
  for p in 8081 8005 8010; do
    ss -lnt 2>/dev/null | grep -q ":$p " && die "porta $p já está em uso" || ok "porta $p livre"
  done

  # 3. Disco. Este host já teve incidente de backup falhando por espaço;
  #    somar 50 GB de mídia sem checar seria repetir o erro.
  local avail_gb needed_gb
  avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  needed_gb=$(( MEDIA_MIN_GB + DISK_HEADROOM_GB ))
  if (( avail_gb < needed_gb )); then
    die "disco insuficiente: ${avail_gb} GB livres, necessário ${needed_gb} GB (${MEDIA_MIN_GB} de mídia + ${DISK_HEADROOM_GB} de folga)"
  fi
  ok "disco: ${avail_gb} GB livres (necessário ${needed_gb} GB)"

  # 4. DNS precisa apontar para cá antes do Let's Encrypt tentar validar.
  local host_ip dns_ip
  host_ip=$(hostname -I | awk '{print $1}')
  dns_ip=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ -z "$dns_ip" ]]; then
    warn "DNS de $DOMAIN não resolve ainda — o Let's Encrypt vai falhar até propagar"
  elif [[ "$dns_ip" != "$host_ip" ]]; then
    warn "DNS de $DOMAIN aponta para $dns_ip, mas este host é $host_ip"
  else
    ok "DNS de $DOMAIN resolve para este host ($host_ip)"
  fi

  # 5. Hestia e usuário.
  [[ -d /usr/local/hestia ]] || die "HestiaCP não encontrado"
  [[ -d "/home/$HESTIA_USER" ]] || die "usuário Hestia '$HESTIA_USER' não existe"
  ok "HestiaCP presente, usuário $HESTIA_USER existe"

  # 6. Aviso sobre o Docker no host de produção.
  if command -v docker >/dev/null 2>&1; then
    ok "Docker já instalado ($(docker --version))"
  else
    warn "Docker será INSTALADO. Ele altera regras de netfilter."
    warn "Mitigação aplicada: todas as portas ficam em 127.0.0.1, então"
    warn "nenhuma regra do Docker expõe serviço para fora."
  fi
}

# ─────────────────────────────────────────────────────────────────────────
install_docker() {
  step "Docker"
  if command -v docker >/dev/null 2>&1; then ok "já instalado"; return; fi

  # Configura o daemon ANTES de subir, para nunca existir uma janela em que
  # o Docker esteja ativo com padrões que conflitem com o firewall do Hestia.
  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'JSON'
{
  "ip": "127.0.0.1",
  "iptables": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
    ok "daemon.json criado: publicação padrão amarrada a 127.0.0.1"
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "Docker instalado"
}

# ─────────────────────────────────────────────────────────────────────────
install_azuracast() {
  step "AzuraCast"
  mkdir -p "$AZC_DIR"
  cd "$AZC_DIR"

  if [[ ! -f docker-compose.yml ]]; then
    curl -fsSL https://raw.githubusercontent.com/AzuraCast/AzuraCast/main/docker-compose.sample.yml \
      -o docker-compose.yml
    ok "docker-compose.yml obtido"
  fi

  # O override é o que garante o isolamento em loopback.
  cp "$(dirname "$(realpath "$0")")/docker-compose.override.yml" "$AZC_DIR/docker-compose.override.yml"
  ok "override de isolamento aplicado"

  if [[ ! -f azuracast.env ]]; then
    cat > azuracast.env <<ENVEOF
# Web Rádio Porto do Capim
LANG=pt_BR.UTF-8
AZURACAST_HTTP_PORT=8081
AZURACAST_HTTPS_PORT=0
# Atrás do proxy do Hestia: o AzuraCast precisa saber a URL pública real
# para montar corretamente os links do painel e as URLs dos manifestos HLS.
AZURACAST_BASE_URL=https://${DOMAIN}
ENABLE_ADVANCED_FEATURES=true
# TLS é terminado pelo nginx do Hestia; o contêiner não gerencia certificado.
LETSENCRYPT_HOST=
ENVEOF
    ok "azuracast.env criado (base URL https://${DOMAIN})"
  fi

  docker compose pull -q
  docker compose up -d
  ok "contêineres no ar"

  # Confirma que NADA vazou para fora do loopback.
  step "Verificação de isolamento"
  local leaked
  leaked=$(ss -lnt 2>/dev/null | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):(8081|800[0-9]|801[0-9]|802[0-5])$/ {print $4}')
  if [[ -n "$leaked" ]]; then
    die "VAZAMENTO: portas expostas fora do loopback: $leaked — rode 'docker compose down' agora"
  fi
  ok "nenhuma porta do AzuraCast exposta fora de 127.0.0.1"
}

# ─────────────────────────────────────────────────────────────────────────
setup_site() {
  step "Site novo no HestiaCP: $DOMAIN"
  local V=/usr/local/hestia/bin

  if $V/v-list-web-domain "$HESTIA_USER" "$DOMAIN" >/dev/null 2>&1; then
    ok "domínio já existe no Hestia"
  else
    $V/v-add-web-domain "$HESTIA_USER" "$DOMAIN"
    ok "domínio criado"
  fi

  # Template proxy do Hestia costuma apontar o nginx para ele mesmo e gerar
  # "400 header too large". Removemos o proxy e usamos só nosso template.
  $V/v-delete-web-domain-proxy "$HESTIA_USER" "$DOMAIN" 2>/dev/null || true

  local TPL_DIR=/usr/local/hestia/data/templates/web/nginx/php-fpm
  cp "$(dirname "$(realpath "$0")")/nginx-proxy.conf" "$TPL_DIR/webradio.stpl"
  sed 's/%web_ssl_port%/%web_port%/; s/ ssl;/;/; /ssl_certificate/d; /ssl_protocols/d' \
    "$TPL_DIR/webradio.stpl" > "$TPL_DIR/webradio.tpl"
  ok "template nginx 'webradio' instalado"

  $V/v-change-web-domain-tpl "$HESTIA_USER" "$DOMAIN" webradio
  $V/v-add-letsencrypt-domain "$HESTIA_USER" "$DOMAIN" || \
    warn "Let's Encrypt falhou — verifique o DNS e rode: v-add-letsencrypt-domain $HESTIA_USER $DOMAIN"
  $V/v-rebuild-web-domain "$HESTIA_USER" "$DOMAIN"
  ok "site publicado em https://$DOMAIN"
}

# ─────────────────────────────────────────────────────────────────────────
case "$MODE" in
  --check)
    preflight
    echo; echo "${GRN}${BLD}Pré-voo concluído. Nada foi alterado.${RST}"
    echo "Para aplicar de fato:  DOMAIN=$DOMAIN HESTIA_USER=$HESTIA_USER $0 --apply"
    ;;
  --apply)
    preflight
    echo
    read -r -p "${BLD}Aplicar as mudanças neste servidor de PRODUÇÃO? (digite CONFIRMO): ${RST}" a
    [[ "$a" == "CONFIRMO" ]] || die "abortado pelo operador"
    install_docker
    install_azuracast
    setup_site
    echo; echo "${GRN}${BLD}Pronto.${RST} Painel: https://$DOMAIN"
    echo "Rollback: cd $AZC_DIR && docker compose down && v-delete-web-domain $HESTIA_USER $DOMAIN"
    ;;
  *) die "uso: $0 [--check|--apply]" ;;
esac
