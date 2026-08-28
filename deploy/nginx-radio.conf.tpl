# nginx — Web Rádio (RHEL/Oracle Linux, sem painel de controle)
#
# Instalado como /etc/nginx/conf.d/__DOMINIO__.conf
# O certbot acrescenta o bloco SSL e o redirecionamento ao rodar --nginx.
#
# LIÇÕES JÁ PAGAS, não desfazer:
#
# 1. /listen/ vai para o AzuraCast (8081), NUNCA direto para o Icecast (8005).
#    O mount no Icecast chama-se apenas /radio.mp3, sem prefixo de estação.
#    Apontar para lá dá 404 no endpoint público com a rádio tocando por dentro.
#
# 2. NÃO adicionar Access-Control-Allow-Origin aqui. O nginx interno do
#    AzuraCast já envia esse cabeçalho; somar o nosso produz "*, *", valor
#    inválido que o navegador rejeita e que quebra o player embutido.
#
# 3. proxy_buffering off em /listen/ é obrigatório. Um stream infinito
#    bufferizado por proxy acumula atraso e estoura o buffer do player.

server {
    listen      80;
    listen      [::]:80;

    # NOME EXATO, NUNCA CURINGA. Aprendido quebrando:
    #
    # Com `server_name radio.1bit.net.br *.radio.1bit.net.br`, ao emitir o
    # certificado do primeiro cliente o certbot encontrou ESTE bloco como o
    # melhor match para `radiodemo.radio.1bit.net.br` (o curinga casa) e
    # reescreveu o ssl_certificate do domínio PRINCIPAL apontando para o
    # certificado do cliente. O painel passou a servir o certificado errado.
    #
    # Cada cliente ganha seu próprio arquivo em conf.d/ com nome exato, e o
    # certbot edita sempre o arquivo certo. O multi-cliente continua nativo:
    # o AzuraCast monta os links pelo Host recebido (prefer_browser_url=1).
    server_name __DOMINIO__;

    # Upload de acervo: um álbum em WAV passa de 500 MB com facilidade.
    client_max_body_size 2048m;

    access_log /var/log/nginx/__DOMINIO__.access.log;
    error_log  /var/log/nginx/__DOMINIO__.error.log;

    # ── Stream contínuo (MP3/AAC) ─────────────────────────────────────
    location /listen/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;

        proxy_buffering off;
        proxy_request_buffering off;

        # Ouvinte fica horas conectado; o padrão de 60s cortaria a cada minuto.
        proxy_read_timeout 24h;
        proxy_send_timeout 24h;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # ── HLS — é o que sustenta "ouvintes ilimitados" ──────────────────
    location /hls/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # O manifesto muda a cada segmento; cachear congelaria a rádio no
        # passado. Os segmentos, ao contrário, são imutáveis — e é isso que
        # permite a um CDN absorver a escala.
        location ~ \.m3u8$ {
            proxy_pass http://127.0.0.1:8081;
            add_header Cache-Control 'no-cache, no-store, must-revalidate' always;
        }
        location ~ \.(aac|ts|mp4|m4s)$ {
            proxy_pass http://127.0.0.1:8081;
            add_header Cache-Control 'public, max-age=31536000, immutable' always;
        }
    }

    # ── Painel administrativo e API ───────────────────────────────────
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;

        # IDIOMA — força português independentemente do navegador do visitante.
        #
        # O AzuraCast resolve o idioma nesta ordem
        # (Enums/SupportedLocales::createFromRequest):
        #   1. locale do perfil do usuário  (só existe se estiver logado)
        #   2. Accept-Language do NAVEGADOR
        #   3. variável LANG do servidor
        #
        # A PÁGINA PÚBLICA não tem usuário logado, então quem decidia era o
        # navegador do ouvinte: visitante com Chrome em inglês recebia o
        # player em inglês, numa rádio brasileira. Reescrevendo o cabeçalho
        # aqui, a etapa 2 sempre devolve pt_BR.
        #
        # Não atrapalha o painel: o locale do perfil (etapa 1) tem prioridade,
        # então um cliente que queira outro idioma ainda pode escolher.
        proxy_set_header Accept-Language "pt-BR,pt;q=0.9";

        # WebSocket do "tocando agora". Connection fixo em "upgrade" quebraria
        # keep-alive nas requisições normais; repassando $http_upgrade o
        # cabeçalho some quando vazio.
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $http_upgrade;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 3600s;
    }
}
