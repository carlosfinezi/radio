#!/usr/bin/env node
/**
 * Testes de regressão das sondas, contra servidores sintéticos.
 *
 * Cada caso aqui corresponde a um defeito REAL encontrado em auditoria, em
 * que a sonda aprovava algo não conforme. O objetivo não é cobrir a sonda:
 * é impedir que esses defeitos específicos voltem.
 */

import http from 'node:http';
import { measureIcyBitrate, measureHlsBitrate, parseM3U8, concurrentListeners } from './lib/probe.mjs';

let falhas = 0;
const ok = (c, m) => { console.log(`  ${c ? '\x1b[32m✓' : '\x1b[31m✗'}\x1b[0m ${m}`); if (!c) falhas++; };

function servidor(handler) {
  const s = http.createServer(handler);
  return new Promise((r) => s.listen(0, '127.0.0.1', () => r({ s, porta: s.address().port })));
}

/** Emite áudio no ritmo indicado; opcionalmente encerra antes da hora. */
function streamHandler({ kbps = 128, burstKB = 64, morrerApos = null }) {
  return (req, res) => {
    res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'icy-br': String(kbps) });
    res.write(Buffer.alloc(burstKB * 1024));
    const bytesPorTick = (kbps * 1000) / 8 / 10; // tick de 100ms
    const iv = setInterval(() => res.write(Buffer.alloc(Math.round(bytesPorTick))), 100);
    if (morrerApos) setTimeout(() => { clearInterval(iv); res.end(); }, morrerApos * 1000);
    req.on('close', () => clearInterval(iv));
  };
}

console.log('\n\x1b[1mREGRESSÃO DAS SONDAS\x1b[0m\n' + '─'.repeat(64));

// ── 1. Stream que morre no meio da janela deve REPROVAR ──────────────────
console.log('\n▸ Stream encerrado pelo servidor (alínea "a": contínuo e ininterrupto)');
{
  const { s, porta } = await servidor(streamHandler({ kbps: 128, morrerApos: 6 }));
  try {
    const r = await measureIcyBitrate(`http://127.0.0.1:${porta}/`, 12);
    ok(false, `deveria ter lançado erro, mas devolveu ${r.kbps.toFixed(1)} kbps`);
  } catch (e) {
    ok(/ENCERROU|abortada/i.test(e.message), `detectou encerramento: "${e.message.slice(0, 60)}…"`);
  }
  s.close();
}

// ── 2. Stream contínuo e correto deve APROVAR ────────────────────────────
console.log('\n▸ Stream contínuo a 128 kbps (caso de controle)');
{
  const { s, porta } = await servidor(streamHandler({ kbps: 128 }));
  try {
    const r = await measureIcyBitrate(`http://127.0.0.1:${porta}/`, 10);
    ok(Math.abs(r.kbps - 128) / 128 < 0.15, `mediu ${r.kbps.toFixed(1)} kbps (esperado ~128)`);
  } catch (e) { ok(false, `erro inesperado: ${e.message}`); }
  s.close();
}

// ── 3. AVERAGE-BANDWIDTH não pode ser confundido com BANDWIDTH ───────────
console.log('\n▸ Parser: AVERAGE-BANDWIDTH vs BANDWIDTH');
{
  const master = `#EXTM3U
#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=120000,BANDWIDTH=128000
hi.m3u8`;
  const m = parseM3U8(master, 'http://x/live.m3u8');
  ok(m.variants[0].bandwidth === 128000,
     `capturou BANDWIDTH=${m.variants[0].bandwidth} (esperado 128000, não 120000)`);
}

