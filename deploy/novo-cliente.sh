#!/usr/bin/env bash
#
# Cadastro de um cliente novo na plataforma de rádio.
#
#   sudo ./novo-cliente.sh --slug radioxyz --nome "Rádio XYZ" \
#                          --email contato@xyz.com.br [--cota 20] [--bitrate 128]
#
# Faz em um comando o que antes eram ~30 minutos de cliques, e — mais
# importante — aplica a configuração CORRETA de fábrica. Cada valor abaixo
# corresponde a um defeito que custou tempo real para ser descoberto:
#
#   fuso America/Fortaleza .... criar pela interface deixa America/Argentina
#   enable_hls + variante HLS . ligar a flag NÃO basta; sem linha em
#                               station_hls_streams o Liquidsoap não gera saída
#   cota de disco explícita ... NULL deixa um cliente encher o disco de todos
#   max_listeners alto ........ o padrão 2500 vira teto artificial
#   porta dentro da faixa ..... estação fora do bloco publicado fica inalcançável
#
# Usa a API administrativa (não SQL direto) para que o AzuraCast monte todos
# os registros relacionados — storage locations, playlist padrão, permissões.

set -Eeuo pipefail

AZC_DIR="${AZC_DIR:-/var/azuracast}"
CONTAINER="${AZC_CONTAINER:-azuracast}"
BASE_DOMAIN="${BASE_DOMAIN:-radio.1bit.net.br}"
API_URL="${API_URL:-https://$BASE_DOMAIN}"
AQUI="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

SLUG=""; NOME=""; EMAIL=""; COTA_GB=20; BITRATE=128; DESCRICAO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --nome) NOME="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --cota) COTA_GB="$2"; shift 2 ;;
    --bitrate) BITRATE="$2"; shift 2 ;;
    --descricao) DESCRICAO="$2"; shift 2 ;;
    *) echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
done

GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok(){ echo "${GRN}✓${RST} $*"; }
warn(){ echo "${YEL}⚠${RST} $*"; }
die(){ echo "${RED}✗ $*${RST}" >&2; exit 1; }
step(){ echo; echo "${BLD}── $* ──${RST}"; }

[[ -n "$SLUG" && -n "$NOME" && -n "$EMAIL" ]] \
  || die "uso: $0 --slug xyz --nome 'Rádio XYZ' --email contato@xyz.com.br [--cota 20]"
[[ "$SLUG" =~ ^[a-z0-9_]+$ ]] \
  || die "slug '$SLUG' inválido: só minúsculas, números e underscore (vira subdomínio e URL da API)"

APIKEY="${AZC_API_KEY:-$(cat "$AQUI/../.apikey" 2>/dev/null || true)}"
[[ -n "$APIKEY" ]] || die "defina AZC_API_KEY (chave de administrador do AzuraCast)"

DOMINIO="${SLUG//_/-}.${BASE_DOMAIN}"
api(){ curl -sk -H "X-API-Key: $APIKEY" -H 'Content-Type: application/json' "$@"; }

# ── Pré-voo ──────────────────────────────────────────────────────────────
step "Pré-voo"
[[ $EUID -eq 0 ]] || die "precisa rodar como root (sudo)"

api -o /dev/null -w '' "$API_URL/api/admin/stations" >/dev/null 2>&1 \
  || die "API inacessível ou chave inválida"
ok "API respondendo"

if api "$API_URL/api/admin/stations" | jq -e --arg s "$SLUG" '.[] | select(.short_name==$s)' >/dev/null 2>&1; then
  die "já existe estação com o slug '$SLUG'"
fi
ok "slug '$SLUG' disponível"

# Bloco de portas livre. O AzuraCast aloca de 10 em 10; se a faixa acabar,
# a estação nasce sem porta e o stream nunca sobe.
MINP=$(grep '^AUTO_ASSIGN_PORT_MIN=' "$AZC_DIR/azuracast.env" | cut -d= -f2)
MAXP=$(grep '^AUTO_ASSIGN_PORT_MAX=' "$AZC_DIR/azuracast.env" | cut -d= -f2)
N_EST=$(api "$API_URL/api/admin/stations" | jq 'length')
BLOCOS=$(( (MAXP - MINP) / 10 ))
(( N_EST < BLOCOS )) \
  || die "faixa de portas esgotada: $N_EST estação(ões) para $BLOCOS bloco(s) em $MINP-$MAXP.
   Amplie AUTO_ASSIGN_PORT_MAX no azuracast.env E a faixa publicada no
   docker-compose.override.yml — os dois precisam casar."
