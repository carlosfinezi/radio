#!/usr/bin/env bash
#
# Instalação isolada do AzuraCast — Web Rádio Porto do Capim
#
# Desenho: AzuraCast em Docker, TODA porta amarrada a 127.0.0.1. O acesso
# público vem de um site novo e separado no HestiaCP, que faz proxy reverso e
# termina o TLS. O nginx do Hestia segue dono exclusivo de 80 e 443.
#
# CONTEXTO DE RISCO: este host serve sistemas de votação de câmaras municipais
# (tenants VotoAqui) e o liciteagora. Um erro aqui não é um deploy quebrado, é
# uma cidade sem sessão legislativa. Daí o pré-voo extenso e as três camadas de
# isolamento (daemon.json + !override + verificação pós-subida).
#
# Uso:
#   DOMAIN=radio.exemplo.br HESTIA_USER=carlosfinezi ./install.sh --check
#   DOMAIN=radio.exemplo.br HESTIA_USER=carlosfinezi ./install.sh --apply

set -Eeuo pipefail

DOMAIN="${DOMAIN:-}"
HESTIA_USER="${HESTIA_USER:-carlosfinezi}"
AZC_DIR="${AZC_DIR:-/var/azuracast}"
MEDIA_MIN_GB=50
DISK_HEADROOM_GB=25
MODE="${1:---check}"
AQUI="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
V=/usr/local/hestia/bin

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok()   { echo "${GRN}✓${RST} $*"; }
warn() { echo "${YEL}⚠${RST} $*"; }
die()  { echo "${RED}✗ $*${RST}" >&2; exit 1; }
step() { echo; echo "${BLD}── $* ──${RST}"; }

# ─────────────────────────────────────────────────────────────────────────
preflight() {
  step "Pré-voo"
  [[ $EUID -eq 0 ]] || die "precisa rodar como root"
  [[ -n "$DOMAIN" ]] || die "defina DOMAIN=radio.seudominio.br"
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "DOMAIN '$DOMAIN' não parece um domínio válido"

  # ── Guarda contra sequestro de domínio em produção ────────────────────
  # A versão anterior dizia "domínio já existe" e seguia adiante trocando o
  # template e refazendo o vhost. `DOMAIN=votoaqui.com.br ./install.sh
  # --apply` teria apontado o apex do VotoAqui para o AzuraCast.
  if $V/v-list-web-domain "$HESTIA_USER" "$DOMAIN" >/dev/null 2>&1; then
    # O template é o campo TPL. Extrair por posição em `plain` pegava o IP.
    # Falhava fechado (bloqueava tudo), mas por acidente, não por desenho.
    local tpl
    tpl=$($V/v-list-web-domain "$HESTIA_USER" "$DOMAIN" json 2>/dev/null \
          | jq -r '.[].TPL // empty' 2>/dev/null | head -1)
    [[ -n "$tpl" ]] || tpl="(desconhecido)"
    if [[ "$tpl" != "webradio" ]]; then
      die "o domínio '$DOMAIN' JÁ EXISTE neste servidor usando o template '$tpl'.
   Reconfigurá-lo apontaria um site em produção para o AzuraCast.
   Se a intenção é mesmo essa, remova o domínio antes, de forma consciente."
    fi
    ok "domínio já existe e já usa o template webradio (reexecução segura)"
  else
    ok "domínio '$DOMAIN' é novo — nenhum site existente será tocado"
  fi

  # ── Backend web precisa ser nginx puro ────────────────────────────────
  # Com apache2 por trás, v-change-web-domain-tpl falharia DEPOIS de criar o
  # domínio, deixando estado parcial.
  if [[ ! -d /usr/local/hestia/data/templates/web/nginx/php-fpm ]]; then
    die "template dir do nginx/php-fpm não encontrado — backend web incompatível"
  fi
  ok "backend web nginx/php-fpm presente"

  # ── Portas 80/443 continuam do Hestia ─────────────────────────────────
  local dono
  dono=$(ss -lntp 2>/dev/null | awk '$4 ~ /:(80|443)$/ {print $6}' | head -1)
  [[ "$dono" == *nginx* ]] && ok "80/443 pertencem ao nginx do Hestia" \
                           || warn "não identifiquei o nginx do Hestia em 80/443: '$dono'"

  for p in 8081 8005 8010; do
    ss -lnt 2>/dev/null | grep -q ":$p " && die "porta $p já está em uso" || ok "porta $p livre"
  done

  # ── Disco ─────────────────────────────────────────────────────────────
  # Mede o volume onde a mídia vai realmente morar. `df /` mediria o
  # filesystem errado se /var estiver em mount separado.
  local alvo avail_gb needed_gb
  alvo="$AZC_DIR"; while [[ ! -d "$alvo" && "$alvo" != "/" ]]; do alvo=$(dirname "$alvo"); done
  avail_gb=$(df -BG --output=avail "$alvo" | tail -1 | tr -dc '0-9')
  needed_gb=$(( MEDIA_MIN_GB + DISK_HEADROOM_GB ))
  (( avail_gb >= needed_gb )) \
    || die "disco insuficiente em $(df --output=target "$alvo" | tail -1): ${avail_gb} GB livres, necessário ${needed_gb} GB"
  ok "disco: ${avail_gb} GB livres em $(df --output=target "$alvo" | tail -1)"

  # ── DNS ───────────────────────────────────────────────────────────────
  local host_ip dns_ip
  host_ip=$(hostname -I | awk '{print $1}')
  dns_ip=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
  if [[ -z "$dns_ip" ]]; then
    warn "DNS de $DOMAIN não resolve — o Let's Encrypt falhará até propagar"
  elif [[ "$dns_ip" != "$host_ip" ]]; then
    warn "DNS de $DOMAIN aponta para $dns_ip, mas este host é $host_ip"
  else
    ok "DNS de $DOMAIN resolve para este host ($host_ip)"
  fi

  [[ -d "/home/$HESTIA_USER" ]] || die "usuário Hestia '$HESTIA_USER' não existe"
  ok "usuário $HESTIA_USER existe"

  # ── Compose precisa suportar a tag !override ──────────────────────────
  if command -v docker >/dev/null 2>&1; then
    local cv
    cv=$(docker compose version --short 2>/dev/null || echo "0")
    ok "Docker presente; Compose $cv"
    if ! printf '%s\n2.24.0\n' "$cv" | sort -V -C; then
      warn "Compose $cv pode não suportar a tag !override (precisa >= 2.24)."
      warn "Sem ela, o override SOMA portas em vez de substituir — perigoso aqui."
    fi
  else
    warn "Docker será INSTALADO (altera regras de netfilter)."
    warn "Mitigação: daemon.json com \"ip\": \"127.0.0.1\" ANTES de qualquer subida."
  fi
}

