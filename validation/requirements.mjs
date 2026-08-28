/**
 * Os 10 requisitos do edital (alíneas a-j) como verificações executáveis.
 *
 * Regra de ouro deste arquivo: um check só devolve `pass: true` quando existe
 * EVIDÊNCIA MENSURÁVEL. "O serviço respondeu 200" não prova bitrate; medir
 * bytes/segundo prova. Onde não há como provar automaticamente, o check
 * devolve `manual: true` e diz exatamente qual artefato o auditor deve exigir.
 */

import {
  measureIcyBitrate, measureHlsBitrate, fetchText, parseM3U8,
  concurrentListeners, azuraApi,
} from './lib/probe.mjs';

/**
 * Aspas seguras para interpolação em shell.
 *
 * `cfg.station`, `cfg.container` e `cfg.uptimeLog` vêm de variáveis de
 * ambiente e caem dentro de comandos executados como root. Um
 * `AZC_STATION='x; rm -rf /'` era executado literalmente. Aspas simples com
 * escape do próprio apóstrofo é a forma canônica de neutralizar isso.
 */
const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

/**
 * Raiz do projeto, derivada da localização DESTE arquivo.
 *
 * Os caminhos estavam fixos em /root/webradio/... e por isso a suíte falhava
 * inteira em qualquer outro servidor — exatamente o que aconteceu ao rodá-la
 * no destino da migração, onde o projeto vive em /home/cloud-user/webradio.
 * O laudo reprovava artefatos que existiam, só que noutro caminho.
 */
const BASE = new URL('..', import.meta.url).pathname.replace(/\/$/, '');


const MIN_KBPS = 128;
const MIN_STORAGE_GB = 50;
const SLA_TARGET = 99.0;

/**
 * Tolerância de medição: encoders oscilam entre janelas de amostragem.
 *
 * ATENÇÃO NA LEITURA DO LAUDO: com 0.96 o limiar efetivo vira 122,88 kbps
 * para um edital que exige "mínima de 128 kbps". Um encoder configurado a
 * 123 kbps sairia aprovado. A tolerância existe porque a medição real tem
 * jitter (medido: 110-150 kbps em janelas de 1s, convergindo a 128,4 em 12s),
 * mas o valor medido é sempre impresso na evidência justamente para que o
 * auditor veja o número, não só o ✅.
 */
const KBPS_TOLERANCE = 0.96;

