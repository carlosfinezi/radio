#!/usr/bin/env node
/**
 * Executor da suíte de conformidade do edital (alíneas a-j).
 *
 * Uso:
 *   node validation/run.mjs                 # uma passada
 *   node validation/run.mjs --loop          # repete até tudo passar
 *   node validation/run.mjs --only b,d      # só as alíneas indicadas
 *   node validation/run.mjs --json out.json # grava o laudo estruturado
 *
 * Código de saída: 0 = todos os checks críticos passaram; 1 = há falha.
 * Isso é o que permite encadear em CI ou num laço de shell.
 */

import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import { writeFileSync } from 'node:fs';
import { requirements, meta } from './requirements.mjs';

const execAsync = promisify(exec);

/**
 * Executa comando e devolve { out, ok }.
 *
 * O `ok` NÃO é decoração. A versão anterior devolvia só a string e engolia
 * o erro, o que produzia o pior defeito possível numa suíte de conformidade:
 * `docker exec` falhando devolvia string vazia, a regex não achava limite
 * nenhum, e o check concluía "sem limite de ouvintes" -> PASS. Ou seja,
 * o servidor inteiro fora do ar era certificado como conforme.
 *
 * Todo check que dependa de comando externo TEM de olhar o `ok` antes de
 * interpretar o `out`.
 */
const sh = async (cmd) => {
  try {
    const { stdout } = await execAsync(cmd, { timeout: 60000, shell: '/bin/bash' });
    return { out: stdout, ok: true, code: 0 };
  } catch (e) {
    return { out: e.stdout || '', ok: false, code: e.code ?? 1, err: (e.stderr || e.message || '').slice(0, 200) };
  }
};

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

const cfg = {
  baseUrl: process.env.AZC_BASE_URL || 'https://radio.exemplo.br',
  apiKey: process.env.AZC_API_KEY || '',
  station: process.env.AZC_STATION || 'porto_do_capim',
  container: process.env.AZC_CONTAINER || 'azuracast',
  streamUrl: process.env.STREAM_URL || '',
  hlsUrl: process.env.HLS_URL || '',
  edgeUrl: process.env.EDGE_URL || '',
  uptimeLog: process.env.UPTIME_LOG || '/var/log/webradio/uptime.csv',
  loadTestListeners: Number(process.env.LOAD_TEST_LISTENERS || 50),
};

// Defaults derivados, para não repetir configuração à toa
if (!cfg.streamUrl) cfg.streamUrl = `${cfg.baseUrl}/listen/${cfg.station}/radio.mp3`;
if (!cfg.hlsUrl) cfg.hlsUrl = `${cfg.baseUrl}/hls/${cfg.station}/live.m3u8`;

const C = {
  reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m',
  green: '\x1b[32m', red: '\x1b[31m', yellow: '\x1b[33m', cyan: '\x1b[36m',
};

const only = val('--only') ? val('--only').split(',').map((s) => s.trim()) : null;

async function runOnce() {
  const started = new Date();
  const results = [];

  for (const req of requirements) {
    if (only && !only.includes(req.letter)) continue;
    console.log(`\n${C.bold}${C.cyan}(${req.letter}) ${req.title}${C.reset}`);

    const checks = [];
    for (const check of req.checks) {
      process.stdout.write(`  ${C.dim}▸ ${check.name}...${C.reset}`);
      let r;
      const t0 = Date.now();
      try {
        r = await check.run({ cfg, sh });
      } catch (e) {
        r = { pass: false, evidence: `ERRO: ${e.message}`, error: true };
      }
      r.ms = Date.now() - t0;

      // `manual` NÃO pode absolver um FAIL crítico.
      // Na versão anterior, `manual: true` tirava o check do denominador
      // mesmo com pass:false e critical:true — a suíte imprimia
      // "✓ Todos os checks automatizáveis passaram" e saía com código 0
      // com o app fora das lojas, o backup nunca restaurado e o SLA nunca
      // medido. Era exatamente a linha que iria colada numa proposta.
      // Agora MANUAL significa "pendente de evidência humana", e pendência
      // em item crítico bloqueia a aprovação.
      const status = r.pass ? (r.manual ? 'PARCIAL' : 'PASS') : (r.manual ? 'MANUAL' : 'FAIL');
      const color = status === 'PASS' ? C.green : status === 'FAIL' ? C.red : C.yellow;
      const icon = status === 'PASS' ? '✓' : status === 'FAIL' ? '✗' : '⚠';
      process.stdout.write(`\r  ${color}${icon}${C.reset} ${check.name} ${C.dim}(${r.ms}ms)${C.reset}\n`);
      console.log(`    ${C.dim}${r.evidence}${C.reset}`);

      checks.push({
        id: check.id, name: check.name, critical: check.critical !== false,
        status, pass: !!r.pass, manual: !!r.manual,
        evidence: r.evidence, detail: r.detail ?? null, ms: r.ms,
      });
    }
    results.push({ letter: req.letter, title: req.title, edital: req.edital, checks });
  }

  const flat = results.flatMap((r) => r.checks);
  const summary = {
    total: flat.length,
    pass: flat.filter((c) => c.status === 'PASS').length,
    fail: flat.filter((c) => c.status === 'FAIL').length,
    manual: flat.filter((c) => c.status === 'MANUAL').length,
    parcial: flat.filter((c) => c.status === 'PARCIAL').length,
    criticalFail: flat.filter((c) => c.status === 'FAIL' && c.critical).length,
    // Pendência de evidência humana em item crítico bloqueia a aprovação
    // tanto quanto uma falha: não se assina contrato com "depois a gente vê".
    criticalPendente: flat.filter((c) => c.status === 'MANUAL' && c.critical).length,
    startedAt: started.toISOString(),
    durationMs: Date.now() - started.getTime(),
  };
  summary.bloqueia = summary.criticalFail + summary.criticalPendente;

  return { summary, results, cfg: { ...cfg, apiKey: cfg.apiKey ? '***' : '(vazio)' } };
}

