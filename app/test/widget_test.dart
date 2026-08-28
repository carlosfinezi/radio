// Testes do app da Web Rádio.
//
// O teste gerado pelo `flutter create` referenciava `MyApp`, classe que não
// existe aqui (a nossa é `RadioApp`), e por isso a análise falhava.
//
// Estes testes NÃO tocam áudio: o AudioService exige plataforma nativa e não
// roda em ambiente de teste. Verificam o que dá para verificar sem device —
// que a configuração aponta para o servidor certo e é coerente entre si.

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_porto_do_capim/config.dart';

void main() {
  group('Config', () {
    test('todas as URLs usam HTTPS', () {
      // Sem HTTPS o ATS da Apple bloqueia e o app é rejeitado na revisão.
      for (final url in [
        Config.streamHls,
        Config.streamIcy,
        Config.nowPlayingApi,
        Config.playerWebUrl,
      ]) {
        expect(url, startsWith('https://'), reason: '$url precisa ser HTTPS');
      }
    });

    test('todas as URLs apontam para o mesmo host', () {
      // Divergência aqui significa o app entregando algo diferente do que
      // foi medido pela suíte de conformidade do edital.
      for (final url in [Config.streamHls, Config.streamIcy, Config.nowPlayingApi]) {
        expect(Uri.parse(url).host, equals(Config.host));
      }
    });

    test('o slug da estação aparece nas URLs de stream', () {
      expect(Config.streamHls, contains(Config.stationSlug));
      expect(Config.streamIcy, contains(Config.stationSlug));
    });

    test('intervalo de metadados não sobrecarrega o servidor', () {
      // Um poll por segundo vindo de cada aparelho instalado derrubaria a API.
      expect(Config.nowPlayingInterval.inSeconds, greaterThanOrEqualTo(10));
    });
  });
}
