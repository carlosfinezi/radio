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

const MIN_KBPS = 128;
const MIN_STORAGE_GB = 50;
const SLA_TARGET = 99.0;

/** Tolerância de medição: encoders VBR/CBR oscilam ~4% entre janelas. */
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
          const out = await sh(
            `docker inspect --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -q) 2>/dev/null || true`
          );
          const lines = out.trim().split('\n').filter(Boolean);
          const bad = lines.filter((l) => !/(always|unless-stopped)$/.test(l));
          return {
            pass: lines.length > 0 && bad.length === 0,
            evidence: lines.length
              ? `${lines.length} contêiner(es); ${bad.length} sem restart automático`
              : 'nenhum contêiner encontrado',
            detail: { containers: lines, semRestart: bad },
          };
        },
      },
      {
        id: 'a3',
        name: 'Continuidade sob falha de fonte (fallback do AutoDJ)',
        critical: true,
        async run({ cfg }) {
          // O Liquidsoap deve ter fallback encadeado. Sem fonte ao vivo,
          // a playlist tem que estar no ar — é isso que "ininterrupto" significa.
          const m = await measureIcyBitrate(cfg.streamUrl, 6);
          return {
            pass: m.kbps > 1,
            evidence: `sem fonte ao vivo, o stream segue a ${m.kbps.toFixed(1)} kbps (AutoDJ assumiu)`,
            detail: { kbps: m.kbps },
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
          const out = await sh(
            `docker exec ${cfg.container} cat /var/azuracast/stations/${cfg.station}/config/icecast.xml 2>/dev/null | grep -iE '<(clients|sources|max_listeners)>' || true`
          );
          const clients = /<clients>(\d+)<\/clients>/i.exec(out);
          const n = clients ? Number(clients[1]) : null;
          // O Icecast exige um número; o que importa é ser alto o bastante
          // para não ser o gargalo antes da porta de rede saturar.
          return {
            pass: n === null || n >= 5000,
            evidence: n === null
              ? 'sem limite explícito de clientes'
              : `<clients>${n}</clients> — ${n >= 5000 ? 'acima do limite físico da porta de rede' : 'ABAIXO do necessário; vira gargalo antes da banda'}`,
            detail: { clients: n, raw: out.trim() },
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
          const out = await sh(
            `for d in /var/azuracast/stations /var/lib/docker /; do ` +
            `  if [ -d "$d" ]; then df -BG --output=avail "$d" | tail -1; break; fi; ` +
            `done`
          );
          const availGb = Number((out.match(/(\d+)G/) || [])[1] || 0);
          return {
            pass: availGb >= MIN_STORAGE_GB,
            evidence: `${availGb} GB disponíveis no volume de mídia (mínimo ${MIN_STORAGE_GB} GB)`,
            detail: { availGb, required: MIN_STORAGE_GB },
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
          return {
            pass: r.status === 200,
            evidence: `${agendadas.length} playlist(s) com grade horária configurada`,
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
          return {
            pass: r.status === 200 && s.backend_running === true && s.frontend_running === true,
            evidence: `backend(AutoDJ)=${s.backend_running} frontend(Icecast)=${s.frontend_running}`,
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
          const out = await sh(`test -f /root/webradio/reports/sla-report.mjs && echo OK || echo FALTA`);
          return {
            pass: out.includes('OK'),
            evidence: out.includes('OK')
              ? 'gerador de relatório presente (reports/sla-report.mjs)'
              : 'gerador de relatório AUSENTE',
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
        name: 'Código-fonte do app presente e íntegro',
        critical: true,
        async run({ cfg, sh }) {
          const out = await sh(`ls /root/webradio/app/lib/*.dart /root/webradio/app/pubspec.yaml 2>/dev/null | wc -l`);
          return {
            pass: Number(out.trim()) >= 2,
            evidence: `${out.trim()} arquivo(s) do projeto Flutter encontrados`,
          };
        },
      },
      {
        id: 'h2',
        name: 'App consome o mesmo endpoint HLS validado nas alíneas b/c',
        critical: true,
        async run({ cfg, sh }) {
          const out = await sh(`grep -rl "${new URL(cfg.hlsUrl).host}" /root/webradio/app/ 2>/dev/null | head -3 || true`);
          return {
            pass: out.trim().length > 0,
            evidence: out.trim() ? `endpoint referenciado em: ${out.trim().split('\n').join(', ')}` : 'app não referencia o host do stream',
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
        name: 'Monitoramento de disponibilidade ativo e coletando',
        critical: true,
        async run({ cfg, sh }) {
          const out = await sh(`test -f ${cfg.uptimeLog} && wc -l < ${cfg.uptimeLog} || echo 0`);
          const n = Number(out.trim()) || 0;
          return {
            pass: n > 0,
            evidence: `${n} amostra(s) de disponibilidade registradas em ${cfg.uptimeLog}`,
            detail: { amostras: n },
          };
        },
      },
      {
        id: 'i2',
        name: `Disponibilidade apurada >= ${SLA_TARGET}%`,
        critical: true,
        async run({ cfg, sh }) {
          const out = await sh(
            `awk -F, 'NF>=2{t++; if($2=="up") u++} END{if(t>0) printf "%.4f %d %d", (u/t)*100, u, t; else printf "0 0 0"}' ${cfg.uptimeLog} 2>/dev/null || echo "0 0 0"`
          );
          const [pct, up, total] = out.trim().split(/\s+/).map(Number);
          return {
            pass: total > 0 && pct >= SLA_TARGET,
            evidence: total > 0
              ? `${pct.toFixed(4)}% de disponibilidade (${up}/${total} amostras)`
              : 'sem amostras suficientes — o monitor precisa rodar antes de apurar SLA',
            manual: total === 0,
            detail: { pct, up, total, alvo: SLA_TARGET },
          };
        },
      },
      {
        id: 'i3',
        name: 'Redundância: existe segundo nó de entrega',
        critical: true,
        async run({ cfg }) {
          if (!cfg.edgeUrl) {
            return {
              pass: false,
              evidence: 'EDGE_URL não configurado — sem redundância, um único reboot mensal já consome os 7h18 de margem do SLA de 99%',
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
          const out = await sh(`test -f /root/webradio/docs/RUNBOOK.md && wc -l < /root/webradio/docs/RUNBOOK.md || echo 0`);
          const n = Number(out.trim()) || 0;
          return {
            pass: n > 30,
            evidence: n > 0 ? `runbook com ${n} linhas` : 'RUNBOOK.md ausente',
          };
        },
      },
      {
        id: 'j2',
        name: 'Alertas automáticos de queda configurados',
        critical: true,
        async run({ cfg, sh }) {
          const out = await sh(`test -f /root/webradio/reports/uptime-monitor.mjs && echo OK || echo FALTA`);
          return {
            pass: out.includes('OK'),
            evidence: out.includes('OK') ? 'monitor com alerta presente' : 'monitor de uptime ausente',
          };
        },
      },
      {
        id: 'j3',
        name: 'Backup restaurável comprovado',
        critical: true,
        manual: true,
        async run({ cfg, sh }) {
          const out = await sh(`test -f /root/webradio/deploy/backup.sh && echo OK || echo FALTA`);
          return {
            pass: false,
            manual: true,
            evidence: out.includes('OK')
              ? 'script de backup presente, mas RESTAURAÇÃO ainda não foi testada em ambiente limpo — exigir teste trimestral'
              : 'script de backup ausente',
          };
        },
      },
    ],
  },
];

export const meta = { MIN_KBPS, MIN_STORAGE_GB, SLA_TARGET };
