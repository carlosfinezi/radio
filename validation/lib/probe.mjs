/**
 * Sondas de baixo nível para validação de streaming de áudio.
 *
 * Princípio: medir o que o servidor ENTREGA, não o que ele DECLARA.
 * Cabeçalho `icy-br: 128` é uma afirmação; 10 segundos de bytes contados é prova.
 */

import http from 'node:http';
import https from 'node:https';
import { URL } from 'node:url';

/**
 * O prefixo `Mozilla/5.0` não é cosmético: servidores Icecast (e o fork KH,
 * muito usado em produção) derrubam a conexão de User-Agents com cara de bot.
 * Medido em 27/08/2026: "WebRadioValidator/1.0" e qualquer UA com o padrão
 * "(+...)" levam socket hang up; com o prefixo Mozilla a conexão é aceita.
 * Mantemos o nome do validador visível para não mascarar quem somos nos logs.
 */
const UA = 'Mozilla/5.0 (compatible; WebRadioValidator/1.0)';

function client(u) {
  return u.protocol === 'https:' ? https : http;
}

/**
 * GET cru com controle de socket. Resolve com { status, headers, req, res }
 * SEM consumir o corpo — quem chama decide o que fazer com o fluxo.
 */
export function openStream(url, { headers = {}, timeoutMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = client(u).get(
      u,
      { headers: { 'User-Agent': UA, ...headers }, timeout: timeoutMs },
      (res) => resolve({ status: res.statusCode, headers: res.headers, req, res })
    );
    req.on('timeout', () => { req.destroy(new Error(`timeout após ${timeoutMs}ms`)); });
    req.on('error', reject);
  });
}

/**
 * Mede a taxa REAL de um stream contínuo (Icecast/ICY, MP3 ou AAC).
 *
 * O Icecast entrega um burst inicial (buffer de arranque do player) a toda a
 * velocidade do link e só depois passa a "pacear" em tempo real. Medir sem
 * descartar esse burst infla o resultado grosseiramente.
 *
 * Calibração empírica contra stream de 128 kbps conhecido (27/08/2026):
 *   1º segundo: 2227 kbps (burst) · 2º em diante: ~128 kbps (estável)
 *   jitter por janela de 1s: 110-150 kbps · média de 12s+: 128,4 kbps
 * Daí WARMUP_MS=3000 (3x a duração do burst observado) e janela mínima de 12s.
 *
 * @returns {{kbps:number, bytes:number, elapsedMs:number, icy:object, contentType:string}}
 */
export async function measureIcyBitrate(url, seconds = 12) {
  const WARMUP_MS = 3000;
  if (seconds < 10) {
    // Abaixo disso o jitter de ±17% mascara o resultado e o laudo vira ruído.
    seconds = 10;
  }

  const { status, headers, req, res } = await openStream(url, {
    headers: { 'Icy-MetaData': '1' },
    timeoutMs: (WARMUP_MS + seconds * 1000) * 2,
  });

  if (status !== 200) {
    req.destroy();
    throw new Error(`HTTP ${status} ao abrir o stream`);
  }

  return await new Promise((resolve, reject) => {
    let bytes = 0;
    let measuringFrom = null;

    res.on('data', (chunk) => {
      if (measuringFrom === null) return; // ainda no burst
      bytes += chunk.length;
    });
    res.on('error', reject);
    req.on('error', reject);

    // Só começa a contar depois do burst ter passado.
    const warmupTimer = setTimeout(() => { measuringFrom = Date.now(); }, WARMUP_MS);

    setTimeout(() => {
      clearTimeout(warmupTimer);
      const elapsedMs = measuringFrom ? Date.now() - measuringFrom : 0;
      req.destroy();
      if (!elapsedMs || bytes === 0) {
        return reject(new Error('stream não entregou dados após o warmup'));
      }
      resolve({
        kbps: (bytes * 8) / elapsedMs, // bytes*8/ms === kbits/s
        bytes,
        elapsedMs,
        icy: Object.fromEntries(
          Object.entries(headers).filter(([k]) => k.startsWith('icy-'))
        ),
        contentType: headers['content-type'] || null,
      });
    }, WARMUP_MS + seconds * 1000);
  });
}

/** Faz GET e devolve o corpo como texto (para manifestos, JSON, HTML). */
export async function fetchText(url, opts = {}) {
  const r = await fetch(url, {
    headers: { 'User-Agent': UA, ...(opts.headers || {}) },
    signal: AbortSignal.timeout(opts.timeoutMs ?? 15000),
    redirect: 'follow',
  });
  return { status: r.status, headers: Object.fromEntries(r.headers), body: await r.text() };
}

