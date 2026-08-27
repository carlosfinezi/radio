#!/usr/bin/env bash
#
# Empacota TUDO que precisa atravessar para o servidor novo.
#
# Roda no servidor de ORIGEM. Produz um único tarball verificável.
#
# O que vai junto (e por quê):
#   1. dump do banco       -> estações, playlists, grade, usuários, audiência
#   2. mídia das estações  -> o acervo; é o que não tem como recriar
#   3. configs da stack    -> .env, azuracast.env, override de isolamento
#   4. log de SLA          -> histórico de disponibilidade é evidência contratual;
#                             perder isso zera a apuração do mês
#   5. manifesto           -> contagens e somas para conferir do outro lado
#
# O que NÃO vai (de propósito):
#   - configs geradas das estações (icecast.xml, liquidsoap.liq): o AzuraCast
#     regenera a partir do banco. Levar as antigas carrega caminhos e portas
#     do servidor velho.
#   - certificados TLS: pertencem ao domínio e ao servidor; reemitir é grátis.
#
# Uso:  ./exportar.sh [destino.tar.gz]

set -Eeuo pipefail

AZC_DIR="${AZC_DIR:-/var/azuracast}"
CONTAINER="${AZC_CONTAINER:-azuracast}"
UPTIME_LOG="${UPTIME_LOG:-/var/log/webradio/uptime.csv}"
SAIDA="${1:-/root/webradio-export-$(date +%Y%m%d-%H%M%S).tar.gz}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok(){ echo "${GRN}✓${RST} $*"; }
warn(){ echo "${YEL}⚠${RST} $*"; }
die(){ echo "${RED}✗ $*${RST}" >&2; exit 1; }

command -v docker >/dev/null || die "docker não encontrado"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || die "contêiner '$CONTAINER' não está em execução"

SENHA=$(grep '^MYSQL_PASSWORD=' "$AZC_DIR/azuracast.env" | cut -d= -f2-)
[[ -n "$SENHA" ]] || die "não achei MYSQL_PASSWORD em $AZC_DIR/azuracast.env"

mkdir -p "$TMP/pacote"

# ── 1. Banco ─────────────────────────────────────────────────────────────
echo "${BLD}Banco de dados${RST}"
docker exec "$CONTAINER" mariadb-dump -u azuracast -p"$SENHA" \
  --single-transaction --quick --routines --events azuracast \
  2>/dev/null | gzip -9 > "$TMP/pacote/azuracast.sql.gz"

TAM_DB=$(stat -c%s "$TMP/pacote/azuracast.sql.gz")
# Um dump "vazio" ainda tem cabeçalho; abaixo de 1 KB é falha silenciosa,
# que é o pior jeito de descobrir que o backup não presta.
(( TAM_DB > 1024 )) || die "dump saiu com $TAM_DB bytes — provavelmente vazio"
ok "dump: $(numfmt --to=iec "$TAM_DB")"

# Confere que o dump contém as tabelas que importam, e não só o cabeçalho.
for t in station station_playlists station_schedules station_media users; do
  zgrep -q "CREATE TABLE \`$t\`" "$TMP/pacote/azuracast.sql.gz" \
    || die "tabela '$t' ausente do dump — não migre com esse arquivo"
done
ok "todas as tabelas essenciais presentes no dump"

# ── 2. Mídia ─────────────────────────────────────────────────────────────
echo "${BLD}Mídia das estações${RST}"
# LÊ DE DENTRO DO CONTÊINER, de propósito.
#
# `/var/azuracast/` no HOST contém apenas os arquivos do compose. A mídia vive
# num volume do Docker (azuracast_station_data), montada em /var/azuracast
# dentro do contêiner. A primeira versão deste script olhava o caminho do host
# e reportou alegremente "0 arquivos de mídia" com 3 faixas indexadas no banco
# — numa migração real isso teria perdido o acervo inteiro do cliente,
# silenciosamente, e o erro só apareceria com a rádio muda do outro lado.
#
# Poderíamos ler o mountpoint do volume, mas ele depende do driver de
# armazenamento do Docker. Passar pelo contêiner funciona em qualquer caso.
N_ARQ=$(docker exec "$CONTAINER" sh -c \
  "find /var/azuracast/stations -path '*/media/*' -type f 2>/dev/null | wc -l" | tr -d '[:space:]')

