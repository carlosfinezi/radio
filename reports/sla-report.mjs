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
// Fronteiras no fuso LOCAL do servidor, não em UTC. Num contrato brasileiro,
// recortar por UTC-0 incluiria 31/07 21h-24h BRT na competência de agosto e
// excluiria as últimas 3h de 31/08 — o mês do laudo não bateria com o mês
// civil que a contratante mede.
const inicio = new Date(ano, mes - 1, 1, 0, 0, 0, 0);
const fim = new Date(ano, mes, 1, 0, 0, 0, 0);
const diasNoMes = Math.round((fim - inicio) / 864e5);

// ── 1. Disponibilidade ───────────────────────────────────────────────────
/**
 * Janelas de manutenção descontáveis do SLA.
 *
 * A alínea (i) ressalva apenas "interrupções programadas PREVIAMENTE
 * comunicadas". A versão anterior aceitava qualquer `comunicadoEm` truthy —
 * a string "qualquer coisa" escrita depois do fato convertia 20% de downtime
 * em contrato conforme. Agora exigimos:
 *   1. `comunicadoEm` ser data válida;
 *   2. a comunicação ser ANTERIOR ao início da janela (é o que "prévia" quer
 *      dizer, e é o ônus da contratada comprovar);
 *   3. duração dentro de um teto — janela de um mês inteiro não é manutenção.
 * As janelas aceitas E as rejeitadas aparecem no relatório: desconto que não
 * é auditável não vale como desconto.
 */
const MAX_JANELA_HORAS = 8;

function lerJanelasManutencao() {
  if (!existsSync(CFG.maintenancePath)) return { aceitas: [], rejeitadas: [] };
  let bruto;
  try {
    const j = JSON.parse(readFileSync(CFG.maintenancePath, 'utf8'));
    bruto = Array.isArray(j) ? j : j.janelas || [];
  } catch (e) {
    return { aceitas: [], rejeitadas: [{ motivo: `arquivo inválido: ${e.message}` }] };
  }

  const aceitas = [], rejeitadas = [];
  for (const w of bruto) {
    const ini = new Date(w.inicio), f = new Date(w.fim), com = new Date(w.comunicadoEm);
    const horas = (f - ini) / 36e5;
    let motivo = null;

    if (isNaN(ini) || isNaN(f)) motivo = 'datas de início/fim inválidas';
    else if (f <= ini) motivo = 'fim anterior ao início';
    else if (isNaN(com)) motivo = `comunicadoEm inválido ("${w.comunicadoEm}")`;
    else if (com >= ini) motivo = `comunicação em ${com.toISOString().slice(0, 10)} NÃO é prévia ao início`;
    else if (horas > MAX_JANELA_HORAS) motivo = `duração de ${horas.toFixed(1)}h excede o teto de ${MAX_JANELA_HORAS}h`;

    // Preserva as strings originais para exibição e guarda os Date em campos
    // próprios: sobrescrever `w.fim` com o objeto Date fazia o relatório
    // imprimir "Mon Aug 10 2026 04:00:00 GMT-0300 (...)" na tabela.
    if (motivo) rejeitadas.push({ ...w, motivo, horas });
    else aceitas.push({ ...w, ini, fimD: f, horas });
  }
  return { aceitas, rejeitadas };
}