/** Parser mínimo de M3U8. Extrai variantes (master) ou segmentos (media). */
export function parseM3U8(text, baseUrl) {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!lines[0]?.startsWith('#EXTM3U')) throw new Error('não é um manifesto M3U8 válido');

  const variants = [];
  const segments = [];
  let targetDuration = null;
  let pendingVariant = null;

  for (const line of lines) {
    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetDuration = Number(line.split(':')[1]);
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      const attrs = line.slice(line.indexOf(':') + 1);
      const bw = /BANDWIDTH=(\d+)/.exec(attrs);
      pendingVariant = { bandwidth: bw ? Number(bw[1]) : null, raw: attrs };
    } else if (line.startsWith('#EXTINF:')) {
      segments.push({ duration: parseFloat(line.split(':')[1]), uri: null });
    } else if (!line.startsWith('#')) {
      const abs = new URL(line, baseUrl).toString();
      if (pendingVariant) {
        variants.push({ ...pendingVariant, uri: abs });
        pendingVariant = null;
      } else {
        const last = segments[segments.length - 1];
        if (last && last.uri === null) last.uri = abs;
        else segments.push({ duration: null, uri: abs });
      }
    }
  }
  return { isMaster: variants.length > 0, variants, segments, targetDuration };
}

/**
 * Mede a taxa real de um stream HLS baixando segmentos consecutivos.
 * Segue o master até a variante de maior BANDWIDTH.
 */
export async function measureHlsBitrate(url, seconds = 12) {
  let manifestUrl = url;
  let m = parseM3U8((await fetchText(manifestUrl)).body, manifestUrl);

  let declaredBandwidth = null;
  if (m.isMaster) {
    const best = m.variants.reduce((a, b) => ((b.bandwidth ?? 0) > (a.bandwidth ?? 0) ? b : a));
    declaredBandwidth = best.bandwidth;
    manifestUrl = best.uri;
    m = parseM3U8((await fetchText(manifestUrl)).body, manifestUrl);
  }

  const segs = m.segments.filter((s) => s.uri);
  if (!segs.length) throw new Error('manifesto HLS sem segmentos');

  let totalBytes = 0;
  let totalDuration = 0;
  const deadline = Date.now() + seconds * 1000;

  for (const seg of segs) {
    if (Date.now() > deadline) break;
    const r = await fetch(seg.uri, { signal: AbortSignal.timeout(20000) });
    if (!r.ok) throw new Error(`segmento HTTP ${r.status}: ${seg.uri}`);
    totalBytes += (await r.arrayBuffer()).byteLength;
    totalDuration += seg.duration || m.targetDuration || 0;
  }

  if (!totalDuration) throw new Error('não foi possível apurar a duração dos segmentos');
  return {
    kbps: (totalBytes * 8) / (totalDuration * 1000),
    bytes: totalBytes,
    durationSec: totalDuration,
    segmentsRead: segs.length,
    targetDuration: m.targetDuration,
    declaredBandwidthKbps: declaredBandwidth ? declaredBandwidth / 1000 : null,
  };
}

/**
 * Teste de carga: abre `n` conexões simultâneas e confirma que TODAS
 * recebem áudio de verdade. Evidência para a alínea (d).
 *
 * Retorna a contagem de conexões que receberam pelo menos `minBytes`.
 */
export async function concurrentListeners(url, n, { holdSeconds = 10, minBytes = 8192 } = {}) {
  const results = await Promise.allSettled(
    Array.from({ length: n }, async (_, i) => {
      const { status, req, res } = await openStream(url, { timeoutMs: 30000 });
      if (status !== 200) { req.destroy(); throw new Error(`conexão ${i}: HTTP ${status}`); }
      let bytes = 0;
      res.on('data', (c) => { bytes += c.length; });
      await new Promise((r) => setTimeout(r, holdSeconds * 1000));
      req.destroy();
      if (bytes < minBytes) throw new Error(`conexão ${i}: só ${bytes} bytes`);
      return bytes;
    })
  );

  const ok = results.filter((r) => r.status === 'fulfilled');
  return {
    requested: n,
    succeeded: ok.length,
    failed: n - ok.length,
    totalBytes: ok.reduce((s, r) => s + r.value, 0),
    errors: results.filter((r) => r.status === 'rejected').map((r) => String(r.reason)).slice(0, 5),
  };
}

/** Chamada autenticada à API do AzuraCast. */
export async function azuraApi(baseUrl, apiKey, path) {
  const r = await fetch(new URL(path, baseUrl), {
    headers: { 'X-API-Key': apiKey, Accept: 'application/json', 'User-Agent': UA },
    signal: AbortSignal.timeout(20000),
  });
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* deixa null; quem chama trata */ }
  return { status: r.status, json, text: text.slice(0, 500) };
}
