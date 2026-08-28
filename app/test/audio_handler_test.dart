// Trava a regressão que custou dois builds e não aparece em `flutter analyze`.
//
// O just_audio documenta que o Future de `play()` "completa quando a
// reprodução termina, é pausada ou parada". Numa rádio ao vivo isso nunca
// acontece: `await _player.play()` fica pendurado para sempre e leva junto
// tudo que o aguarda — a troca de emissora, a abertura do app, a seleção.
//
// O sintoma não é um erro, é ausência: telas que não avançam. Um teste de
// comportamento exigiria plataforma nativa, então verificamos o código.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final fonte = File('lib/audio_handler.dart').readAsStringSync();

  test('o Future de play() nunca é aguardado', () {
    final linhas = fonte.split('\n');
    final ofensas = <String>[];
    for (var i = 0; i < linhas.length; i++) {
      final l = linhas[i];
      if (l.trimLeft().startsWith('//')) continue;   // comentários explicam o porquê
      if (RegExp(r'await\s+_player\s*\.\s*play\s*\(').hasMatch(l)) {
        ofensas.add('linha ${i + 1}: ${l.trim()}');
      }
    }
    expect(ofensas, isEmpty,
        reason: 'await em _player.play() trava o app: o Future só completa '
            'quando a reprodução termina, e uma rádio ao vivo não termina. '
            'Use unawaited(_player.play()).');
  });

  test('carregar a fonte tem limite de tempo', () {
    // setAudioSource também não lança quando o stream está inacessível — só
    // não completa. Sem timeout, o fallback para MP3 nunca chega a rodar.
    expect(fonte.contains('.timeout(_limiteCarga)'), isTrue,
        reason: 'setAudioSource precisa de timeout, senão o fallback é morto');
  });
}