function apurarDisponibilidade() {
  if (!existsSync(CFG.logPath)) return null;
  const linhas = readFileSync(CFG.logPath, 'utf8').split('\n').slice(1).filter(Boolean);
  const { aceitas: janelas, rejeitadas } = lerJanelasManutencao();

  let up = 0, down = 0, descontadas = 0;
  const incidentes = [];
  const instantes = [];
  let incidenteAberto = null;

  for (const linha of linhas) {
    const [ts, estado] = linha.split(',');
    const t = new Date(ts);
    if (isNaN(t) || t < inicio || t >= fim) continue;
    instantes.push(t);

    if (janelas.some((w) => t >= w.ini && t < w.fimD)) { descontadas++; continue; }

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

  // ── COBERTURA: o número que impedia o laudo de mentir ────────────────
  // `total = up + down` só conta o que ESTÁ no arquivo. Amostras que nunca
  // foram gravadas somem da conta, e o percentual sai da fração medida, não
  // do mês. 100 minutos de amostra apuravam "100,0000% CONFORME" para agosto
  // inteiro. Pior: quando o servidor cai, o monitor cai junto e a queda vira
  // lacuna — ou seja, exatamente o evento que o SLA existe para medir é o que
  // some. Sem cobertura declarada, este documento não é prova de nada.
  instantes.sort((a, b) => a - b);
  const deltas = [];
  for (let i = 1; i < instantes.length; i++) deltas.push(instantes[i] - instantes[i - 1]);
  const intervaloMs = deltas.length
    ? deltas.slice().sort((a, b) => a - b)[Math.floor(deltas.length / 2)]
    : 0;

  const esperadas = intervaloMs > 0 ? Math.round((fim - inicio) / intervaloMs) : 0;
  const coletadas = instantes.length;
  const cobertura = esperadas > 0 ? (coletadas / esperadas) * 100 : 0;

  const lacunas = [];
  for (let i = 1; i < instantes.length; i++) {
    const d = instantes[i] - instantes[i - 1];
    if (intervaloMs > 0 && d > intervaloMs * 5) {
      lacunas.push({ de: instantes[i - 1].toISOString(), ate: instantes[i].toISOString(), horas: d / 36e5 });
    }
  }

  const total = up + down;
  const pct = total > 0 ? (up / total) * 100 : null;
  const COBERTURA_MINIMA = 95;
  const coberturaOk = cobertura >= COBERTURA_MINIMA;

  return {
    total, up, down, descontadas, incidentes, janelas, rejeitadas,
    pct, diasNoMes,
    intervaloMin: intervaloMs / 60000,
    esperadas, coletadas, cobertura, coberturaOk, lacunas,
    coberturaMinima: COBERTURA_MINIMA,
    // Só é "conforme" com meta atingida E cobertura suficiente para afirmar.
    conforme: total > 0 && pct >= CFG.slaTarget && coberturaOk,
    apuravel: total > 0 && coberturaOk,
  };
}

// ── 2. Audiência ─────────────────────────────────────────────────────────
async function apurarAudiencia() {
  if (!CFG.baseUrl || !CFG.apiKey) return null;
  // `end` é INCLUSIVO no endpoint do AzuraCast: passar o 1º do mês seguinte
  // trazia as sessões desse dia para dentro do relatório do mês anterior.
  // Usamos o último dia do mês de competência.
  const ultimoDia = new Date(fim.getTime() - 864e5);
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const q = `start=${iso(inicio)}&end=${iso(ultimoDia)}`;
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
  // `new Set(ls.map(l => l.ip)).size` devolvia 1 quando a API não expõe `ip`
  // (todos viravam undefined): "1 ouvinte único" para 10.000 sessões. Número
  // fabricado num relatório contratual é pior que número ausente.
  const ips = ls.map((l) => l.ip).filter((x) => typeof x === 'string' && x.length > 0);
  return {
    sessoes: ls.length,
    ouvintesUnicos: ips.length ? new Set(ips).size : null,
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
  // Margem e indisponibilidade calculadas sobre os dias REAIS do mês.
  // Fixar 30 dias subdimensionava agosto em 3,2% e superdimensionava
  // fevereiro em 7% — num documento contratual.
  const minutosNoMes = disp.diasNoMes * 24 * 60;
  const margemMin = (1 - CFG.slaTarget / 100) * minutosNoMes;
  const indispMin = (disp.down / disp.total) * minutosNoMes;

  if (!disp.coberturaOk) {
    L.push(`> ⛔ **LAUDO NÃO CONCLUSIVO — cobertura insuficiente.**`);
    L.push('>');
    L.push(`> Foram coletadas **${disp.coletadas} de ~${disp.esperadas}** amostras esperadas ` +
           `para ${CFG.month} (**${disp.cobertura.toFixed(2)}%** de cobertura; mínimo exigido ${disp.coberturaMinima}%).`);
    L.push('>');
    L.push('> O percentual abaixo refere-se **apenas ao período efetivamente medido** e ' +
           '**não** representa a disponibilidade do mês. Amostra ausente não é amostra "no ar".');
    L.push('');
  }

  L.push(`| Indicador | Valor |`);
  L.push(`|---|---|`);
  L.push(`| Disponibilidade no período medido | **${disp.pct.toFixed(4)}%** |`);
  L.push(`| Meta contratual | ${CFG.slaTarget.toFixed(2)}% |`);
  L.push(`| **Situação** | ${
    !disp.coberturaOk ? '⛔ **NÃO APURÁVEL** (cobertura insuficiente)'
      : disp.conforme ? '✅ **CONFORME**'
      : '❌ **NÃO CONFORME**'} |`);
  L.push(`| Cobertura do monitoramento | ${disp.cobertura.toFixed(2)}% (${disp.coletadas}/${disp.esperadas} amostras) |`);
  L.push(`| Intervalo de amostragem | ${disp.intervaloMin.toFixed(1)} min |`);
  L.push(`| Dias no mês | ${disp.diasNoMes} |`);
  L.push(`| Amostras indisponíveis | ${disp.down} |`);
  L.push(`| Indisponibilidade estimada | ${fmtHoras(indispMin / 60)} (margem contratual: ${fmtHoras(margemMin / 60)}) |`);
  L.push(`| Amostras em parada programada (descontadas) | ${disp.descontadas} |`);
  L.push('');

  if (disp.lacunas.length) {
    L.push(`### ⚠️ Lacunas no monitoramento (${disp.lacunas.length})`);
    L.push('');
    L.push('Períodos sem qualquer amostra. Como o monitor roda no próprio host, ' +
           'uma queda do servidor derruba o monitor junto e a indisponibilidade ' +
           'não é registrada — estas lacunas podem esconder exatamente o que o SLA mede.');
    L.push('');
    L.push('| De | Até | Duração |');
    L.push('|---|---|---|');
    for (const g of disp.lacunas.slice(0, 20)) {
      L.push(`| ${g.de} | ${g.ate} | ${fmtHoras(g.horas)} |`);
    }
    L.push('');
  }

  if (disp.janelas.length || disp.rejeitadas.length) {
    L.push('### Paradas programadas');
    L.push('');
    L.push('| Início | Fim | Comunicada em | Situação |');
    L.push('|---|---|---|---|');
    for (const w of disp.janelas) {
      L.push(`| ${w.inicio} | ${w.fim} | ${w.comunicadoEm} | ✅ descontada (${w.horas.toFixed(1)}h) |`);
    }
    for (const w of disp.rejeitadas) {
      L.push(`| ${w.inicio ?? '—'} | ${w.fim ?? '—'} | ${w.comunicadoEm ?? '—'} | ❌ NÃO descontada: ${w.motivo} |`);
    }
    L.push('');
  }
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
  L.push(`| Ouvintes únicos | ${aud.ouvintesUnicos === null ? 'não disponível (API não expõe IP)' : aud.ouvintesUnicos} |`);
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
L.push('Relatório gerado automaticamente. Os dados de audiência provêm dos registros');
L.push('de conexão do servidor de streaming.');
L.push('');
L.push('**Limitação metodológica declarada:** a sondagem de disponibilidade é executada');
L.push('no mesmo host que hospeda o serviço. Uma indisponibilidade que afete o host');
L.push('inteiro derruba também o coletor, e o período aparece como lacuna, não como');
L.push('indisponibilidade. Por isso a cobertura é declarada acima. Para prova');
L.push('contratualmente robusta, o coletor deve ser movido para um nó externo.');

const doc = L.join('\n');
if (CFG.out) { writeFileSync(CFG.out, doc); console.log(`Relatório gravado em ${CFG.out}`); }
else console.log(doc);

// Códigos distintos: automação não pode confundir "não medido" com "conforme".
//   0 = conforme e apurável
//   1 = apurado e NÃO conforme
//   2 = não apurável (sem dados ou cobertura insuficiente)
if (!disp || !disp.apuravel) process.exit(2);
process.exit(disp.conforme ? 0 : 1);