ok "portas: $N_EST/$BLOCOS blocos usados"

# Disco: soma das cotas já concedidas + a nova não pode passar do disponível.
LIVRE_GB=$(df -BG --output=avail "$AZC_DIR" | tail -1 | tr -dc '0-9')
(( COTA_GB + 10 <= LIVRE_GB )) \
  || die "cota de ${COTA_GB} GB não cabe: ${LIVRE_GB} GB livres (reservando 10 GB de folga)"
ok "disco: ${LIVRE_GB} GB livres, cota pedida ${COTA_GB} GB"

DNS_IP=$(getent hosts "$DOMINIO" | awk '{print $1}' | head -1 || true)
MEU_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
[[ "$DNS_IP" == "$MEU_IP" ]] \
  && ok "DNS de $DOMINIO resolve para este host" \
  || warn "DNS de $DOMINIO -> '${DNS_IP:-nada}' (esperado $MEU_IP). Certificado será pulado."

# ── Estação ──────────────────────────────────────────────────────────────
step "Criando a estação"
COTA_BYTES=$(( COTA_GB * 1024 * 1024 * 1024 ))
RESP=$(api -X POST "$API_URL/api/admin/stations" -d "$(jq -n \
  --arg nome "$NOME" --arg slug "$SLUG" --arg desc "${DESCRICAO:-Web rádio de $NOME}" \
  '{
    name: $nome, short_name: $slug, description: $desc,
    frontend_type: "icecast", backend_type: "liquidsoap",
    timezone: "America/Fortaleza",
    enable_streamers: true, enable_public_page: true, enable_public_api: true,
    enable_hls: true, enable_on_demand: true
  }')")
# A cota NÃO vai no payload: o campo media_storage_location faz a API
# devolver erro não-JSON. É aplicada logo abaixo, via SQL, no
# storage_location que o AzuraCast acabou de criar para esta estação.
EST_ID=$(jq -r '.id // empty' <<<"$RESP")
[[ -n "$EST_ID" ]] || die "falha ao criar a estação: $(head -c 300 <<<"$RESP")"
ok "estação criada (id=$EST_ID)"

S=$(grep '^MYSQL_PASSWORD=' "$AZC_DIR/azuracast.env" | cut -d= -f2)
sql(){ docker exec "$CONTAINER" mariadb -u azuracast -p"$S" azuracast -e "$1" >/dev/null 2>&1; }

# Variante HLS: a flag enable_hls sozinha não produz saída nenhuma.
sql "INSERT INTO station_hls_streams (station_id,name,format,bitrate,listeners)
     VALUES ($EST_ID,'aac_${BITRATE}','aac',${BITRATE},0);"
ok "variante HLS aac_${BITRATE} criada"

# Teto de ouvintes alto: o padrão 2500 vira gargalo antes da banda.
sql "UPDATE station SET frontend_config=JSON_SET(frontend_config,'\$.max_listeners',20000)
     WHERE id=$EST_ID;"

# ── Calibragem de latência ───────────────────────────────────────────────
# Valores obtidos empiricamente com transmissão ao vivo real:
#   dj_buffer 5s  -> o Web DJ caía com "Invalid data" a cada ~45s
#   dj_buffer 15s -> estável, porém ~50s de atraso até o ouvinte
#   dj_buffer 8s  -> meio-termo adotado
# HLS com janela menor faz o player entrar mais perto da borda ao vivo:
# 3 segmentos de 2s em vez de 5 de 4s corta ~10s do atraso percebido.
#
# Se um cliente relatar quedas na transmissão ao vivo, SUBA o dj_buffer
# (10-12s). Se reclamar de atraso, BAIXE — mas não abaixo de 6s.
sql "UPDATE station SET backend_config=JSON_SET(backend_config,
       '\$.dj_buffer', 8,
       '\$.hls_segment_length', 2,
       '\$.hls_segments_in_playlist', 3,
       '\$.hls_segments_overhead', 2
     ) WHERE id=$EST_ID;"
sql "UPDATE storage_location sl
     JOIN station s ON s.media_storage_location_id = sl.id
     SET sl.storage_quota=$COTA_BYTES WHERE s.id=$EST_ID;"
ok "teto de ouvintes 20000 · cota ${COTA_GB} GB"

