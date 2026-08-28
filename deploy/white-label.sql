-- White-label da plataforma de rádio (1bit)
--
-- Aplicar:
--   docker exec -i azuracast mariadb -u azuracast -p"$SENHA" azuracast < deploy/white-label.sql
--   docker exec azuracast azuracast_cli cache:clear
--
-- POR QUE VIA CSS E NÃO EDITANDO O PHP:
-- O aviso de doação vem de backend/src/Notification/Check/DonateAdvisorCheck.php,
-- que não tem opção de desligar (só um rate-limit de 600s). Editar o PHP
-- funcionaria até a próxima atualização do AzuraCast sobrescrever o arquivo.
-- O campo `internal_custom_css` é injetado em backend/templates/panel.phtml
-- (linha 34) e sobrevive a atualizações.
--
-- O seletor usa o id definido no próprio DonateAdvisorCheck
-- (`id: 'notification-donation'`), que o Dashboard.vue renderiza em `:id`.
-- Verificado autenticando no painel e conferindo o HTML servido.
--
-- NOTA: a AGPL não obriga a exibir apelo de doação, então ocultar é
-- legítimo num produto white-label. Como a plataforma inteira é construída
-- sobre trabalho não remunerado de terceiros, vale considerar apoiar o
-- projeto por fora: https://www.azuracast.com/docs/help/donate/

UPDATE settings SET
  internal_custom_css = CONCAT(
    '/* 1bit — white-label. Oculta o aviso de doação do AzuraCast no painel\n',
    '   dos clientes. Ver deploy/white-label.sql para o porquê. */\n',
    '#notification-donation { display: none !important; }\n'
  ),
  -- Nome da instância, exibido no título das páginas do painel.
  instance_name = 'Rádio 1bit',
  -- Oculta "AzuraCast" no rodapé e no título das páginas públicas.
  hide_product_name = 1;

SELECT
  instance_name                       AS instancia,
  hide_product_name                   AS oculta_nome_produto,
  LENGTH(internal_custom_css)         AS bytes_css
FROM settings;

-- ── Idioma do painel ─────────────────────────────────────────────────────
-- A ordem de resolução do AzuraCast é:
--   1. locale do PERFIL do usuário
--   2. Accept-Language do NAVEGADOR
--   3. variável de ambiente LANG
-- Com o perfil NULL, quem decide é o navegador do cliente: um Chrome em
-- inglês mostra o painel inteiro em inglês, por mais que LANG=pt_BR.UTF-8
-- esteja no servidor. A tradução pt_BR do AzuraCast é 99,95% completa
-- (2081 strings, 1 sem tradução), então só faltava selecioná-la.
UPDATE users SET locale = 'pt_BR.UTF-8'
  WHERE locale IS NULL OR locale = 'default' OR locale = '';

SELECT id, email, locale FROM users;
