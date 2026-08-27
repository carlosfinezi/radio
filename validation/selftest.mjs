#!/usr/bin/env node
/**
 * Auto-teste das sondas contra streams públicos de bitrate CONHECIDO.
 *
 * Motivo: antes de usar essas sondas como prova de conformidade contratual,
 * elas próprias precisam ser provadas. Se a sonda medir 128 kbps num stream
 * que sabidamente é 128 kbps, ela é confiável. Se não, todo o laudo é lixo.
 */

import { measureIcyBitrate, concurrentListeners, fetchText, parseM3U8 } from './lib/probe.mjs';

const CASOS = [
  { url: 'https://ice1.somafm.com/groovesalad-128-mp3', esperado: 128, nome: 'SomaFM Groove Salad MP3' },
  { url: 'https://ice1.somafm.com/dronezone-128-mp3', esperado: 128, nome: 'SomaFM Drone Zone MP3' },
];

const TOLERANCIA = 0.10; // encoders reais oscilam; 10% é generoso mas ainda detecta erro grosseiro
let falhas = 0;

console.log('\n\x1b[1mAUTO-TESTE DAS SONDAS\x1b[0m');
console.log('─'.repeat(64));

for (const caso of CASOS) {
  process.stdout.write(`\n▸ ${caso.nome} (esperado ${caso.esperado} kbps)\n`);
  try {
    const m = await measureIcyBitrate(caso.url, 12);
    const desvio = Math.abs(m.kbps - caso.esperado) / caso.esperado;
    const ok = desvio <= TOLERANCIA;
    if (!ok) falhas++;
    console.log(
      `  ${ok ? '\x1b[32m✓' : '\x1b[31m✗'}\x1b[0m medido: \x1b[1m${m.kbps.toFixed(2)} kbps\x1b[0m ` +
      `| declarado: ${m.icy['icy-br']} kbps | desvio: ${(desvio * 100).toFixed(2)}%`
    );
    console.log(`    \x1b[2m${m.bytes} bytes em ${(m.elapsedMs / 1000).toFixed(2)}s · ${m.contentType}\x1b[0m`);
  } catch (e) {
    falhas++;
    console.log(`  \x1b[31m✗ ERRO: ${e.message}\x1b[0m`);
  }
}

// Teste de concorrência: prova que a sonda da alínea (d) funciona
console.log(`\n▸ Sonda de carga: 25 ouvintes simultâneos`);
try {
  const r = await concurrentListeners(CASOS[0].url, 25, { holdSeconds: 6 });
  const ok = r.failed === 0;
  if (!ok) falhas++;
  console.log(
    `  ${ok ? '\x1b[32m✓' : '\x1b[31m✗'}\x1b[0m ${r.succeeded}/${r.requested} conexões receberam áudio ` +
    `(${(r.totalBytes / 1048576).toFixed(2)} MB)`
  );
  if (r.errors.length) console.log(`    \x1b[2m${r.errors.join(' | ')}\x1b[0m`);
} catch (e) {
  falhas++;
  console.log(`  \x1b[31m✗ ERRO: ${e.message}\x1b[0m`);
}

// Teste do parser M3U8 com entrada sintética (não depende de rede)
console.log(`\n▸ Parser M3U8`);
try {
  const master = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
128/live.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=256000,CODECS="mp4a.40.2"
256/live.m3u8`;
  const m1 = parseM3U8(master, 'https://r.exemplo.br/hls/live.m3u8');
  const media = `#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:4.000,
seg100.aac
#EXTINF:4.000,
seg101.aac`;
  const m2 = parseM3U8(media, 'https://r.exemplo.br/hls/128/live.m3u8');

  const ok = m1.isMaster && m1.variants.length === 2 && m1.variants[1].bandwidth === 256000
    && !m2.isMaster && m2.segments.length === 2 && m2.targetDuration === 4
    && m2.segments[0].uri === 'https://r.exemplo.br/hls/128/seg100.aac';
  if (!ok) falhas++;
  console.log(`  ${ok ? '\x1b[32m✓' : '\x1b[31m✗'}\x1b[0m master=${m1.variants.length} variantes · media=${m2.segments.length} segmentos · resolução de URL relativa OK`);
} catch (e) {
  falhas++;
  console.log(`  \x1b[31m✗ ERRO: ${e.message}\x1b[0m`);
}

console.log('\n' + '─'.repeat(64));
if (falhas === 0) {
  console.log('\x1b[32m\x1b[1m✓ Sondas validadas — medições são confiáveis.\x1b[0m\n');
} else {
  console.log(`\x1b[31m\x1b[1m✗ ${falhas} falha(s) — NÃO usar o laudo até corrigir as sondas.\x1b[0m\n`);
}
process.exit(falhas === 0 ? 0 : 1);