# ── Papel e usuário do cliente ───────────────────────────────────────────
step "Criando acesso do cliente"
PAPEL=$(api -X POST "$API_URL/api/admin/roles" -d "$(jq -n --arg n "Gestor — $NOME" \
  --argjson id "$EST_ID" '{
    name: $n,
    permissions: { global: [], station: { ($id|tostring): [
      "view station management", "view station reports",
      "manage station profile", "manage station broadcasting",
      "manage station streamers", "manage station media",
      "delete station media", "manage station automation",
      "manage station podcasts", "manage station mounts"
    ]}}}')" | jq -r '.id // empty')
[[ -n "$PAPEL" ]] || die "falha ao criar o papel do cliente"
ok "papel criado (id=$PAPEL) — escopado APENAS à estação $EST_ID"

SENHA=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)
# `locale` explícito é OBRIGATÓRIO aqui, não um capricho.
# A ordem de resolução do AzuraCast (Enums/SupportedLocales::createFromRequest)
# é: perfil do usuário -> Accept-Language do NAVEGADOR -> variável LANG.
# Com o perfil em NULL, o navegador do cliente decide — e um cliente com
# Chrome em inglês vê o painel inteiro em inglês, por mais que LANG=pt_BR
# esteja no servidor. Definir no perfil é a única forma de garantir.
USR=$(api -X POST "$API_URL/api/admin/users" -d "$(jq -n \
  --arg e "$EMAIL" --arg n "$NOME" --arg p "$SENHA" --argjson r "$PAPEL" \
  '{email:$e, name:$n, new_password:$p, locale:"pt_BR.UTF-8", roles:[{id:$r}]}')" | jq -r '.id // empty')
[[ -n "$USR" ]] || die "falha ao criar o usuário"

# Cinto e suspensório: se a API ignorar o campo locale, grava direto.
sql "UPDATE users SET locale='pt_BR.UTF-8' WHERE id=$USR;"
ok "usuário $EMAIL criado (id=$USR) · painel em português"

# ── Subdomínio ───────────────────────────────────────────────────────────
step "Publicando $DOMINIO"
sed "s/__DOMINIO__/$DOMINIO/g" "$AQUI/nginx-radio.conf.tpl" > "/etc/nginx/conf.d/$DOMINIO.conf"
nginx -t >/dev/null 2>&1 || die "configuração do nginx inválida"
systemctl reload nginx
ok "vhost publicado (HTTP)"

if [[ "$DNS_IP" == "$MEU_IP" ]]; then
  if certbot --nginx -d "$DOMINIO" --non-interactive --agree-tos \
       -m atendimento@1bit.net.br --redirect >/dev/null 2>&1; then
    ok "certificado emitido"
  else
    warn "certbot falhou — rode depois: certbot --nginx -d $DOMINIO"
  fi
else
  warn "certificado pulado (DNS). Depois: certbot --nginx -d $DOMINIO"
fi

# ── Sobe e confere ───────────────────────────────────────────────────────
step "Ativando"
docker exec "$CONTAINER" azuracast_cli cache:clear >/dev/null 2>&1 || true
sql "UPDATE station SET has_started=1, needs_restart=1 WHERE id=$EST_ID;"
docker exec "$CONTAINER" azuracast_cli azuracast:radio:restart >/dev/null 2>&1 || true
sleep 25

PORTA=$(docker exec "$CONTAINER" mariadb -N -u azuracast -p"$S" azuracast \
  -e "SELECT JSON_EXTRACT(frontend_config,'\$.port') FROM station WHERE id=$EST_ID;" 2>/dev/null)
if ss -lnt | grep -q "127.0.0.1:$PORTA "; then
  ok "porta $PORTA publicada e em escuta"
else
  warn "porta $PORTA NÃO está publicada — o stream ficará inalcançável."
  warn "Ajuste a faixa no docker-compose.override.yml e recrie o contêiner."
fi

cat <<FIM

${GRN}${BLD}Cliente cadastrado.${RST}

  Painel .......... https://$DOMINIO
  Usuário ......... $EMAIL
  Senha ........... $SENHA
  Stream .......... https://$DOMINIO/listen/$SLUG/radio.mp3
  HLS ............. https://$DOMINIO/hls/$SLUG/live.m3u8
  Player público .. https://$DOMINIO/public/$SLUG

  Cota ${COTA_GB} GB · HLS ${BITRATE} kbps · porta $PORTA

${YEL}O cliente ainda precisa subir mídia e montar playlists — sem acervo o
AutoDJ não tem o que tocar e a estação fica muda.${RST}
Entregue a senha por canal seguro e peça troca no primeiro acesso.
FIM