# ─────────────────────────────────────────────────────────────────────────
# Camada 1 de isolamento: default de publicação no loopback.
# Aplicada SEMPRE, inclusive com Docker pré-instalado — era o furo da versão
# anterior, que só escrevia daemon.json quando instalava o Docker do zero.
configurar_daemon() {
  step "Docker daemon: publicação padrão em 127.0.0.1"
  mkdir -p /etc/docker
  local atual=""
  [[ -f /etc/docker/daemon.json ]] && atual=$(cat /etc/docker/daemon.json)

  if grep -q '"ip"[[:space:]]*:[[:space:]]*"127.0.0.1"' <<<"$atual"; then
    ok "daemon.json já publica em 127.0.0.1 por padrão"
    return
  fi

  if [[ -n "$atual" ]]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    command -v jq >/dev/null || die "daemon.json já existe e o jq não está instalado; ajuste \"ip\": \"127.0.0.1\" à mão"
    jq '. + {ip:"127.0.0.1"}' <<<"$atual" > /etc/docker/daemon.json
    ok "daemon.json existente preservado (backup criado) e ajustado"
  else
    cat > /etc/docker/daemon.json <<'JSON'
{
  "ip": "127.0.0.1",
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
    ok "daemon.json criado"
  fi
  # NÃO usar `cmd && { ...; }` aqui.
  # Sob `set -e`, uma lista AND-OR cujo primeiro comando falha faz a FUNÇÃO
  # inteira retornar não-zero, e o script morre em silêncio. Foi exatamente o
  # que aconteceu em 27/08/2026: `systemctl is-active --quiet docker` devolve 4
  # quando o Docker não está instalado, e o instalador abortou logo depois de
  # imprimir "daemon.json criado", sem mensagem de erro nenhuma.
  if systemctl is-active --quiet docker; then
    systemctl restart docker
    ok "docker reiniciado para aplicar o daemon.json"
  else
    ok "docker ainda não está ativo — daemon.json valerá na primeira subida"
  fi
}

install_docker() {
  # Mesma armadilha da função acima: com `&& { ...; return; }`, a ausência do
  # Docker (o caso normal na primeira execução) derrubaria o script aqui.
  if command -v docker >/dev/null 2>&1; then
    ok "Docker já instalado ($(docker --version))"
    return 0
  fi
  step "Instalando Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
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
  mkdir -p "$AZC_DIR"; cd "$AZC_DIR"

  [[ -f docker-compose.yml ]] || {
    curl -fsSL https://raw.githubusercontent.com/AzuraCast/AzuraCast/main/docker-compose.sample.yml -o docker-compose.yml
    ok "docker-compose.yml obtido"
  }
  cp "$AQUI/docker-compose.override.yml" "$AZC_DIR/docker-compose.override.yml"

  # Camada 2: `.env` do projeto. A interpolação ${AZURACAST_HTTP_PORT} lê
  # DAQUI, nunca de env_file:. Sem este arquivo, cai no default 80/443.
  # AZURACAST_HTTPS_PORT NÃO pode ser 0.
  # O arquivo base monta '${AZURACAST_HTTPS_PORT:-443}:${AZURACAST_HTTPS_PORT:-443}',
  # que com 0 vira '0:0' e o Compose rejeita com
  # "services.web.ports.[1] is missing a target port" — a config nem resolve.
  # O valor abaixo existe só para a interpolação ser válida: o `!override` do
  # nosso arquivo descarta as 150 portas do base (verificado: 150 -> 3), então
  # a 8443 nunca chega a ser publicada. TLS é terminado pelo nginx do Hestia.
  cat > "$AZC_DIR/.env" <<ENVEOF
AZURACAST_HTTP_PORT=8081
AZURACAST_HTTPS_PORT=8443
AZURACAST_SFTP_PORT=2022
ENVEOF
  cat > "$AZC_DIR/azuracast.env" <<ENVEOF
LANG=pt_BR.UTF-8
AZURACAST_BASE_URL=https://${DOMAIN}
ENABLE_ADVANCED_FEATURES=true
ENVEOF
  ok ".env e azuracast.env gravados"

  # ── Portão: conferir a configuração RESOLVIDA antes de subir ──────────
  # É aqui que se pega o override não fazendo efeito. Melhor abortar do que
  # descobrir com o vhost das câmaras fora do ar.
  step "Conferindo a configuração resolvida"
  # Mostra o erro REAL do compose. A versão anterior engolia a saída com
  # 2>/dev/null e chutava "(jq instalado?)", mandando o operador investigar a
  # ferramenta errada — o problema era um mapeamento de porta inválido.
  local cfg_err
  if ! cfg_err=$(docker compose config 2>&1 >/dev/null); then
    echo "$cfg_err" | head -5
    die "o compose não resolve a configuração (erro acima). NÃO subimos às cegas."
  fi

  local publicadas
  publicadas=$(docker compose config --format json \
    | jq -r '.services.web.ports[]? | "\(.published)|\(.host_ip // "0.0.0.0")"')
  [[ -n "$publicadas" ]] || die "o serviço web não declarou nenhuma porta — configuração inesperada"

  local fora
  fora=$(awk -F'|' '$2 != "127.0.0.1"' <<<"$publicadas" || true)
  if [[ -n "$fora" ]]; then
    echo "$fora" | head -10
    die "o override NÃO surtiu efeito: as portas acima publicariam fora do loopback.
   Causa provável: Compose < 2.24 (sem suporte a !override). NÃO suba assim."
  fi
  ok "todas as $(wc -l <<<"$publicadas") portas resolvidas para 127.0.0.1"

  docker compose pull -q
  docker compose up -d
  ok "contêineres no ar"

  verificar_isolamento
}

# Camada 3: verificação pós-subida, olhando as DUAS camadas onde a exposição
# pode acontecer. `ss -lnt` sozinho é cego: com userland-proxy desligado não
# existe socket em escuta, e a exposição vive só no DNAT do netfilter.
verificar_isolamento() {
  step "Verificação de isolamento"

  local vaz
  vaz=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -vE '(^\S+\s*$)' \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+|\[::\]:[0-9]+' \
        | grep -v '^127\.0\.0\.1:' || true)
  if [[ -n "$vaz" ]]; then
    echo "$vaz" | sort -u | head -20
    docker compose down
    die "VAZAMENTO: portas publicadas fora do loopback (listadas acima). Stack derrubada."
  fi
  ok "docker ps: nenhuma porta fora de 127.0.0.1"

  if iptables -t nat -S DOCKER 2>/dev/null | grep -qE '\-\-dport (80|443) '; then
    docker compose down
    die "VAZAMENTO: há DNAT do Docker para as portas 80/443. Stack derrubada."
  fi
  ok "netfilter: nenhum DNAT do Docker para 80/443"

  local hestia_ok
  hestia_ok=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://127.0.0.1:80/ 2>/dev/null || echo "erro")
  ok "nginx do Hestia responde na 80 (HTTP $hestia_ok)"
}

# ─────────────────────────────────────────────────────────────────────────
setup_site() {
  step "Site no HestiaCP: $DOMAIN"
  local TPL_DIR=/usr/local/hestia/data/templates/web/nginx/php-fpm

  # Templates gravados como arquivos separados. Gerar um do outro por sed foi
  # o que quebrou o Let's Encrypt na versão anterior.
  cp "$AQUI/webradio.tpl"  "$TPL_DIR/webradio.tpl"
  cp "$AQUI/webradio.stpl" "$TPL_DIR/webradio.stpl"
  ok "templates webradio instalados"

  $V/v-list-web-domain "$HESTIA_USER" "$DOMAIN" >/dev/null 2>&1 \
    || { $V/v-add-web-domain "$HESTIA_USER" "$DOMAIN"; ok "domínio criado"; }

  # `v-delete-web-domain-proxy` REMOVE o nginx.conf do domínio e não o
  # regenera. Sem o rebuild logo em seguida, o vhost fica só com o fragmento
  # nginx.conf_letsencrypt e o nginx nem reconhece o domínio: toda requisição
  # cai no catch-all e o desafio ACME devolve 404. O Let's Encrypt falha 100%
  # das vezes, e a mensagem não diz nada sobre vhost faltando.
  $V/v-delete-web-domain-proxy "$HESTIA_USER" "$DOMAIN" 2>/dev/null || true
  $V/v-rebuild-web-domain "$HESTIA_USER" "$DOMAIN"
  ok "vhost regenerado após remover o proxy"

  # Portão: só pedimos certificado se o desafio for de fato alcançável.
  # Cada tentativa falha incrementa o FAIL_COUNT do Hestia, que desiste do
  # domínio após 30 — queimar tentativas às cegas custa caro.
  local acme
  acme=$(curl -s -m 15 -o /dev/null -w '%{http_code}' \
         "http://${DOMAIN}/.well-known/acme-challenge/preflight" || echo "000")
  if [[ "$acme" != "200" ]]; then
    die "o desafio ACME devolveu HTTP ${acme} (esperado 200) em http://${DOMAIN}/.well-known/acme-challenge/
   Não vamos pedir certificado às cegas e queimar FAIL_COUNT.
   Verifique: DNS propagado, porta 80 alcançável de fora, vhost gerado
   (deve existir /home/${HESTIA_USER}/conf/web/${DOMAIN}/nginx.conf)."
  fi
  ok "desafio ACME alcançável (HTTP 200)"

  # ORDEM IMPORTA: o certificado é emitido com o vhost HTTP servindo o desafio
  # ACME. Só depois trocamos para o template webradio (que já traz o bloco
  # ACME no .tpl, permitindo renovação futura).
  $V/v-add-letsencrypt-domain "$HESTIA_USER" "$DOMAIN" \
    || die "Let's Encrypt falhou. Verifique o DNS e o log em /var/log/hestia/.
   NÃO seguimos sem certificado: sem TLS o app iOS (ATS) e o player web não funcionam."
  ok "certificado emitido"

  $V/v-change-web-domain-tpl "$HESTIA_USER" "$DOMAIN" webradio
  $V/v-rebuild-web-domain "$HESTIA_USER" "$DOMAIN"
  ok "site publicado em https://$DOMAIN"

  nginx -t 2>&1 | tail -2
}

# ─────────────────────────────────────────────────────────────────────────
case "$MODE" in
  --check)
    preflight
    echo; echo "${GRN}${BLD}Pré-voo concluído. Nada foi alterado.${RST}"
    echo "Para aplicar:  DOMAIN=$DOMAIN HESTIA_USER=$HESTIA_USER $0 --apply"
    ;;
  --apply)
    preflight
    echo
    echo "${BLD}Servidor:${RST} $(hostname) ($(hostname -I | awk '{print $1}'))"
    echo "${BLD}Domínio a configurar:${RST} $DOMAIN  (usuário $HESTIA_USER)"
    echo "${BLD}Sites em produção neste host:${RST} $(ls /home/*/web 2>/dev/null | grep -c '\.' || echo '?')"
    echo
    read -r -p "${BLD}Confirma aplicar em PRODUÇÃO? (digite CONFIRMO): ${RST}" a
    [[ "$a" == "CONFIRMO" ]] || die "abortado pelo operador"
    configurar_daemon
    install_docker
    configurar_daemon   # reaplica caso o Docker tenha sido instalado agora
    install_azuracast
    setup_site
    echo; echo "${GRN}${BLD}Pronto.${RST} Painel: https://$DOMAIN"
    echo "Rollback: cd $AZC_DIR && docker compose down && $V/v-delete-web-domain $HESTIA_USER $DOMAIN"
    ;;
  *) die "uso: $0 [--check|--apply]" ;;
esac