function printSummary(s) {
  console.log(`\n${C.bold}${'─'.repeat(64)}${C.reset}`);
  console.log(
    `${C.bold}RESUMO${C.reset}  ` +
    `${C.green}${s.pass} PASS${C.reset}  ` +
    `${C.red}${s.fail} FAIL${C.reset}  ` +
    `${C.yellow}${s.manual} PENDENTE${C.reset}  ` +
    `${C.yellow}${s.parcial} PARCIAL${C.reset}  ` +
    `${C.dim}de ${s.total} verificações em ${(s.durationMs / 1000).toFixed(1)}s${C.reset}`
  );

  if (s.criticalFail > 0) {
    console.log(`${C.red}${C.bold}✗ ${s.criticalFail} falha(s) CRÍTICA(S) — não conforme ao edital.${C.reset}`);
  }
  if (s.criticalPendente > 0) {
    console.log(
      `${C.yellow}${C.bold}⚠ ${s.criticalPendente} item(ns) CRÍTICO(S) sem evidência${C.reset}` +
      `${C.yellow} — conformidade NÃO comprovada (não é o mesmo que aprovado).${C.reset}`
    );
  }
  if (s.bloqueia === 0 && s.fail > 0) {
    console.log(`${C.yellow}Falhas apenas em itens não-críticos.${C.reset}`);
  }
  if (s.bloqueia === 0 && s.fail === 0) {
    console.log(`${C.green}${C.bold}✓ Conformidade comprovada em todos os itens críticos.${C.reset}`);
  }
}

function toMarkdown(report) {
  const L = [];
  L.push('# Laudo de Conformidade — Web Rádio Porto do Capim');
  L.push('');
  L.push(`Gerado em: ${report.summary.startedAt}`);
  L.push(`Alvo: \`${report.cfg.baseUrl}\` · estação \`${report.cfg.station}\``);
  L.push('');
  const s = report.summary;
  L.push(`**${s.pass} aprovados · ${s.fail} reprovados · ${s.manual} pendentes de evidência · ${s.parcial} parciais** (${s.total} verificações)`);
  L.push('');
  if (s.bloqueia > 0) {
    L.push(`> ⛔ **Conformidade NÃO comprovada.** ${s.criticalFail} falha(s) crítica(s) e ` +
      `${s.criticalPendente} item(ns) crítico(s) sem evidência. Este laudo não sustenta assinatura de contrato.`);
  } else {
    L.push('> ✅ Conformidade comprovada em todos os itens críticos automatizáveis.');
  }
  L.push('');
  L.push('| Alínea | Requisito | Resultado |');
  L.push('|---|---|---|');
  for (const r of report.results) {
    const f = r.checks.filter((c) => c.status === 'FAIL').length;
    const m = r.checks.filter((c) => c.status === 'MANUAL').length;
    const p = r.checks.filter((c) => c.status === 'PARCIAL').length;
    const st = f > 0 ? `❌ ${f} falha(s)`
      : m > 0 ? `⚠️ ${m} sem evidência`
      : p > 0 ? `🟡 ${p} parcial(is)`
      : '✅ conforme';
    L.push(`| ${r.letter} | ${r.title} | ${st} |`);
  }
  L.push('');
  const ICON = { PASS: '✅', FAIL: '❌', MANUAL: '⚠️', PARCIAL: '🟡' };
  for (const r of report.results) {
    L.push(`## (${r.letter}) ${r.title}`);
    L.push('');
    L.push(`> ${r.edital}`);
    L.push('');
    for (const c of r.checks) {
      L.push(`- ${ICON[c.status]} **${c.name}**${c.critical ? '' : ' _(não-crítico)_'}`);
      L.push(`  - Evidência: ${c.evidence}`);
    }
    L.push('');
  }
  return L.join('\n');
}

// ── main ────────────────────────────────────────────────────────────────
// `Number(undefined)` é NaN, e `for (i=1; i<=NaN)` nunca executa: o laço não
// rodava, `report` ficava undefined e o processo estourava com TypeError ao
// imprimir o resumo. Qualquer valor inválido cai no default.
const num = (flag, def) => { const n = Number(val(flag, def)); return Number.isFinite(n) && n > 0 ? n : def; };
const maxAttempts = num('--max-attempts', has('--loop') ? 10 : 1);
const waitSec = num('--wait', 30);
let report;

for (let attempt = 1; attempt <= maxAttempts; attempt++) {
  if (maxAttempts > 1) {
    console.log(`\n${C.bold}════ Tentativa ${attempt}/${maxAttempts} ════${C.reset}`);
  }
  report = await runOnce();
  printSummary(report.summary);

  // Repetir não resolve pendência de evidência humana; só falha transitória.
  if (report.summary.criticalFail === 0) break;
  if (attempt < maxAttempts) {
    console.log(`${C.dim}Aguardando ${waitSec}s antes de repetir...${C.reset}`);
    await new Promise((r) => setTimeout(r, waitSec * 1000));
  }
}

const jsonPath = val('--json');
if (jsonPath) { writeFileSync(jsonPath, JSON.stringify(report, null, 2)); console.log(`\nLaudo JSON: ${jsonPath}`); }
const mdPath = val('--md');
if (mdPath) { writeFileSync(mdPath, toMarkdown(report)); console.log(`Laudo Markdown: ${mdPath}`); }

// Sai diferente de zero tanto por falha crítica quanto por pendência crítica.
process.exit(report.summary.bloqueia > 0 ? 1 : 0);
