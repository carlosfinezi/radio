-- Grade de programação — Web Rádio Porto do Capim
--
-- POR QUE ESTE ARQUIVO EXISTE:
-- A grade vive no banco do AzuraCast, não em configuração versionada. Sem um
-- script como este, perder o banco significa perder a programação inteira, e
-- não há como auditar quando/por que um horário mudou. Este arquivo é a
-- fonte da verdade; o banco é a aplicação dela.
--
-- Aplicar:
--   docker exec -i azuracast mariadb -u azuracast -p"$SENHA" azuracast \
--     < deploy/grade-programacao.sql
--   docker exec azuracast azuracast_cli cache:clear
--   docker exec azuracast azuracast_cli azuracast:radio:restart porto_do_capim
--
-- ─────────────────────────────────────────────────────────────────────────
-- DUAS ARMADILHAS DO AZURACAST, aprendidas quebrando:
--
-- 1. NÃO existe tipo 'scheduled'. O enum PlaylistTypes aceita apenas
--    default | once_per_x_songs | once_per_x_minutes | once_per_hour | custom.
--    O agendamento é ORTOGONAL ao tipo: uma playlist vira "programada" ao
--    ganhar linhas em station_schedules. Gravar 'scheduled' faz o endpoint
--    /api/station/{id}/schedule estourar com erro de enum no Doctrine.
--
-- 2. `days` é ISO-8601: 1=segunda ... 7=domingo. E `start_time`/`end_time`
--    são inteiros HHMM (600 = 06:00, 1830 = 18:30), no FUSO DA ESTAÇÃO.
-- ─────────────────────────────────────────────────────────────────────────

SET @station := (SELECT id FROM station WHERE short_name = 'porto_do_capim');

-- Limpa a grade anterior (idempotência): remove agendamentos e as playlists
-- de programa, preservando a rotação geral e a mídia já indexada.
DELETE s FROM station_schedules s
  JOIN station_playlists p ON p.id = s.playlist_id
  WHERE p.station_id = @station AND p.name <> 'Programação Musical';
DELETE FROM station_playlists
  WHERE station_id = @station AND name <> 'Programação Musical' AND name <> 'default';

-- ── Rede de segurança ────────────────────────────────────────────────────
-- Sem esta playlist a rádio fica MUDA nos intervalos entre programas
-- (09-12, 13-18, 20-06 nos dias úteis). Ela não tem agendamento de
-- propósito: é o que o AutoDJ toca quando nenhum programa está no ar.
INSERT INTO station_playlists
  (station_id,name,description,type,is_enabled,play_per_songs,play_per_minutes,
   weight,source,include_in_requests,playback_order,is_jingle,
   play_per_hour_minute,remote_timeout,include_in_on_demand,avoid_duplicates)
SELECT @station,'Programação Musical',
       'Rotação geral. Preenche todo horário sem programa agendado — é o que impede silêncio no ar.',
       'default',1,0,0,3,'songs',1,'shuffle',0,0,0,1,0
WHERE NOT EXISTS (
  SELECT 1 FROM (SELECT * FROM station_playlists) x
  WHERE x.station_id = @station AND x.name = 'Programação Musical'
);

-- ── Programas ────────────────────────────────────────────────────────────
-- weight 5 > 3 da rotação geral: dentro da janela, o programa prevalece.
INSERT INTO station_playlists
  (station_id,name,description,type,is_enabled,play_per_songs,play_per_minutes,
   weight,source,include_in_requests,playback_order,is_jingle,
   play_per_hour_minute,remote_timeout,include_in_on_demand,avoid_duplicates)
VALUES
  (@station,'Bom Dia, Porto do Capim','Jornada matinal: informação local, agenda da UFPB e música.','default',1,0,0,5,'songs',1,'shuffle',0,0,0,1,0),
  (@station,'Universidade Aberta','Faixa institucional: pesquisa, extensão e serviços da UFPB.','default',1,0,0,5,'songs',1,'shuffle',0,0,0,1,0),
  (@station,'Sons do Sanhauá','Música paraibana e nordestina no fim de tarde.','default',1,0,0,5,'songs',1,'shuffle',0,0,0,1,0),
  (@station,'Memória e Território','História e cultura da comunidade do Porto do Capim.','default',1,0,0,5,'songs',1,'shuffle',0,0,0,1,0),
  (@station,'Domingo de Choro','Choro, forró tradicional e regional brasileiro.','default',1,0,0,5,'songs',1,'shuffle',0,0,0,1,0);

-- ── Horários ─────────────────────────────────────────────────────────────
INSERT INTO station_schedules (playlist_id,start_time,end_time,days,loop_once,prevent_requests)
SELECT p.id, h.ini, h.fim, h.dias, 0, 0
FROM station_playlists p
JOIN (
  SELECT 'Bom Dia, Porto do Capim' AS nome,  600 AS ini,  900 AS fim, '1,2,3,4,5' AS dias
  UNION ALL SELECT 'Universidade Aberta',   1200, 1300, '1,2,3,4,5'
  UNION ALL SELECT 'Sons do Sanhauá',       1800, 2000, '1,2,3,4,5'
  UNION ALL SELECT 'Memória e Território',  1000, 1200, '6'
  UNION ALL SELECT 'Domingo de Choro',      1000, 1200, '7'
) h ON h.nome = p.name
WHERE p.station_id = @station;

-- ── Vincula a mídia disponível a todos os programas ──────────────────────
-- PROVISÓRIO: hoje todos compartilham o mesmo acervo. Ao subir o conteúdo
-- real, atribua as faixas de cada programa pelo painel (Mídia → selecionar
-- → adicionar à playlist) e remova este bloco.
INSERT INTO station_playlist_media (playlist_id,media_id,weight,last_played,is_queued)
SELECT p.id, m.id, ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY m.id), 0, 1
FROM station_playlists p
CROSS JOIN station_media m
WHERE p.station_id = @station AND p.is_enabled = 1
  AND NOT EXISTS (
    SELECT 1 FROM (SELECT * FROM station_playlist_media) pm
    WHERE pm.playlist_id = p.id AND pm.media_id = m.id
  );

-- Desabilita a playlist vazia que o AzuraCast cria sozinho ao criar a estação.
UPDATE station_playlists SET is_enabled = 0
  WHERE station_id = @station AND name = 'default';

SELECT p.name AS programa,
       CONCAT(LPAD(FLOOR(s.start_time/100),2,'0'),':',LPAD(s.start_time%100,2,'0')) AS inicio,
       CONCAT(LPAD(FLOOR(s.end_time/100),2,'0'),':',LPAD(s.end_time%100,2,'0'))     AS fim,
       s.days AS dias_iso
FROM station_playlists p
LEFT JOIN station_schedules s ON s.playlist_id = p.id
WHERE p.station_id = @station AND p.is_enabled = 1
ORDER BY s.days, s.start_time;
