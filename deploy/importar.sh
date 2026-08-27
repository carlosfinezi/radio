#!/usr/bin/env bash
#
# Restaura no servidor de DESTINO o pacote gerado por exportar.sh.
#
# Uso:  sudo ./importar.sh pacote.tar.gz https://radio.1bit.net.br
#
# CUIDADO CENTRAL DESTE SCRIPT:
# A senha do banco do DESTINO é diferente da origem. O dump traz os DADOS,
# não as credenciais do servidor. Restaurar usando a senha que veio no pacote
# falha; é preciso conectar com a senha local e só então injetar os dados.

set -Eeuo pipefail

PACOTE="${1:-}"
BASE_URL="${2:-}"
AZC_DIR="${AZC_DIR:-/var/azuracast}"
CONTAINER="${AZC_CONTAINER:-azuracast}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'; BLD=$'\e[1m'; RST=$'\e[0m'
ok(){ echo "${GRN}✓${RST} $*"; }
warn(){ echo "${YEL}⚠${RST} $*"; }
die(){ echo "${RED}✗ $*${RST}" >&2; exit 1; }
step(){ echo; echo "${BLD}── $* ──${RST}"; }

[[ -f "$PACOTE" ]] || die "uso: $0 pacote.tar.gz https://dominio-novo"
[[ -n "$BASE_URL" ]] || die "informe a URL base do destino (ex.: https://radio.1bit.net.br)"

# Senha LOCAL — nunca a que veio no pacote.
SENHA=$(grep '^MYSQL_PASSWORD=' "$AZC_DIR/azuracast.env" | cut -d= -f2-)
[[ -n "$SENHA" ]] || die "não achei MYSQL_PASSWORD local em $AZC_DIR/azuracast.env"

tar xzf "$PACOTE" -C "$TMP"
P="$TMP/pacote"
[[ -f "$P/azuracast.sql.gz" ]] || die "pacote sem dump de banco"

step "Manifesto de origem"
cat "$P/MANIFESTO.txt" | sed -n '/CONFERIR/,/^$/p'

# ── 1. Banco ─────────────────────────────────────────────────────────────
step "Restaurando banco"
# Guarda o estado atual antes de sobrescrever: se algo der errado, há volta.
docker exec "$CONTAINER" mariadb-dump -u azuracast -p"$SENHA" --single-transaction \
  azuracast 2>/dev/null | gzip -9 > "$AZC_DIR/pre-import-$(date +%Y%m%d-%H%M%S).sql.gz"
ok "estado anterior salvo em $AZC_DIR/pre-import-*.sql.gz"

zcat "$P/azuracast.sql.gz" | docker exec -i "$CONTAINER" \
  mariadb -u azuracast -p"$SENHA" azuracast 2>/dev/null \
  || die "falha ao restaurar o dump"
ok "banco restaurado"

# ── 2. Mídia ─────────────────────────────────────────────────────────────
step "Restaurando mídia"
if [[ -s "$P/midia.tar.gz" ]]; then
  # Entra pelo contêiner: a mídia vive num volume do Docker, não no caminho
  # do host. Escrever em /var/azuracast/stations do HOST não teria efeito.
  docker exec -i "$CONTAINER" tar xz -C /var/azuracast < "$P/midia.tar.gz"
  docker exec "$CONTAINER" chown -R azuracast:azuracast /var/azuracast/stations
  N=$(docker exec "$CONTAINER" sh -c \
      "find /var/azuracast/stations -path '*/media/*' -type f | wc -l" | tr -d '[:space:]')
  ok "mídia restaurada: $N arquivo(s)"
else
  warn "pacote sem mídia"
  N=0
fi

# ── 3. URL base ──────────────────────────────────────────────────────────
step "Ajustando a URL base para o domínio novo"
# Precisa mudar nos DOIS lugares: o banco alimenta os links do painel, o
# azuracast.env alimenta o ambiente do contêiner. Corrigir só um deixa metade
# dos links apontando para o servidor antigo.
docker exec "$CONTAINER" mariadb -u azuracast -p"$SENHA" azuracast \
  -e "UPDATE settings SET base_url='${BASE_URL#https://}', prefer_browser_url=1;" 2>/dev/null \
  || warn "não consegui atualizar settings.base_url — ajuste pelo painel"
sed -i "s|^AZURACAST_BASE_URL=.*|AZURACAST_BASE_URL=${BASE_URL}|" "$AZC_DIR/azuracast.env"
ok "URL base = $BASE_URL (banco + env)"

# ── 4. Log de SLA ────────────────────────────────────────────────────────
if [[ -f "$P/uptime.csv" ]]; then
  mkdir -p /var/log/webradio
  if [[ -f /var/log/webradio/uptime.csv ]]; then
    # Concatena preservando o histórico: o log de SLA é evidência contratual,
    # sobrescrever apagaria a apuração do mês.
    tail -n +2 "$P/uptime.csv" >> /var/log/webradio/uptime.csv
    ok "histórico de SLA anexado ao log existente"
  else
    cp "$P/uptime.csv" /var/log/webradio/uptime.csv
    ok "histórico de SLA restaurado"
  fi
fi

# ── 5. Reinicia e confere ────────────────────────────────────────────────
step "Reiniciando"
docker exec "$CONTAINER" azuracast_cli cache:clear >/dev/null 2>&1 || true
cd "$AZC_DIR" && docker compose restart >/dev/null 2>&1
sleep 30
docker exec "$CONTAINER" azuracast_cli azuracast:radio:restart >/dev/null 2>&1 || true
sleep 20

step "Conferência"
Q(){ docker exec "$CONTAINER" mariadb -N -u azuracast -p"$SENHA" azuracast -e "$1" 2>/dev/null; }
printf "  estações .............. %s\n" "$(Q 'SELECT COUNT(*) FROM station;')"
printf "  playlists ............. %s\n" "$(Q 'SELECT COUNT(*) FROM station_playlists;')"
printf "  agendamentos .......... %s\n" "$(Q 'SELECT COUNT(*) FROM station_schedules;')"
printf "  faixas indexadas ...... %s\n" "$(Q 'SELECT COUNT(*) FROM station_media;')"
printf "  vínculos playlist-faixa %s\n" "$(Q 'SELECT COUNT(*) FROM station_playlist_media;')"
printf "  variantes HLS ......... %s\n" "$(Q 'SELECT COUNT(*) FROM station_hls_streams;')"
printf "  usuários .............. %s\n" "$(Q 'SELECT COUNT(*) FROM users;')"
printf "  arquivos de mídia ..... %s\n" "$N"
echo
echo "Compare com o manifesto acima. Divergência = restauração incompleta."
