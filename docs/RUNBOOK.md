# Runbook Operacional — Web Rádio Porto do Capim

Documento de plantão. Atende à alínea (j) do edital (suporte técnico) e é a
referência para quem atender um incidente às 3h da manhã.

**Endpoints**

| O quê | URL |
|---|---|
| Painel administrativo | `https://radio.liciteagora.app` |
| Stream MP3 (ICY) | `https://radio.liciteagora.app/listen/porto_do_capim/radio.mp3` |
| Stream HLS | `https://radio.liciteagora.app/hls/porto_do_capim/live.m3u8` |
| Tocando agora (público) | `https://radio.liciteagora.app/api/nowplaying/porto_do_capim` |

**Onde as coisas moram**

| O quê | Caminho |
|---|---|
| Stack do AzuraCast | `/var/azuracast` |
| Mídia do Auto DJ | `/var/azuracast/stations/porto_do_capim/media` |
| Log de disponibilidade | `/var/log/webradio/uptime.csv` |
| Vhost do site | `/home/carlosfinezi/conf/web/radio.liciteagora.app/` |
| Suíte de conformidade | `/root/webradio/validation` |

---

## Diagnóstico em 60 segundos

```bash
cd /var/azuracast && docker compose ps        # contêineres de pé?
curl -sI https://radio.liciteagora.app/listen/porto_do_capim/radio.mp3 | head -3
cd /root/webradio && node validation/run.mjs --only a,b   # o áudio flui a 128k?
tail -20 /var/log/webradio/uptime.csv          # desde quando caiu?
```

---

## Incidente 1 — Rádio fora do ar (ouvinte não conecta)

**Sintoma:** player não toca; `curl` no stream falha ou devolve 5xx.

1. **O contêiner está de pé?**
   ```bash
   cd /var/azuracast && docker compose ps
   docker compose logs --tail=100 stations
   ```
   Se caiu: `docker compose up -d`

2. **O nginx do Hestia está roteando?**
   ```bash
   curl -sI http://127.0.0.1:8005/porto_do_capim/radio.mp3 | head -3
   ```
   - Responde no localhost mas não no domínio → problema no vhost.
     `v-rebuild-web-domain carlosfinezi radio.liciteagora.app`
   - Não responde nem no localhost → problema no Icecast/Liquidsoap (passo 3).

3. **O Liquidsoap está no ar?**
   ```bash
   docker compose logs --tail=200 stations | grep -iE 'liquidsoap|error|fail'
   ```
   Reiniciar só a estação, pelo painel: **Estação → Reiniciar**.

⚠️ **Nunca** rode `docker compose down -v`. O `-v` apaga os volumes, e com eles
os 50 GB de mídia e o banco de audiência inteiro.

---

## Incidente 2 — Áudio no ar, mas mudo ou picotado

1. Meça o que está sendo entregue de verdade:
   ```bash
   cd /root/webradio && node validation/run.mjs --only b
   ```
2. **Muito abaixo de 128 kbps** → o encoder está sofrendo. Ver CPU:
   `docker stats --no-stream`
3. **Stream responde 200 com pouquíssimos bytes** → a fonte morreu e o
   fallback não assumiu. Verifique se a playlist de emergência tem arquivos:
   ```bash
   ls -la /var/azuracast/stations/porto_do_capim/media/
   ```

---

## Incidente 3 — Painel inacessível, mas a rádio toca

O áudio é servido pelo contêiner `stations`; o painel, pelo `web`. Um cai sem
o outro. Isso é comportamento esperado e **não** conta como indisponibilidade
para o SLA — a alínea (i) mede o serviço de streaming.

```bash
docker compose restart web
```

---

## Incidente 4 — Disco cheio

Este host já teve backup falhando por falta de espaço. Verifique primeiro:

```bash
df -h /
du -sh /var/azuracast/stations/*/media | sort -h | tail
docker system df
```

Limpeza segura (não toca em mídia nem em banco):
```bash
docker image prune -af
docker builder prune -af
```

---

## Rotinas periódicas

| Quando | O quê |
|---|---|
| Contínuo | `uptime-monitor.mjs` rodando (systemd) |
| Diário | `deploy/backup.sh` |
| Mensal (dia 1) | `node reports/sla-report.mjs --month AAAA-MM --out laudo.md` |
| Mensal | `node validation/run.mjs --md laudo-conformidade.md` |
| **Trimestral** | **Restaurar um backup em máquina limpa.** Backup não testado não é backup. |

---

## Escalonamento

| Nível | Quando | Ação |
|---|---|---|
| 1 | Queda < 15 min | Plantão aplica este runbook |
| 2 | Queda > 15 min ou reincidente | Acionar responsável técnico |
| 3 | Perda de dados / mídia | Parar, **não improvisar**, restaurar do backup |

**Margem de SLA:** 99% em 30 dias = **7h12min** de indisponibilidade por mês.
Uma única queda de 3 horas já consome 42% da margem mensal.
