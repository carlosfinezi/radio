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

  // NÃO pedir `Icy-MetaData: 1` aqui. Com metadados ligados o servidor
  // interpola blocos de título no fluxo de áudio, e esses bytes entram na
  // contagem — viés sistemático para cima justamente no número que vai
  // para o laudo. Os cabeçalhos `icy-*` de resposta (inclusive `icy-br`)
  // vêm de qualquer forma.
  const { status, headers, req, res } = await openStream(url, {
    timeoutMs: (WARMUP_MS + seconds * 1000) * 2,
  });

  if (status !== 200) {
    req.destroy();
    throw new Error(`HTTP ${status} ao abrir o stream`);
  }

  return await new Promise((resolve, reject) => {
    let bytes = 0;
    let measuringFrom = null;
    let warmupTimer = null;
    let janelaTimer = null;
    let finalizado = false;

    const encerrar = (fn, arg) => {
      if (finalizado) return;
      finalizado = true;
      clearTimeout(warmupTimer);
      clearTimeout(janelaTimer);   // sem isso o processo ficava preso até 15s
      req.destroy();               // extras por medição quando havia erro
      fn(arg);
    };

    res.on('data', (chunk) => {
      if (measuringFrom === null) return; // ainda no burst
      bytes += chunk.length;
    });

    // "Contínuo e ininterrupto" (alínea a) significa que o mount NÃO fecha.
    // Sem este handler, um stream que morria no meio da janela era medido
    // como se tivesse durado a janela inteira: bytes parados, tempo correndo.
    // O bitrate saía baixo, mas checks do tipo "recebeu algum byte?" davam
    // PASS para uma rádio que caiu 6 segundos depois de abrir.
    res.on('end', () => encerrar(reject, new Error(
      `o servidor ENCERROU o stream após ${((Date.now() - (measuringFrom ?? Date.now())) / 1000).toFixed(1)}s ` +
      'de medição — transmissão não é contínua'
    )));
    res.on('aborted', () => encerrar(reject, new Error('conexão abortada pelo servidor')));
    res.on('error', (e) => encerrar(reject, e));
    req.on('error', (e) => encerrar(reject, e));

    // Só começa a contar depois do burst ter passado.
    warmupTimer = setTimeout(() => { measuringFrom = Date.now(); }, WARMUP_MS);

    janelaTimer = setTimeout(() => {
      const elapsedMs = measuringFrom ? Date.now() - measuringFrom : 0;
      if (!elapsedMs || bytes === 0) {
        return encerrar(reject, new Error('stream não entregou dados após o warmup'));
      }
      encerrar(resolve, {
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
  let pendingByteRange = null;
  let initSegment = null;
  let ultimoFimByteRange = 0;

  for (const line of lines) {
    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetDuration = Number(line.split(':')[1]);
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      const attrs = line.slice(line.indexOf(':') + 1);
      // `(?:^|,)` é obrigatório: /BANDWIDTH=(\d+)/ casa DENTRO de
      // `AVERAGE-BANDWIDTH=`, então um manifesto com
      // "AVERAGE-BANDWIDTH=120000,BANDWIDTH=128000" capturava 120000 —
      // e na escolha de variante podia selecionar a faixa errada.
      const bw = /(?:^|,)BANDWIDTH=(\d+)/.exec(attrs);
      pendingVariant = { bandwidth: bw ? Number(bw[1]) : null, raw: attrs };
    } else if (line.startsWith('#EXT-X-MAP:')) {
      const m = /URI="([^"]+)"/.exec(line);
      if (m) initSegment = new URL(m[1], baseUrl).toString();
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      // Formato: <tamanho>[@<offset>]. Sem offset, começa onde o anterior
      // terminou (RFC 8216 §4.3.2.2).
      const [tam, off] = line.split(':')[1].split('@').map(Number);
      const offset = Number.isFinite(off) ? off : ultimoFimByteRange;
      pendingByteRange = { length: tam, offset };
      ultimoFimByteRange = offset + tam;
    } else if (line.startsWith('#EXTINF:')) {
      segments.push({ duration: parseFloat(line.split(':')[1]), uri: null, byteRange: null });
    } else if (!line.startsWith('#')) {
      const abs = new URL(line, baseUrl).toString();
      if (pendingVariant) {
        variants.push({ ...pendingVariant, uri: abs });
        pendingVariant = null;
      } else {
        const last = segments[segments.length - 1];
        if (last && last.uri === null) {
          last.uri = abs;
          last.byteRange = pendingByteRange;
        } else {
          segments.push({ duration: null, uri: abs, byteRange: pendingByteRange });
        }
        pendingByteRange = null;
      }
    }
  }
  return { isMaster: variants.length > 0, variants, segments, targetDuration, initSegment };
}

/**
 * Mede a taxa real de um stream HLS baixando segmentos consecutivos.
 * Segue o master até a variante de maior BANDWIDTH.
 */
/**
 * @param {'min'|'max'} variante  Qual faixa do master medir.
 *   O edital exige velocidade MÍNIMA de 128 kbps. Medir a variante de maior
 *   bandwidth num master com 64k e 128k aprovaria um sistema em que o ouvinte
 *   em rede ruim recebe 64k. Por isso o padrão é 'min': validamos o pior caso
 *   que o ouvinte pode receber, que é o que o contrato garante.
 */
export async function measureHlsBitrate(url, seconds = 12, variante = 'min') {
  let manifestUrl = url;
  let m = parseM3U8((await fetchText(manifestUrl)).body, manifestUrl);

  let declaredBandwidth = null;
  let variantesDisponiveis = null;
  if (m.isMaster) {
    const comBw = m.variants.filter((v) => v.bandwidth != null);
    const lista = comBw.length ? comBw : m.variants;
    const escolhida = lista.reduce((a, b) => {
      const ba = a.bandwidth ?? Infinity, bb = b.bandwidth ?? Infinity;
      return variante === 'min' ? (bb < ba ? b : a) : (bb > ba ? b : a);
    });
    declaredBandwidth = escolhida.bandwidth;
    variantesDisponiveis = lista.map((v) => v.bandwidth);
    manifestUrl = escolhida.uri;
    m = parseM3U8((await fetchText(manifestUrl)).body, manifestUrl);
  }

  const segs = m.segments.filter((s) => s.uri);
  if (!segs.length) throw new Error('manifesto HLS sem segmentos');

  let totalBytes = 0;
  let totalDuration = 0;
  let lidos = 0;
  const deadline = Date.now() + seconds * 1000;

  for (const seg of segs) {
    if (Date.now() > deadline) break;

    // SEGMENTOS BYTE-RANGE (RFC 8216 §4.3.2.2) compartilham a mesma URI.
    // Baixar a URI inteira uma vez por segmento contava o arquivo N vezes:
    // um stream real de 61 kbps era medido como 182 kbps e aprovado na
    // alínea (b). Com Range, contamos exatamente os bytes do segmento.
    const opts = { signal: AbortSignal.timeout(20000) };
    if (seg.byteRange) {
      const ini = seg.byteRange.offset;
      const fim = ini + seg.byteRange.length - 1;
      opts.headers = { Range: `bytes=${ini}-${fim}` };
    }

    const r = await fetch(seg.uri, opts);
    if (!r.ok && r.status !== 206) throw new Error(`segmento HTTP ${r.status}: ${seg.uri}`);
    const recebidos = (await r.arrayBuffer()).byteLength;

    // Servidor que ignora Range devolve 200 com o arquivo inteiro; nesse caso
    // usamos o tamanho declarado no manifesto, não o que veio no corpo.
    totalBytes += seg.byteRange && r.status !== 206
      ? Math.min(seg.byteRange.length, recebidos)
      : recebidos;

    totalDuration += seg.duration || m.targetDuration || 0;
    lidos++;
  }

  if (!totalDuration) throw new Error('não foi possível apurar a duração dos segmentos');
  return {
    kbps: (totalBytes * 8) / (totalDuration * 1000),
    bytes: totalBytes,
    durationSec: totalDuration,
    segmentsRead: lidos,          // efetivamente baixados, não os do manifesto
    segmentsNoManifesto: segs.length,
    usouByteRange: segs.some((s) => s.byteRange),
    targetDuration: m.targetDuration,
    variantesDisponiveis,
    varianteMedida: variante,
    declaredBandwidthKbps: declaredBandwidth ? declaredBandwidth / 1000 : null,
  };
}

/**
 * Teste de carga: abre `n` conexões simultâneas e confirma que TODAS
 * recebem áudio de verdade. Evidência para a alínea (d).
 *
 * Retorna a contagem de conexões que receberam pelo menos `minBytes`.
 */
export async function concurrentListeners(url, n, {
  holdSeconds = 10,
  expectedKbps = 128,
  // Fração do áudio esperado que a conexão precisa ter recebido para contar
  // como ouvinte de verdade.
  minFracao = 0.5,
} = {}) {
  const esperadoBytes = (expectedKbps * 1000 * holdSeconds) / 8;
  const minBytes = Math.max(8192, esperadoBytes * minFracao);

  const results = await Promise.allSettled(
    Array.from({ length: n }, async (_, i) => {
      const { status, req, res } = await openStream(url, { timeoutMs: (holdSeconds + 20) * 1000 });
      if (status !== 200) { req.destroy(); throw new Error(`conexão ${i}: HTTP ${status}`); }

      let bytes = 0;
      let encerrouCedo = null;
      res.on('data', (c) => { bytes += c.length; });

      // UM ICECAST NO TETO DE `clients` ACEITA A CONEXÃO E DERRUBA EM SEGUIDA.
      // A versão anterior só olhava "recebeu mais de 8 KB?": os ~48 KB do
      // burst inicial bastavam, e a rejeição era contabilizada como
      // ouvinte atendido — o check feito para provar "ouvintes ilimitados"
      // pontuava a recusa como aprovação.
      const fim = new Promise((resolve) => {
        res.on('end', () => { encerrouCedo = 'servidor encerrou'; resolve(); });
        res.on('aborted', () => { encerrouCedo = 'conexão abortada'; resolve(); });
        res.on('error', (e) => { encerrouCedo = e.message; resolve(); });
        setTimeout(resolve, holdSeconds * 1000);
      });
      await fim;
      req.destroy();

      if (encerrouCedo) {
        throw new Error(`conexão ${i}: ${encerrouCedo} após ${bytes} bytes (esperado ~${Math.round(esperadoBytes)})`);
      }
      if (bytes < minBytes) {
        throw new Error(
          `conexão ${i}: recebeu ${bytes} bytes, esperado ao menos ${Math.round(minBytes)} ` +
          `(${expectedKbps} kbps × ${holdSeconds}s) — servidor aceitou e estrangulou`
        );
      }
      return bytes;
    })
  );

  const ok = results.filter((r) => r.status === 'fulfilled');
  return {
    requested: n,
    succeeded: ok.length,
    failed: n - ok.length,
    totalBytes: ok.reduce((s, r) => s + r.value, 0),
    esperadoPorConexao: Math.round(esperadoBytes),
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
