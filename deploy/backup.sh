#!/usr/bin/env bash
#
# Backup diário — alínea (j) do edital.
#
# Três coisas precisam sobreviver a uma perda total da máquina:
#   1. o banco (audiência histórica, usuários, playlists, grade)
#   2. a mídia do Auto DJ (os 50 GB)
#   3. a configuração da stack
#
# Estratégia: banco todo dia (comprimido, pequeno); mídia por espelhamento
# incremental (rsync), porque 50 GB em tarball diário estouraria o disco —
# exatamente o incidente de backup falhando por espaço que já ocorreu neste host.

set -Eeuo pipefail

AZC_DIR="${AZC_DIR:-/var/azuracast}"
DEST="${BACKUP_DEST:-/var/backups/webradio}"
RETENCAO_DIAS="${RETENCAO_DIAS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { echo "[$(date -Is)] $*"; }
die() { echo "[$(date -Is)] ERRO: $*" >&2; exit 1; }

mkdir -p "$DEST/db" "$DEST/config" "$DEST/media"

# ── Espaço antes de começar ──────────────────────────────────────────────
# Falhar cedo e alto é melhor que encher o disco e derrubar a rádio junto.
AVAIL_MB=$(df -BM --output=avail "$DEST" | tail -1 | tr -dc '0-9')
(( AVAIL_MB > 2048 )) || die "menos de 2 GB livres em $DEST — abortando antes de piorar"

# ── 1. Banco ─────────────────────────────────────────────────────────────
log "banco de dados..."
cd "$AZC_DIR"
docker compose exec -T mariadb \
  mysqldump --single-transaction --quick --routines azuracast \
  2>/dev/null | gzip -9 > "$DEST/db/azuracast-$STAMP.sql.gz" \
  || die "falha no dump do banco"

DB_SIZE=$(stat -c%s "$DEST/db/azuracast-$STAMP.sql.gz")
(( DB_SIZE > 1024 )) || die "dump saiu com $DB_SIZE bytes — quase certamente vazio"
log "banco OK ($(numfmt --to=iec "$DB_SIZE"))"

# ── 2. Configuração ──────────────────────────────────────────────────────
log "configuração..."
tar czf "$DEST/config/config-$STAMP.tar.gz" \
  -C "$AZC_DIR" docker-compose.yml docker-compose.override.yml azuracast.env \
  2>/dev/null || log "aviso: algum arquivo de config não foi encontrado"

# ── 3. Mídia (incremental) ───────────────────────────────────────────────
log "mídia (rsync incremental)..."
if [[ -d "$AZC_DIR/stations" ]]; then
  rsync -a --delete --info=stats2 \
    "$AZC_DIR/stations/" "$DEST/media/" | tail -5
else
  log "aviso: $AZC_DIR/stations não existe ainda"
fi

# ── 4. Retenção ──────────────────────────────────────────────────────────
find "$DEST/db"     -name '*.sql.gz'  -mtime "+$RETENCAO_DIAS" -delete
find "$DEST/config" -name '*.tar.gz'  -mtime "+$RETENCAO_DIAS" -delete

log "concluído. Ocupação: $(du -sh "$DEST" | cut -f1)"
log "LEMBRETE: backup só vale se a restauração foi testada. Ver RUNBOOK, rotina trimestral."