// ── 4. Seleção de variante deve pegar a MENOR (edital pede taxa MÍNIMA) ──
console.log('\n▸ Seleção de variante: pior caso que o ouvinte recebe');
{
  const master = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=64000
lo.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000
hi.m3u8`;
  const { s, porta } = await servidor((req, res) => {
    if (req.url.includes('live.m3u8')) { res.writeHead(200); return res.end(master); }
    // a variante "lo" entrega 64 kbps de verdade
    const media = `#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\nseg.aac`;
    if (req.url.includes('.m3u8')) { res.writeHead(200); return res.end(media); }
    res.writeHead(200); res.end(Buffer.alloc(32000)); // 32000B/4s = 64 kbps
  });
  const r = await measureHlsBitrate(`http://127.0.0.1:${porta}/live.m3u8`, 8, 'min');
  ok(r.declaredBandwidthKbps === 64,
     `mediu a variante mínima (${r.declaredBandwidthKbps} kbps), não a máxima — um sistema com faixa de 64k NÃO passa como 128k`);
  s.close();
}

// ── 5. EXT-X-BYTERANGE não pode multiplicar o bitrate ────────────────────
console.log('\n▸ Segmentos byte-range no mesmo arquivo');
{
  // 3 segmentos de 10s cada dentro de um arquivo de 227.208 bytes.
  // Bitrate real: 227208*8/30000 = 60,6 kbps.
  const TAM = 227208;
  const media = `#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.000,
#EXT-X-BYTERANGE:75736@0
all.aac
#EXTINF:10.000,
#EXT-X-BYTERANGE:75736
all.aac
#EXTINF:10.000,
#EXT-X-BYTERANGE:75736
all.aac`;
  let bytesServidos = 0;
  const { s, porta } = await servidor((req, res) => {
    if (req.url.endsWith('.m3u8')) { res.writeHead(200); return res.end(media); }
    const range = req.headers.range;
    if (range) {
      const [ini, fim] = range.replace('bytes=', '').split('-').map(Number);
      const n = fim - ini + 1;
      bytesServidos += n;
      res.writeHead(206, { 'Content-Range': `bytes ${ini}-${fim}/${TAM}` });
      return res.end(Buffer.alloc(n));
    }
    bytesServidos += TAM;
    res.writeHead(200); res.end(Buffer.alloc(TAM));
  });
  const r = await measureHlsBitrate(`http://127.0.0.1:${porta}/live.m3u8`, 20);
  const real = 60.6;
  ok(Math.abs(r.kbps - real) / real < 0.10,
     `mediu ${r.kbps.toFixed(1)} kbps (real ${real}) — antes media ~182 e aprovava como 128`);
  ok(r.usouByteRange === true, `detectou byte-range; baixou ${bytesServidos} bytes (arquivo tem ${TAM})`);
  s.close();
}

// ── 6. Conexão aceita e derrubada NÃO pode contar como ouvinte ───────────
console.log('\n▸ Teste de carga: servidor que aceita e derruba (teto de clients)');
{
  let nConn = 0;
  const { s, porta } = await servidor((req, res) => {
    const meu = ++nConn;
    res.writeHead(200, { 'Content-Type': 'audio/mpeg' });
    res.write(Buffer.alloc(48 * 1024)); // burst generoso
    if (meu > 4) { setTimeout(() => res.end(), 1500); return; } // derruba as excedentes
    const iv = setInterval(() => res.write(Buffer.alloc(1600)), 100);
    req.on('close', () => clearInterval(iv));
  });
  const r = await concurrentListeners(`http://127.0.0.1:${porta}/`, 8, { holdSeconds: 6 });
  ok(r.failed === 4 && r.succeeded === 4,
     `${r.succeeded} atendidas / ${r.failed} recusadas (esperado 4/4) — antes contava 8/0`);
  s.close();
}

console.log('\n' + '─'.repeat(64));
console.log(falhas === 0
  ? '\x1b[32m\x1b[1m✓ Todas as regressões passaram.\x1b[0m\n'
  : `\x1b[31m\x1b[1m✗ ${falhas} regressão(ões) falhando.\x1b[0m\n`);
process.exit(falhas === 0 ? 0 : 1);
