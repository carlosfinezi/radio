#!/usr/bin/env node
/**
 * Gerador do relatório mensal — alíneas (g) métricas de audiência e (i) SLA.
 *
 * Produz um documento em Markdown pronto para anexar à medição do contrato,
 * combinando duas fontes independentes:
 *   1. o CSV do monitor de uptime  -> disponibilidade apurada
 *   2. a API do AzuraCast          -> audiência (ouvintes, sessões, geo)
 *
 * Sobre o desconto de paradas programadas: o edital ressalva "interrupções
 * programadas previamente comunicadas". Elas não são adivinhadas — precisam
 * estar declaradas em maintenance.json, com data de comunicação. Sem esse
 * registro, a parada conta contra o SLA. É o comportamento correto: o ônus
 * de comprovar o aviso prévio é da contratada.
 *
 * Uso:
 *   node reports/sla-report.mjs --month 2026-08 --out laudo-2026-08.md
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { azuraApi } from '../validation/lib/probe.mjs';

const argv = process.argv.slice(2);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

const CFG = {
  month: val('--month', new Date().toISOString().slice(0, 7)),
  logPath: process.env.UPTIME_LOG || '/var/log/webradio/uptime.csv',
  maintenancePath: val('--maintenance', '/etc/webradio/maintenance.json'),
  baseUrl: process.env.AZC_BASE_URL || '',
  apiKey: process.env.AZC_API_KEY || '',
  station: process.env.AZC_STATION || 'porto_do_capim',
  slaTarget: 99.0,
  out: val('--out', ''),
};

const [ano, mes] = CFG.month.split('-').map(Number);
const inicio = new Date(Date.UTC(ano, mes - 1, 1));
const fim = new Date(Date.UTC(ano, mes, 1));

// ── 1. Disponibilidade ───────────────────────────────────────────────────
function lerJanelasManutencao() {
  if (!existsSync(CFG.maintenancePath)) return [];
  try {
    const j = JSON.parse(readFileSync(CFG.maintenancePath, 'utf8'));
    return (Array.isArray(j) ? j : j.janelas || [])
      .filter((w) => w.comunicadoEm) // sem aviso prévio comprovado, não descontamos
      .map((w) => ({ ...w, ini: new Date(w.inicio), fim: new Date(w.fim) }));
  } catch { return []; }
}

function apurarDisponibilidade() {
  if (!existsSync(CFG.logPath)) return null;
  const linhas = readFileSync(CFG.logPath, 'utf8').split('\n').slice(1).filter(Boolean);
  const janelas = lerJanelasManutencao();

  let up = 0, down = 0, descontadas = 0;
  const incidentes = [];
  let incidenteAberto = null;

  for (const linha of linhas) {
    const [ts, estado] = linha.split(',');
    const t = new Date(ts);
    if (isNaN(t) || t < inicio || t >= fim) continue;

    if (janelas.some((w) => t >= w.ini && t < w.fim)) { descontadas++; continue; }

    if (estado === 'up') {
      up++;
      if (incidenteAberto) {
        incidenteAberto.fim = ts;
        incidentes.push(incidenteAberto);
        incidenteAberto = null;
      }
    } else {
      down++;
      if (!incidenteAberto) incidenteAberto = { inicio: ts, fim: null, amostras: 0 };
      incidenteAberto.amostras++;
    }
  }
  if (incidenteAberto) incidentes.push(incidenteAberto);

  const total = up + down;
  return {
    total, up, down, descontadas,
    pct: total > 0 ? (up / total) * 100 : null,
    incidentes,
    conforme: total > 0 && (up / total) * 100 >= CFG.slaTarget,
  };
}

// ── 2. Audiência ─────────────────────────────────────────────────────────
async function apurarAudiencia() {
  if (!CFG.baseUrl || !CFG.apiKey) return null;
  const q = `start=${inicio.toISOString().slice(0, 10)}&end=${fim.toISOString().slice(0, 10)}`;
  const r = await azuraApi(CFG.baseUrl, CFG.apiKey, `/api/station/${CFG.station}/listeners?${q}`);
  if (r.status !== 200 || !Array.isArray(r.json)) return { erro: `API HTTP ${r.status}` };

  const ls = r.json;
  const porPais = {}, porDispositivo = {};
  let segundosTotais = 0;

  for (const l of ls) {
    segundosTotais += l.connected_time || 0;
    const pais = l.location?.country || 'desconhecido';
    porPais[pais] = (porPais[pais] || 0) + 1;
    const dev = l.device?.client || l.device?.browser_family || 'desconhecido';
    porDispositivo[dev] = (porDispositivo[dev] || 0) + 1;
  }

  const top = (o) => Object.entries(o).sort((a, b) => b[1] - a[1]).slice(0, 8);
  return {
    sessoes: ls.length,
    ouvintesUnicos: new Set(ls.map((l) => l.ip)).size,
    horasTotaisEscuta: segundosTotais / 3600,
    duracaoMediaMin: ls.length ? segundosTotais / ls.length / 60 : 0,
    topPaises: top(porPais),
    topDispositivos: top(porDispositivo),
  };
}

// ── 3. Documento ─────────────────────────────────────────────────────────
function fmtHoras(h) {
  const H = Math.floor(h), M = Math.round((h - H) * 60);
  return `${H}h${String(M).padStart(2, '0')}min`;
}

const disp = apurarDisponibilidade();
const aud = await apurarAudiencia();
const L = [];

L.push(`# Relatório Mensal — Web Rádio Porto do Capim`);
L.push('');
L.push(`**Competência:** ${CFG.month}`);
L.push(`**Emitido em:** ${new Date().toISOString().slice(0, 19).replace('T', ' ')} UTC`);
L.push('');
L.push('## 1. Disponibilidade do serviço (SLA)');
L.push('');

if (!disp || disp.total === 0) {
  L.push('> ⚠️ **Sem dados de monitoramento no período.** O SLA não pode ser apurado.');
  L.push('> Verifique se `reports/uptime-monitor.mjs` está em execução.');
} else {
  const margemMin = (1 - CFG.slaTarget / 100) * 30 * 24 * 60;
  const indispMin = (disp.down / disp.total) * 30 * 24 * 60;
  L.push(`| Indicador | Valor |`);
  L.push(`|---|---|`);
  L.push(`| Disponibilidade apurada | **${disp.pct.toFixed(4)}%** |`);
  L.push(`| Meta contratual | ${CFG.slaTarget.toFixed(2)}% |`);
  L.push(`| Situação | ${disp.conforme ? '✅ **CONFORME**' : '❌ **NÃO CONFORME**'} |`);
  L.push(`| Amostras coletadas | ${disp.total} |`);
  L.push(`| Amostras indisponíveis | ${disp.down} |`);
  L.push(`| Indisponibilidade estimada | ${fmtHoras(indispMin / 60)} (margem: ${fmtHoras(margemMin / 60)}) |`);
  L.push(`| Amostras em parada programada (descontadas) | ${disp.descontadas} |`);
  L.push('');
  if (disp.incidentes.length) {
    L.push(`### Incidentes registrados (${disp.incidentes.length})`);
    L.push('');
    L.push('| Início | Fim | Amostras |');
    L.push('|---|---|---|');
    for (const i of disp.incidentes.slice(0, 30)) {
      L.push(`| ${i.inicio} | ${i.fim || '(em aberto)'} | ${i.amostras} |`);
    }
  } else {
    L.push('Nenhum incidente de indisponibilidade registrado no período.');
  }
}

L.push('');
L.push('## 2. Métricas de audiência');
L.push('');

if (!aud) {
  L.push('> ⚠️ API do AzuraCast não configurada (`AZC_BASE_URL` / `AZC_API_KEY`).');
} else if (aud.erro) {
  L.push(`> ⚠️ Não foi possível obter audiência: ${aud.erro}`);
} else {
  L.push('| Indicador | Valor |');
  L.push('|---|---|');
  L.push(`| Sessões de escuta | ${aud.sessoes} |`);
  L.push(`| Ouvintes únicos | ${aud.ouvintesUnicos} |`);
  L.push(`| Horas totais de escuta (TLH) | ${fmtHoras(aud.horasTotaisEscuta)} |`);
  L.push(`| Duração média por sessão | ${aud.duracaoMediaMin.toFixed(1)} min |`);
  L.push('');
  if (aud.topPaises.length) {
    L.push('### Origem geográfica');
    L.push('');
    L.push('| País | Sessões |');
    L.push('|---|---|');
    for (const [p, n] of aud.topPaises) L.push(`| ${p} | ${n} |`);
    L.push('');
  }
  if (aud.topDispositivos.length) {
    L.push('### Plataforma de acesso');
    L.push('');
    L.push('| Cliente | Sessões |');
    L.push('|---|---|');
    for (const [d, n] of aud.topDispositivos) L.push(`| ${d} | ${n} |`);
  }
}

L.push('');
L.push('---');
L.push('');
L.push('Relatório gerado automaticamente. Os dados de disponibilidade provêm de ');
L.push('sondagem ativa e independente do servidor monitorado; os dados de audiência, ');
L.push('dos registros de conexão do servidor de streaming.');

const doc = L.join('\n');
if (CFG.out) { writeFileSync(CFG.out, doc); console.log(`Relatório gravado em ${CFG.out}`); }
else console.log(doc);

process.exit(disp && disp.total > 0 && !disp.conforme ? 1 : 0);
