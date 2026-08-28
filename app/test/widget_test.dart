// Testes do BitRádio.
//
// Não tocam áudio: o AudioService exige plataforma nativa e não roda em
// ambiente de teste. Verificam o que dá para verificar sem aparelho — que a
// configuração da plataforma é coerente e que o modelo de emissora lê a API
// corretamente.

import 'package:flutter_test/flutter_test.dart';
import 'package:bitradio/config.dart';
import 'package:bitradio/emissora.dart';

void main() {
  group('Config da plataforma', () {
    test('URLs usam HTTPS', () {
      // Sem HTTPS o ATS da Apple bloqueia e o app é rejeitado na revisão.
      for (final url in [Config.baseUrl, Config.stationsApi, Config.politicaPrivacidade]) {
        expect(url, startsWith('https://'), reason: '$url precisa ser HTTPS');
      }
    });

    test('não há emissora fixa na configuração', () {
      // A primeira versão do app tinha o slug cravado aqui, o que amarrava
      // o aplicativo a um único cliente. Este teste impede a regressão.
      expect(Config.baseUrl.contains('porto_do_capim'), isFalse);
      expect(Config.stationsApi.contains('porto_do_capim'), isFalse);
    });

    test('poll de metadados não sobrecarrega o servidor', () {
      // Um poll por segundo vindo de cada aparelho instalado derrubaria a
      // API — e o número multiplica pelo total de clientes.
      expect(Config.nowPlayingInterval.inSeconds, greaterThanOrEqualTo(10));
    });
  });

  group('Emissora', () {
    final json = {
      'id': 1,
      'shortcode': 'porto_do_capim',
      'name': 'Web Rádio Porto do Capim',
      'description': 'UFPB',
      'listen_url': 'https://radio.1bit.net.br/listen/porto_do_capim/radio.mp3',
      'hls_url': 'https://radio.1bit.net.br/hls/porto_do_capim/live.m3u8',
      'hls_enabled': true,
    };

    test('lê o JSON da API', () {
      final e = Emissora.doJson(json);
      expect(e.slug, 'porto_do_capim');
      expect(e.nome, 'Web Rádio Porto do Capim');
      expect(e.urlHls, isNotNull);
    });

    test('prefere HLS quando disponível', () {
      // HLS sobrevive a troca de rede e funciona nativamente no iOS.
      expect(Emissora.doJson(json).urlPreferida, contains('.m3u8'));
    });

    test('cai para o stream contínuo quando o HLS está desligado', () {
      final semHls = Map<String, dynamic>.from(json)
        ..['hls_enabled'] = false
        ..['hls_url'] = null;
      final e = Emissora.doJson(semHls);
      expect(e.urlHls, isNull);
      expect(e.urlPreferida, contains('radio.mp3'));
    });

    test('monta os endpoints a partir do slug', () {
      final e = Emissora.doJson(json);
      expect(e.urlNowPlaying, contains('/api/nowplaying/porto_do_capim'));
      expect(e.urlProgramacao, contains('/api/station/porto_do_capim/schedule'));
    });

    test('sobrevive a ida e volta pelo JSON salvo no aparelho', () {
      // A emissora é guardada inteira em disco para o app abrir sem rede.
      final original = Emissora.doJson(json);
      final voltou = Emissora.doJson(original.paraJson());
      expect(voltou.slug, original.slug);
      expect(voltou.urlPreferida, original.urlPreferida);
    });
  });
}
