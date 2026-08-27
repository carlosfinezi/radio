# Template nginx HTTP do HestiaCP — Web Rádio.
# Instalar em: /usr/local/hestia/data/templates/web/nginx/php-fpm/webradio.tpl
#
# ESTE ARQUIVO EXISTE POR CAUSA DE UM BUG ESPECÍFICO.
# A versão anterior gerava o template HTTP com um `sed` sobre o template SSL,
# o que preservava o `include ... nginx.ssl.conf_*`. O Hestia grava o desafio
# do Let's Encrypt em `nginx.conf_letsencrypt` — fragmento `nginx.conf_*`, sem
# o `.ssl`. Com o glob errado, o bloco do ACME nunca entrava no vhost HTTP e o
# `/.well-known/acme-challenge/` caía no `location /`, indo parar no AzuraCast,
# que respondia 404. O certificado NUNCA era emitido, e o `|| warn` do
# instalador escondia a falha.

server {
    listen      %ip%:%web_port%;
    server_name %domain_idn% %alias_idn%;

    client_max_body_size 2048m;

    # ── Desafio ACME ────────────────────────────────────────────────────
    # PRECISA vir antes de qualquer proxy_pass, senão o Let's Encrypt falha.
    location ~ "^/\.well-known/acme-challenge/(.*)$" {
        default_type text/plain;
        root %docroot%;
    }

    # ── Redireciona o resto para HTTPS ──────────────────────────────────
    # O stream é consumido por app móvel e por navegador: HTTP puro seria
    # bloqueado por mixed-content e pelo ATS da Apple.
    location / {
        return 301 https://$host$request_uri;
    }

    include %home%/%user%/conf/web/%domain%/nginx.conf_*;
}