if [[ "${N_ARQ:-0}" -gt 0 ]]; then
  # Só media/ e podcasts/. As pastas config/, hls/, temp/ e recordings/ são
  # descartáveis: o AzuraCast as regenera, e as antigas carregam caminhos e
  # portas do servidor velho.
  docker exec "$CONTAINER" tar cz -C /var/azuracast \
    --exclude='*/config' --exclude='*/hls' --exclude='*/temp' --exclude='*/recordings' \
    stations > "$TMP/pacote/midia.tar.gz" 2>/dev/null

  TAM_MIDIA=$(stat -c%s "$TMP/pacote/midia.tar.gz")
  (( TAM_MIDIA > 512 )) || die "tarball de mídia saiu com $TAM_MIDIA bytes para $N_ARQ arquivo(s)"

  # Confere que os arquivos realmente entraram, e não só a árvore de pastas.
  N_NO_TAR=$(tar tzf "$TMP/pacote/midia.tar.gz" | grep -c '/media/.\+' || true)
  (( N_NO_TAR >= N_ARQ )) \
    || die "o pacote tem $N_NO_TAR arquivo(s) de mídia, mas a estação tem $N_ARQ — exportação incompleta"
  ok "mídia: $(numfmt --to=iec "$TAM_MIDIA") · $N_ARQ arquivo(s), $N_NO_TAR confirmados no pacote"
else
  warn "nenhum arquivo de mídia nas estações"
  : > "$TMP/pacote/midia.tar.gz"
  N_ARQ=0
fi

# ── 3. Configuração da stack ─────────────────────────────────────────────
echo "${BLD}Configuração${RST}"
tar czf "$TMP/pacote/config.tar.gz" -C "$AZC_DIR" \
  .env azuracast.env docker-compose.override.yml 2>/dev/null \
  || warn "algum arquivo de config não foi encontrado"
ok "configs empacotadas"

# ── 4. Histórico de SLA ──────────────────────────────────────────────────
echo "${BLD}Histórico de disponibilidade${RST}"
if [[ -f "$UPTIME_LOG" ]]; then
  cp "$UPTIME_LOG" "$TMP/pacote/uptime.csv"
  N_AMOSTRAS=$(( $(wc -l < "$UPTIME_LOG") - 1 ))
  ok "log de SLA: $N_AMOSTRAS amostra(s)"
else
  warn "sem log de SLA — a apuração do mês recomeça do zero no destino"
  N_AMOSTRAS=0
fi

# ── 5. Manifesto de conferência ──────────────────────────────────────────
Q(){ docker exec "$CONTAINER" mariadb -N -u azuracast -p"$SENHA" azuracast -e "$1" 2>/dev/null; }
cat > "$TMP/pacote/MANIFESTO.txt" <<EOF
Exportação da Web Rádio
Origem:   $(hostname) ($(hostname -I | awk '{print $1}'))
Data:     $(date -Is)

CONFERIR ESTES NÚMEROS APÓS A RESTAURAÇÃO:
  estações .............. $(Q "SELECT COUNT(*) FROM station;")
  playlists ............. $(Q "SELECT COUNT(*) FROM station_playlists;")
  agendamentos .......... $(Q "SELECT COUNT(*) FROM station_schedules;")
  faixas indexadas ...... $(Q "SELECT COUNT(*) FROM station_media;")
  vínculos playlist-faixa $(Q "SELECT COUNT(*) FROM station_playlist_media;")
  variantes HLS ......... $(Q "SELECT COUNT(*) FROM station_hls_streams;")
  usuários .............. $(Q "SELECT COUNT(*) FROM users;")
  arquivos de mídia ..... $N_ARQ
  amostras de SLA ....... $N_AMOSTRAS

Estações:
$(Q "SELECT CONCAT('  ', short_name, '  tz=', timezone, '  hls=', enable_hls) FROM station;")

ATENÇÃO NO DESTINO:
  - A senha do banco vem em config.tar.gz (azuracast.env). Trate como segredo.
  - AZURACAST_BASE_URL precisa ser reescrito para o domínio novo.
  - Certificados NÃO vão no pacote: reemitir no destino.
  - Conferir AUTO_ASSIGN_PORT_MIN/MAX contra as portas publicadas no destino:
    estação com porta fora da faixa publicada fica inalcançável.
EOF

# ── Empacota ─────────────────────────────────────────────────────────────
tar czf "$SAIDA" -C "$TMP" pacote
sha256sum "$SAIDA" > "$SAIDA.sha256"

echo
echo "${GRN}${BLD}Pacote pronto:${RST} $SAIDA ($(numfmt --to=iec "$(stat -c%s "$SAIDA")"))"
echo "Soma:  $(cut -d' ' -f1 "$SAIDA.sha256")"
echo
cat "$TMP/pacote/MANIFESTO.txt"
