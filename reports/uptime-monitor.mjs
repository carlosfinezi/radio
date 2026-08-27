#!/usr/bin/env node
/**
 * Monitor de disponibilidade — evidência para as alíneas (i) SLA e (j) suporte.
 *
 * Grava uma linha CSV por amostra. É esse arquivo que vira o laudo mensal de
 * SLA, então o formato é deliberadamente burro e append-only: um CSV que
 * qualquer auditor abre no Excel e confere na mão.
 *
 *   timestamp,estado,latencia_ms,detalhe
 *   2026-08-27T10:00:00.000Z,up,143,"200 OK; 128.4 kbps"
 *
 * Uma amostra "up" exige que o stream esteja ENTREGANDO ÁUDIO, não apenas
 * que o HTTP responda 200. Servidor que responde 200 com stream mudo está
 * fora do ar para o ouvinte, e o SLA tem que refletir isso.
 *
 * Uso:
 *   node reports/uptime-monitor.mjs --once
 *   node reports/uptime-monitor.mjs --interval 60      # laço contínuo
 *   node reports/uptime-monitor.mjs --interval 60 --alert-cmd './alerta.sh'
 */

import { appendFileSync, mkdirSync, existsSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { exec } from 'node:child_process';
import { openStream } from '../validation/lib/probe.mjs';

const argv = process.argv.slice(2);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

const CFG = {
  streamUrl: process.env.STREAM_URL || '',
  logPath: process.env.UPTIME_LOG || '/var/log/webradio/uptime.csv',
  intervalSec: Number(val('--interval', 0)),
  alertCmd: val('--alert-cmd', process.env.ALERT_CMD || ''),
  // Só alerta após N falhas seguidas: um blip de rede não é incidente,
  // e alerta que grita à toa deixa de ser lido.
  alertAfter: Number(val('--alert-after', 3)),
  warmupSeconds: 3,
  minBytes: 4096,
  probeSeconds: 5,
};

if (!CFG.streamUrl) {
  console.error('defina STREAM_URL=https://.../listen/porto_do_capim/radio.mp3');
  process.exit(2);
}

if (!existsSync(dirname(CFG.logPath))) mkdirSync(dirname(CFG.logPath), { recursive: true });
if (!existsSync(CFG.logPath)) writeFileSync(CFG.logPath, 'timestamp,estado,latencia_ms,detalhe\n');

/** Uma amostra: conecta, confirma que áudio flui, mede latência de resposta. */
async function sample() {
  const t0 = Date.now();
  try {
    const { status, headers, req, res } = await openStream(CFG.streamUrl, { timeoutMs: 15000 });
    const latency = Date.now() - t0;
    if (status !== 200) { req.destroy(); return { up: false, latency, detail: `HTTP ${status}` }; }

    // Descarta o burst inicial antes de contar, como faz a sonda da suíte.
    // Sem isso o log registrava ~290 kbps para um stream de 192, porque o
    // Icecast despeja o buffer de arranque a toda velocidade do link. Num
    // arquivo que é evidência contratual, número inflado convida contestação.
    let bytes = 0;
    let medindoDesde = null;
    res.on('data', (c) => { if (medindoDesde !== null) bytes += c.length; });

    await new Promise((r) => setTimeout(r, CFG.warmupSeconds * 1000));
    medindoDesde = Date.now();
    await new Promise((r) => setTimeout(r, CFG.probeSeconds * 1000));
    const decorridoMs = Date.now() - medindoDesde;
    req.destroy();

    if (bytes < CFG.minBytes) {
      return { up: false, latency, detail: `respondeu 200 mas entregou só ${bytes} bytes após o warmup (stream mudo)` };
    }
    const kbps = (bytes * 8) / decorridoMs;
    return { up: true, latency, detail: `200 OK; ${kbps.toFixed(1)} kbps` };
  } catch (e) {
    return { up: false, latency: Date.now() - t0, detail: e.message.slice(0, 120) };
  }
}

let consecutiveFails = 0;
let alerted = false;

/**
 * Escapa um campo para CSV.
 *
 * Mensagens de erro de TLS e AggregateError são MULTILINHA. Gravadas cruas,
 * quebravam a linha em duas dentro de um arquivo append-only que o relatório
 * de SLA lê por linha — a amostra virava dois registros corrompidos, num
 * documento que "qualquer auditor abre no Excel".
 */
function csv(v) {
  const s = String(v ?? '').replace(/[\r\n]+/g, ' ').trim();
  return `"${s.replace(/"/g, '""')}"`;   // aspas duplicadas: escape padrão RFC 4180
}

async function tick() {
  const s = await sample();
  const line = `${new Date().toISOString()},${s.up ? 'up' : 'down'},${s.latency},${csv(s.detail)}\n`;
  appendFileSync(CFG.logPath, line);
  process.stdout.write(`${s.up ? '\x1b[32m● up  \x1b[0m' : '\x1b[31m● DOWN\x1b[0m'} ${s.latency}ms  ${s.detail}\n`);

  if (s.up) {
    if (alerted) {
      fire(`RECUPERADO: a rádio voltou ao ar após ${consecutiveFails} falha(s).`);
      alerted = false;
    }
    consecutiveFails = 0;
  } else {
    consecutiveFails++;
    if (consecutiveFails >= CFG.alertAfter && !alerted) {
      fire(`FORA DO AR: ${consecutiveFails} verificações seguidas falharam. Último erro: ${s.detail}`);
      alerted = true;
    }
  }
}

function fire(msg) {
  console.error(`\x1b[33m[ALERTA]\x1b[0m ${msg}`);
  if (!CFG.alertCmd) return;
  exec(`${CFG.alertCmd} ${JSON.stringify(msg)}`, (e) => {
    if (e) console.error(`falha ao disparar alerta: ${e.message}`);
  });
}

await tick();
if (CFG.intervalSec > 0) {
  console.log(`monitorando a cada ${CFG.intervalSec}s -> ${CFG.logPath}`);
  setInterval(tick, CFG.intervalSec * 1000);
}