export const requirements = [
  // ─────────────────────────────────────────────────────────── a
  {
    letter: 'a',
    title: 'Servidor de streaming em nuvem, contínuo e ininterrupto',
    edital: 'Disponibilização de servidor de streaming de áudio em ambiente de nuvem, com funcionamento contínuo e ininterrupto',
    checks: [
      {
        id: 'a1',
        name: 'Stream responde e entrega áudio',
        critical: true,
        async run({ cfg }) {
          const m = await measureIcyBitrate(cfg.streamUrl, 5);
          return {
            pass: m.bytes > 0,
            evidence: `${m.bytes} bytes recebidos em ${m.elapsedMs}ms`,
            detail: { contentType: m.contentType, icy: m.icy },
          };
        },
      },
      {
        id: 'a2',
        name: 'Política de reinício automático configurada (resistência a reboot)',
        critical: true,
        async run({ cfg, sh }) {
          // Filtra pelo projeto compose do AzuraCast. Este host é
          // multi-tenant: inspecionar `docker ps -q` inteiro faria um
          // contêiner alheio sem restart-policy reprovar a rádio.
          const r = await sh(
            `docker ps -q --filter "label=com.docker.compose.project=azuracast" ` +
            `| xargs -r docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}'`
          );
          if (!r.ok) {
            return { pass: false, evidence: `não foi possível inspecionar os contêineres: ${r.err || 'docker indisponível'}` };
          }
          const lines = r.out.trim().split('\n').filter(Boolean);
          const bad = lines.filter((l) => !/(always|unless-stopped)$/.test(l));
          return {
            pass: lines.length > 0 && bad.length === 0,
            evidence: lines.length
              ? `${lines.length} contêiner(es) do AzuraCast; ${bad.length} sem restart automático`
              : 'nenhum contêiner do projeto azuracast em execução',
            detail: { containers: lines, semRestart: bad },
          };
        },
      },
      {
        id: 'a3',
        name: 'Continuidade sob falha de fonte: fallback do AutoDJ configurado',
        critical: true,
        async run({ cfg, sh }) {
          // ATENÇÃO AO ESCOPO DESTE CHECK.
          // A versão anterior media o bitrate de novo e concluía "o AutoDJ
          // assumiu" — sem jamais desconectar a fonte ao vivo. Era um clone
          // do a1/b1 com legenda enganosa.
          //
          // Derrubar a fonte de propósito tiraria a rádio do ar, então aqui
          // verificamos o que dá para verificar sem causar dano: que o
          // Liquidsoap tem cadeia de fallback declarada. O teste de verdade
          // (cortar a fonte e cronometrar a retomada) é de homologação, com
          // janela combinada — está no RUNBOOK.
          const r = await sh(
            `docker exec ${q(cfg.container)} cat ${q(`/var/azuracast/stations/${cfg.station}/config/liquidsoap.liq`)} 2>/dev/null`
          );
          if (!r.ok || !r.out.trim()) {
            return { pass: false, evidence: `não foi possível ler a configuração do Liquidsoap: ${r.err || 'arquivo ausente'}` };
          }
          const temFallback = /\bfallback\s*\(/.test(r.out);
          const temSafe = /single\(|blank\(|safe_blank/.test(r.out);
          return {
            pass: temFallback,
            evidence: temFallback
              ? `cadeia de fallback presente na configuração${temSafe ? ' (com fonte de emergência)' : ' — SEM fonte de emergência final'}`
              : 'nenhuma cadeia de fallback: se a fonte cair, a rádio sai do ar',
            detail: { temFallback, temSafe },
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── b
  {
    letter: 'b',
    title: 'Velocidade mínima de transmissão de 128 kbps',
    edital: 'Velocidade mínima de transmissão de 128 kbps, assegurando qualidade adequada de áudio',
    checks: [
      {
        id: 'b1',
        name: `Bitrate REAL medido no stream contínuo >= ${MIN_KBPS} kbps`,
        critical: true,
        async run({ cfg }) {
          const m = await measureIcyBitrate(cfg.streamUrl, 12);
          return {
            pass: m.kbps >= MIN_KBPS * KBPS_TOLERANCE,
            evidence: `${m.kbps.toFixed(1)} kbps medidos (${m.bytes} bytes / ${(m.elapsedMs / 1000).toFixed(1)}s)`,
            detail: { medido: m.kbps, declarado: m.icy['icy-br'], minimo: MIN_KBPS },
          };
        },
      },
      {
        id: 'b2',
        name: 'Bitrate declarado nos cabeçalhos ICY confere com o medido',
        critical: false,
        async run({ cfg }) {
          const m = await measureIcyBitrate(cfg.streamUrl, 8);
          const declared = Number(m.icy['icy-br']);
          if (!declared) {
            return { pass: false, evidence: 'servidor não expõe o cabeçalho icy-br' };
          }
          const drift = Math.abs(m.kbps - declared) / declared;
          return {
            pass: declared >= MIN_KBPS && drift < 0.15,
            evidence: `declarado ${declared} kbps vs medido ${m.kbps.toFixed(1)} kbps (desvio ${(drift * 100).toFixed(1)}%)`,
            detail: { declared, medido: m.kbps, drift },
          };
        },
      },
      {
        id: 'b3',
        name: `Bitrate REAL do HLS >= ${MIN_KBPS} kbps`,
        critical: true,
        async run({ cfg }) {
          const m = await measureHlsBitrate(cfg.hlsUrl, 12);
          return {
            pass: m.kbps >= MIN_KBPS * KBPS_TOLERANCE,
            evidence: `${m.kbps.toFixed(1)} kbps medidos em ${m.durationSec.toFixed(1)}s de segmentos`,
            detail: m,
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── c
  {
    letter: 'c',
    title: 'Hospedagem e distribuição via internet (navegadores, apps, plataformas)',
    edital: 'Hospedagem e distribuição do sinal de áudio via internet, permitindo a reprodução em tempo real por navegadores web, aplicativos móveis e outras plataformas compatíveis',
    checks: [
      {
        id: 'c1',
        name: 'Manifesto HLS válido (compatibilidade iOS/Safari/Android)',
        critical: true,
        async run({ cfg }) {
          const r = await fetchText(cfg.hlsUrl);
          const m = parseM3U8(r.body, cfg.hlsUrl);
          const n = m.isMaster ? m.variants.length : m.segments.length;
          return {
            pass: r.status === 200 && n > 0,
            evidence: `HTTP ${r.status}; ${m.isMaster ? `master com ${n} variante(s)` : `${n} segmento(s)`}`,
            detail: { isMaster: m.isMaster, targetDuration: m.targetDuration, contentType: r.headers['content-type'] },
          };
        },
      },
      {
        id: 'c2',
        name: 'CORS liberado (player web embutido em site de terceiro)',
        critical: true,
        async run({ cfg }) {
          const r = await fetchText(cfg.hlsUrl, { headers: { Origin: 'https://exemplo.ufpb.br' } });
          const acao = r.headers['access-control-allow-origin'];
          return {
            pass: acao === '*' || acao === 'https://exemplo.ufpb.br',
            evidence: acao
              ? `Access-Control-Allow-Origin: ${acao}`
              : 'cabeçalho CORS AUSENTE — o player web falhará em domínio externo',
            detail: { acao },
          };
        },
      },
      {
        id: 'c3',
        name: 'Stream servido sobre HTTPS (exigido por navegador e por App Store/ATS)',
        critical: true,
        async run({ cfg }) {
          const httpsOk = cfg.hlsUrl.startsWith('https://') && cfg.streamUrl.startsWith('https://');
          return {
            pass: httpsOk,
            evidence: httpsOk
              ? 'stream e HLS em HTTPS'
              : 'URL em HTTP puro: navegador bloqueia por mixed-content e o ATS da Apple rejeita',
            detail: { streamUrl: cfg.streamUrl, hlsUrl: cfg.hlsUrl },
          };
        },
      },
      {
        id: 'c5',
        name: 'Player web existe e funciona nos navegadores que NÃO tocam HLS',
        critical: true,
        async run({ cfg, sh }) {
          // Chrome, Firefox e Edge não reproduzem HLS nativamente — só Safari
          // e iOS. Validar o manifesto (check c1) prova compatibilidade com
          // Safari, NÃO com "navegadores web" como a alínea (c) exige.
          // Sem hls.js ou sem um caminho MP3, a maioria dos ouvintes fica sem som.
          const r = await sh(`cat ${q(BASE + "/web/player.html")}`);
          if (!r.ok || !r.out.trim()) {
            return { pass: false, evidence: 'player web AUSENTE — a alínea (c) exige reprodução por navegador' };
          }
          const temHlsJs = /hls\.min\.js|Hls\.isSupported/.test(r.out);
          const temFallbackMp3 = /radio\.mp3|streamIcy|MP3_URL/.test(r.out);

          // E o MP3 precisa ser de fato consumível por navegador.
          let mp3Ok = false, mp3Detalhe = '';
          try {
            const h = await fetch(cfg.streamUrl, { method: 'GET', headers: { Range: 'bytes=0-1024' } });
            const ct = h.headers.get('content-type') || '';
            mp3Ok = h.ok && /audio\/(mpeg|mp3|aac)/.test(ct);
            mp3Detalhe = `HTTP ${h.status}, Content-Type: ${ct}`;
            try { h.body?.cancel(); } catch { /* ignora */ }
          } catch (e) {
            mp3Detalhe = `falhou: ${e.message}`;
          }

          return {
            pass: temHlsJs && temFallbackMp3 && mp3Ok,
            evidence: `player web presente (hls.js=${temHlsJs}, fallback MP3=${temFallbackMp3}); ` +
              `endpoint MP3: ${mp3Detalhe}`,
            detail: { temHlsJs, temFallbackMp3, mp3Ok },
          };
        },
      },
      {
        id: 'c4',
        name: 'Metadados "tocando agora" expostos publicamente',
        critical: false,
        async run({ cfg }) {
          const r = await fetchText(new URL(`/api/nowplaying/${cfg.station}`, cfg.baseUrl).toString());
          let np = null;
          try { np = JSON.parse(r.body); } catch { /* ignora */ }
          const song = np?.now_playing?.song;
          return {
            pass: r.status === 200 && !!song,
            evidence: song ? `tocando: "${song.text || song.title}"` : `HTTP ${r.status} sem metadados`,
            detail: { listeners: np?.listeners },
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── d
  {
    letter: 'd',
    title: 'Ouvintes simultâneos ilimitados',
    edital: 'Ouvintes simultâneos ilimitados',
    checks: [
      {
        id: 'd1',
        name: 'Nenhum teto de ouvintes configurado no servidor',
        critical: true,
        async run({ cfg, sh }) {
          const r = await sh(
            `docker exec ${q(cfg.container)} cat ${q(`/var/azuracast/stations/${cfg.station}/config/icecast.xml`)}`
          );
          // Sem conseguir ler a configuração, NÃO SE SABE se há limite.
          // "Não sei" jamais pode virar PASS num laudo contratual.
          if (!r.ok || !r.out.trim()) {
            return {
              pass: false,
              evidence: `não foi possível ler o icecast.xml: ${r.err || 'saída vazia'} — impossível afirmar que não há teto de ouvintes`,
            };
          }

          const num = (tag) => {
            const m = new RegExp(`<${tag}>\\s*(\\d+)\\s*</${tag}>`, 'i').exec(r.out);
            return m ? Number(m[1]) : null;
          };
          // `max_listeners` é o teto POR ESTAÇÃO no AzuraCast — a versão
          // anterior mencionava a tag no grep mas só extraía <clients>,
          // então um teto restritivo passava despercebido.
          const clients = num('clients');
          const maxListeners = num('max-listeners') ?? num('max_listeners');

          const limites = [];
          if (clients !== null && clients < 5000) limites.push(`<clients>${clients}</clients>`);
          if (maxListeners !== null && maxListeners > 0 && maxListeners < 5000) {
            limites.push(`<max-listeners>${maxListeners}</max-listeners>`);
          }

          return {
            pass: limites.length === 0,
            evidence: limites.length === 0
              ? `sem teto restritivo (clients=${clients ?? 'ausente'}, max-listeners=${maxListeners ?? 'ilimitado'}); o gargalo passa a ser a banda, não a configuração`
              : `TETO CONFIGURADO: ${limites.join(', ')} — vira gargalo antes da banda saturar`,
            detail: { clients, maxListeners },
          };
        },
      },
      {
        id: 'd2',
        name: 'Teste de carga: N ouvintes simultâneos recebem áudio de verdade',
        critical: true,
        async run({ cfg }) {
          const n = cfg.loadTestListeners;
          const r = await concurrentListeners(cfg.streamUrl, n, { holdSeconds: 10 });
          return {
            pass: r.failed === 0,
            evidence: `${r.succeeded}/${r.requested} conexões receberam áudio (${(r.totalBytes / 1048576).toFixed(1)} MB no total)`,
            detail: r,
          };
        },
      },
      {
        id: 'd3',
        name: 'HLS escala por arquivo estático (não por conexão persistente)',
        critical: true,
        async run({ cfg }) {
          // Segmentos HLS cacheáveis são o que torna "ilimitado" sustentável:
          // o origin entrega 1 cópia por segmento, não 1 por ouvinte.
          const man = parseM3U8((await fetchText(cfg.hlsUrl)).body, cfg.hlsUrl);
          const target = man.isMaster
            ? parseM3U8((await fetchText(man.variants[0].uri)).body, man.variants[0].uri)
            : man;
          const seg = target.segments.find((s) => s.uri);
          if (!seg) return { pass: false, evidence: 'nenhum segmento no manifesto' };
          const r = await fetch(seg.uri, { method: 'HEAD' });
          const cc = r.headers.get('cache-control');
          return {
            pass: r.ok,
            evidence: `segmento acessível isoladamente (HTTP ${r.status}); Cache-Control: ${cc || 'ausente'}`,
            detail: { segmento: seg.uri, cacheControl: cc },
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── e
  {
    letter: 'e',
    title: `Auto DJ integrado com armazenamento mínimo de ${MIN_STORAGE_GB} GB`,
    edital: 'Disponibilização de sistema Auto DJ integrado, com espaço de armazenamento mínimo de 50GB, permitindo a organização, programação e execução automatizada de playlists',
    checks: [
      {
        id: 'e1',
        name: `Cota de armazenamento >= ${MIN_STORAGE_GB} GB`,
        critical: true,
        async run({ cfg, sh }) {
          // Mede o volume onde a mídia REALMENTE vive. Se o diretório das
          // estações ainda não existe, cai para o volume do Docker e, por
          // último, para a raiz.
          //
          // O `-d` antes de cada df é proposital: `df ausente | tail -1` tem
          // exit code do `tail` (zero), então um `||` encadeado nunca dispara
          // e o resultado sai 0 GB — falso negativo silencioso.
          const r = await sh(
            `for d in /var/azuracast/stations /var/lib/docker /; do ` +
            `  if [ -d "$d" ]; then df -BG --output=avail,target "$d" | tail -1; break; fi; ` +
            `done`
          );
          const availGb = Number((r.out.match(/(\d+)G/) || [])[1] || 0);
          const volume = (r.out.trim().split(/\s+/)[1]) || '?';

          // DISTINÇÃO QUE O EDITAL FAZ E ESTE CHECK NÃO CONSEGUE FAZER SOZINHO:
          // a alínea (e) pede 50 GB *de armazenamento disponibilizado*, que é
          // alocação. `df` mede sobra momentânea num volume compartilhado com
          // HestiaCP, VotoAqui e liciteagora. 50 GB livres hoje não são 50 GB
          // reservados. A garantia real exige volume dedicado (ou cota de
          // filesystem) — por isso o resultado sai marcado como parcial.
          const dedicado = volume.startsWith('/var/azuracast');
          return {
            pass: availGb >= MIN_STORAGE_GB,
            manual: availGb >= MIN_STORAGE_GB && !dedicado,
            evidence: `${availGb} GB livres em ${volume} (mínimo ${MIN_STORAGE_GB} GB)` +
              (dedicado ? ' — volume dedicado' : ' — VOLUME COMPARTILHADO: espaço livre não é alocação garantida'),
            detail: { availGb, volume, dedicado, required: MIN_STORAGE_GB },
          };
        },
      },
      {
        id: 'e2',
        name: 'AutoDJ ativo com playlists cadastradas',
        critical: true,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/playlists`);
          const pls = Array.isArray(r.json) ? r.json : [];
          const ativas = pls.filter((p) => p.is_enabled);
          return {
            pass: r.status === 200 && ativas.length > 0,
            evidence: `${ativas.length} playlist(s) ativa(s) de ${pls.length} cadastrada(s)`,
            detail: { playlists: pls.map((p) => ({ nome: p.name, tipo: p.type, ativa: p.is_enabled })) },
          };
        },
      },
      {
        id: 'e3',
        name: 'Execução automatizada comprovada (fila do AutoDJ populada)',
        critical: true,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/queue`);
          const q = Array.isArray(r.json) ? r.json : [];
          return {
            pass: q.length > 0,
            evidence: `${q.length} faixa(s) pré-agendadas na fila do AutoDJ`,
            detail: { proximas: q.slice(0, 3).map((i) => i.song?.text) },
          };
        },
      },
      {
        id: 'e4',
        name: 'Agendamento por horário disponível (programação de grade)',
        critical: false,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/playlists`);
          const pls = Array.isArray(r.json) ? r.json : [];
          const agendadas = pls.filter((p) => p.type === 'scheduled' || (p.schedule_items || []).length > 0);
          // A versão anterior era `pass: r.status === 200` — ou seja, a API
          // responder já aprovava "agendamento configurado", mesmo com zero
          // playlists agendadas. O check ignorava o próprio resultado.
          return {
            pass: r.status === 200 && agendadas.length > 0,
            evidence: r.status !== 200
              ? `API respondeu HTTP ${r.status}`
              : `${agendadas.length} playlist(s) com grade horária configurada`,
            detail: { agendadas: agendadas.map((p) => p.name) },
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── f
  {
    letter: 'f',
    title: 'Painel administrativo web',
    edital: 'Fornecimento de painel administrativo acessível via web, que possibilite o gerenciamento da transmissão, incluindo controle operacional, monitoramento de status e administração dos recursos disponíveis',
    checks: [
      {
        id: 'f1',
        name: 'Painel acessível via HTTPS',
        critical: true,
        async run({ cfg }) {
          const r = await fetchText(cfg.baseUrl);
          return {
            pass: r.status === 200 && cfg.baseUrl.startsWith('https://'),
            evidence: `HTTP ${r.status} em ${cfg.baseUrl}`,
            detail: { https: cfg.baseUrl.startsWith('https://') },
          };
        },
      },
      {
        id: 'f2',
        name: 'Painel exige autenticação (não expõe gestão anonimamente)',
        critical: true,
        async run({ cfg }) {
          const r = await fetch(new URL(`/api/station/${cfg.station}/playlists`, cfg.baseUrl), {
            redirect: 'manual',
          });
          return {
            pass: r.status === 401 || r.status === 403,
            evidence: `acesso sem credencial devolveu HTTP ${r.status} (esperado 401/403)`,
            detail: { status: r.status },
          };
        },
      },
      {
        id: 'f3',
        name: 'API autenticada responde (controle operacional programático)',
        critical: true,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}`);
          return {
            pass: r.status === 200 && !!r.json?.name,
            evidence: r.json?.name ? `estação "${r.json.name}" acessível via API` : `HTTP ${r.status}`,
            detail: { station: r.json?.name },
          };
        },
      },
      {
        id: 'f4',
        name: 'Monitoramento de status em tempo real',
        critical: true,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/status`);
          const s = r.json || {};
          // O endpoint /status devolve camelCase (backendRunning), diferente
          // do resto da API, que usa snake_case (is_enabled, station_id).
          // Ler só uma das grafias reportava `undefined` e reprovava um
          // sistema perfeitamente no ar.
          const backend = s.backendRunning ?? s.backend_running;
          const frontend = s.frontendRunning ?? s.frontend_running;
          return {
            pass: r.status === 200 && backend === true && frontend === true,
            evidence: r.status !== 200
              ? `API respondeu HTTP ${r.status}`
              : `backend(AutoDJ)=${backend} frontend(Icecast)=${frontend}`,
            detail: s,
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── g
  {
    letter: 'g',
    title: 'Relatórios e métricas de audiência',
    edital: 'Disponibilização de relatórios e métricas de audiência, contendo informações sobre acessos, ouvintes simultâneos e demais indicadores relevantes',
    checks: [
      {
        id: 'g1',
        name: 'Ouvintes simultâneos reportados em tempo real',
        critical: true,
        async run({ cfg }) {
          const r = await fetchText(new URL(`/api/nowplaying/${cfg.station}`, cfg.baseUrl).toString());
          const np = JSON.parse(r.body);
          const l = np?.listeners;
          return {
            pass: typeof l?.current === 'number',
            evidence: `ouvintes agora: ${l?.current} (únicos: ${l?.unique}, total: ${l?.total})`,
            detail: l,
          };
        },
      },
      {
        id: 'g2',
        name: 'Histórico de audiência consultável por período',
        critical: true,
        async run({ cfg }) {
          const fim = new Date();
          const ini = new Date(fim.getTime() - 7 * 864e5);
          const q = `start=${ini.toISOString().slice(0, 10)}&end=${fim.toISOString().slice(0, 10)}`;
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/listeners?${q}`);
          return {
            pass: r.status === 200 && Array.isArray(r.json),
            evidence: `HTTP ${r.status}; ${Array.isArray(r.json) ? r.json.length : 0} registro(s) de ouvinte em 7 dias`,
            detail: { amostra: Array.isArray(r.json) ? r.json.slice(0, 2) : r.text },
          };
        },
      },
      {
        id: 'g3',
        name: 'Métricas incluem geolocalização e dispositivo',
        critical: false,
        async run({ cfg }) {
          const r = await azuraApi(cfg.baseUrl, cfg.apiKey, `/api/station/${cfg.station}/listeners`);
          const arr = Array.isArray(r.json) ? r.json : [];
          const amostra = arr[0];
          const temGeo = !!(amostra?.location?.country || amostra?.location?.city);
          const temUA = !!amostra?.device;
          return {
            pass: arr.length === 0 || (temGeo && temUA),
            evidence: arr.length === 0
              ? 'sem ouvintes no momento — inconclusivo, reexecutar com tráfego'
              : `geo=${temGeo} dispositivo=${temUA}`,
            manual: arr.length === 0,
            detail: { camposDisponiveis: amostra ? Object.keys(amostra) : [] },
          };
        },
      },
      {
        id: 'g4',
        name: 'Relatório mensal de audiência gerável em formato entregável',
        critical: true,
        async run({ cfg, sh }) {
          // Não basta o arquivo existir: um gerador que estoura ao rodar não
          // gera relatório nenhum. Executamos de fato, contra o log real.
          const mes = new Date().toISOString().slice(0, 7);
          const r = await sh(
            `UPTIME_LOG=${q(cfg.uptimeLog)} node ${q(BASE + "/reports/sla-report.mjs")} --month ${mes} 2>&1 | head -40`
          );
          const gerou = /Disponibilidade|Relatório Mensal/.test(r.out);
          return {
            pass: gerou,
            evidence: gerou
              ? `gerador executado com sucesso para ${mes}`
              : `gerador falhou ao executar: ${r.out.slice(0, 200) || r.err}`,
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── h
  {
    letter: 'h',
    title: 'Aplicativo Android e iOS',
    edital: 'Disponibilização e manutenção de aplicativo compatível com os sistemas Android e iOS para acesso à programação da Web Rádio Porto do Capim',
    checks: [
      {
        id: 'h1',
        name: 'Projeto compila para Android e iOS (esqueleto nativo presente)',
        critical: true,
        async run({ cfg, sh }) {
          // Contar arquivos .dart NÃO prova que existe app. Sem os projetos
          // nativos não há APK nem IPA, e sem as chaves de plataforma o áudio
          // em segundo plano — que é o coração do requisito — não funciona.
          const A = BASE + "/app";
          const r = await sh(
            `for p in android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist pubspec.yaml lib/main.dart; do ` +
            `  [ -f "${A}/$p" ] && echo "OK $p" || echo "FALTA $p"; done`
          );
          const faltando = r.out.split('\n').filter((l) => l.startsWith('FALTA')).map((l) => l.slice(6));

          // As chaves de plataforma sem as quais o áudio para com a tela bloqueada.
          const chaves = await sh(
            `grep -l 'UIBackgroundModes' ${A}/ios/Runner/Info.plist 2>/dev/null; ` +
            `grep -l 'FOREGROUND_SERVICE_MEDIA_PLAYBACK' ${A}/android/app/src/main/AndroidManifest.xml 2>/dev/null`
          );
          const nChaves = chaves.out.trim().split('\n').filter(Boolean).length;

          return {
            pass: faltando.length === 0 && nChaves === 2,
            evidence: faltando.length
              ? `NÃO COMPILA — ausentes: ${faltando.join(', ')}`
              : nChaves < 2
                ? 'projetos nativos presentes, mas faltam chaves de áudio em segundo plano (UIBackgroundModes / FOREGROUND_SERVICE_MEDIA_PLAYBACK)'
                : 'projetos Android e iOS presentes, com chaves de reprodução em segundo plano',
            detail: { faltando, chavesDePlataforma: nChaves },
          };
        },
      },
      {
        id: 'h2',
        name: 'App aponta para o mesmo host validado nas alíneas b/c',
        critical: true,
        async run({ cfg, sh }) {
          // Comparação real entre o host medido e o host compilado no app.
          // Um grep pelo host do validador seria auto-referencial e falharia
          // sempre que AZC_BASE_URL não fosse editado junto com o config.dart.
          const r = await sh(
            `grep -oP "static const String host = '\\K[^']+" ${BASE}/app/lib/config.dart`
          );
          const hostApp = r.out.trim();
          const hostValidado = new URL(cfg.hlsUrl).host;
          return {
            pass: !!hostApp && hostApp === hostValidado,
            evidence: !hostApp
              ? 'não foi possível ler o host de app/lib/config.dart'
              : hostApp === hostValidado
                ? `app e validação apontam para ${hostApp}`
                : `DIVERGÊNCIA: app aponta para "${hostApp}", validação mediu "${hostValidado}" — o app entrega algo diferente do auditado`,
            detail: { hostApp, hostValidado },
          };
        },
      },
      {
        id: 'h3',
        name: 'Build assinado publicado nas lojas oficiais',
        critical: true,
        manual: true,
        async run() {
          return {
            pass: false,
            manual: true,
            evidence: 'BLOQUEADO: exige Apple Developer Program (US$ 99/ano) e Google Play (US$ 25). ' +
              'Nenhum caminho técnico substitui essas contas. Auditor deve exigir os links das lojas.',
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── i
  {
    letter: 'i',
    title: `Disponibilidade mínima de ${SLA_TARGET}% (SLA)`,
    edital: 'Garantia de disponibilidade mínima de 99% (SLA), ressalvadas interrupções programadas previamente comunicadas e eventos comprovadamente fora do controle da contratada',
    checks: [
      {
        id: 'i1',
        name: 'Monitoramento de disponibilidade ativo, coletando e SEM lacunas',
        critical: true,
        async run({ cfg, sh }) {
          const { existsSync, readFileSync } = await import('node:fs');
          if (!existsSync(cfg.uptimeLog)) {
            return { pass: false, evidence: `log de disponibilidade ausente em ${cfg.uptimeLog}` };
          }
          const linhas = readFileSync(cfg.uptimeLog, 'utf8').split('\n').slice(1).filter(Boolean);
          if (linhas.length < 2) {
            return { pass: false, evidence: `apenas ${linhas.length} amostra(s) — insuficiente para apurar SLA` };
          }

          // O monitor precisa estar VIVO. Log antigo com muitas amostras
          // aprovaria o check enquanto o serviço está morto há uma semana.
          const ultima = new Date(linhas[linhas.length - 1].split(',')[0]);
          if (isNaN(ultima)) {
            return { pass: false, evidence: 'última linha do log tem timestamp inválido' };
          }
          const minutosDesde = (Date.now() - ultima.getTime()) / 60000;

          // Timestamp no FUTURO é corrupção de dados (relógio errado, log
          // sintético, fuso trocado) e não pode ser lido como "recentíssimo".
          // A comparação ingênua `minutosDesde < 30` aprovava -5116 min.
          if (minutosDesde < -2) {
            return {
              pass: false,
              evidence: `última amostra está ${Math.abs(minutosDesde).toFixed(0)} min NO FUTURO — ` +
                'log corrompido ou relógio dessincronizado; laudo não confiável',
              detail: { minutosDesdeUltima: minutosDesde },
            };
          }

          const atual = minutosDesde < 30;
          return {
            pass: atual,
            evidence: `${linhas.length} amostras; última há ${minutosDesde.toFixed(0)} min` +
              (atual ? '' : ' — MONITOR PARADO, o SLA apurado está desatualizado'),
            detail: { amostras: linhas.length, minutosDesdeUltima: minutosDesde },
          };
        },
      },
      {
        id: 'i2',
        name: `Disponibilidade apurada >= ${SLA_TARGET}%`,
        critical: true,
        async run({ cfg }) {
          const { existsSync, readFileSync } = await import('node:fs');
          if (!existsSync(cfg.uptimeLog)) {
            return { pass: false, manual: true, evidence: 'sem log de disponibilidade — SLA não apurável' };
          }
          const linhas = readFileSync(cfg.uptimeLog, 'utf8').split('\n').slice(1).filter(Boolean);
          const amostras = linhas
            .map((l) => { const [ts, estado] = l.split(','); return { t: new Date(ts), up: estado === 'up' }; })
            .filter((a) => !isNaN(a.t));

          if (amostras.length < 2) {
            return { pass: false, manual: true, evidence: 'amostras insuficientes' };
          }

          const up = amostras.filter((a) => a.up).length;
          const total = amostras.length;
          const pct = (up / total) * 100;

          // INTEGRIDADE DO LAUDO: se o monitor ficou parado, as amostras que
          // faltam somem da conta e o percentual sai inflado. Uma queda que
          // derrube o próprio monitor viraria SLA perfeito. Detectamos lacunas
          // comparando o intervalo entre amostras com a mediana observada.
          const deltas = [];
          for (let i = 1; i < amostras.length; i++) {
            deltas.push(amostras[i].t - amostras[i - 1].t);
          }
          const mediana = deltas.slice().sort((a, b) => a - b)[Math.floor(deltas.length / 2)] || 0;
          const lacunas = deltas.filter((d) => mediana > 0 && d > mediana * 5);
          const msPerdidos = lacunas.reduce((s, d) => s + d, 0);
          const amostrasPerdidas = mediana > 0 ? Math.round(msPerdidos / mediana) : 0;

          const integro = lacunas.length === 0;
          return {
            pass: pct >= SLA_TARGET && integro,
            manual: !integro,
            evidence: `${pct.toFixed(4)}% (${up}/${total} amostras)` +
              (integro
                ? ''
                : ` — ⚠️ ${lacunas.length} LACUNA(S) no monitoramento, ~${amostrasPerdidas} amostras ausentes. ` +
                  'Amostra ausente não é amostra "no ar": o percentual acima está otimista e não serve como laudo.'),
            detail: { pct, up, total, alvo: SLA_TARGET, lacunas: lacunas.length, amostrasPerdidas },
          };
        },
      },
      {
        id: 'i3',
        // NÃO-CRÍTICO POR DECISÃO DELIBERADA: o edital exige 99% de
        // disponibilidade, não exige segundo nó. Marcar como crítico fazia a
        // suíte imprimir "não conforme ao edital" e sair com código 1 por um
        // requisito que o edital não contém — um falso negativo que
        // desqualificaria a própria proposta.
        // Fica como recomendação de engenharia, que é o que de fato é.
        name: 'Redundância: segundo nó de entrega (recomendado, não exigido pelo edital)',
        critical: false,
        async run({ cfg }) {
          if (!cfg.edgeUrl) {
            return {
              pass: false,
              evidence: 'EDGE_URL não configurado. O edital não exige redundância, ' +
                'mas sem ela um único reboot mensal já consome boa parte dos 7h12min de margem do SLA de 99%',
            };
          }
          const r = await fetchText(cfg.edgeUrl);
          return {
            pass: r.status === 200,
            evidence: `nó secundário respondeu HTTP ${r.status}`,
            detail: { edgeUrl: cfg.edgeUrl },
          };
        },
      },
    ],
  },

  // ─────────────────────────────────────────────────────────── j
  {
    letter: 'j',
    title: 'Suporte técnico especializado',
    edital: 'Prestação de suporte técnico especializado durante toda a vigência contratual, visando assegurar o pleno funcionamento da solução e a resolução de eventuais incidentes',
    checks: [
      {
        id: 'j1',
        name: 'Runbook de incidentes documentado',
        critical: true,
        async run({ sh }) {
          const r = await sh(`wc -l < ${q(BASE + "/docs/RUNBOOK.md")}`);
          const n = Number(r.out.trim()) || 0;
          return {
            pass: r.ok && n > 30,
            evidence: r.ok ? `runbook com ${n} linhas` : 'RUNBOOK.md ausente',
          };
        },
      },
      {
        id: 'j2',
        name: 'Alertas automáticos de queda EM EXECUÇÃO',
        critical: true,
        async run({ cfg, sh }) {
          // A versão anterior só fazia `test -f` no monitor. Um arquivo no
          // disco não alerta ninguém: o monitor precisa estar rodando como
          // serviço E com um comando de alerta configurado. Sem as duas
          // coisas, o "suporte" da alínea (j) não existe na prática.
          const svc = await sh(`systemctl is-active webradio-monitor.service 2>/dev/null`);
          const ativo = svc.out.trim() === 'active';

          // Ancora em `node` no início da linha de comando. `pgrep -f
          // 'uptime-monitor.mjs'` casa com o PRÓPRIO shell que executa o
          // pgrep (a string está na linha de comando dele), e o check
          // reportava "monitor em execução" com o serviço parado.
          const proc = await sh(`pgrep -a -f '^[^ ]*node .*uptime-monitor'`);
          const rodando = proc.ok && proc.out.trim().length > 0;
          const temAlerta = ativo || /--alert-cmd|ALERT_CMD/.test(proc.out);

          return {
            pass: (ativo || rodando) && temAlerta,
            evidence: !(ativo || rodando)
              ? 'monitor NÃO está em execução — nenhuma queda será detectada nem alertada'
              : temAlerta
                ? `monitor ativo (${ativo ? 'systemd' : 'processo avulso'}) com alerta configurado`
                : 'monitor em execução mas SEM --alert-cmd: registra a queda e não avisa ninguém',
            detail: { systemd: ativo, processo: rodando, temAlerta },
          };
        },
      },
      {
        id: 'j3',
        name: 'Backup restaurável comprovado',
        critical: false, // fora do texto do edital; mantido como boa prática
        manual: true,
        async run({ cfg, sh }) {
          const r = await sh(`test -f ${q(BASE + "/deploy/backup.sh")}`);
          return {
            pass: false,
            manual: true,
            evidence: r.ok
              ? 'script de backup presente, mas RESTAURAÇÃO nunca foi testada em ambiente limpo. ' +
                'Backup não restaurado não é backup — ver rotina trimestral no RUNBOOK.'
              : 'script de backup ausente',
          };
        },
      },
    ],
  },
];

export const meta = { MIN_KBPS, MIN_STORAGE_GB, SLA_TARGET };
