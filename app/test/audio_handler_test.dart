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

  test('a fonte é preparada sem aguardar pré-carregamento', () {
    // O Future de setAudioSource com preload só completa quando a mídia tem
    // duração conhecida. Uma rádio ao vivo não tem: aguardar ali prende a
    // troca de emissora por tempo indefinido.
    expect(fonte.contains('preload: false'), isTrue,
        reason: 'setAudioSource em stream ao vivo exige preload: false');
    expect(RegExp(r'setAudioSource\([^)]*\)\s*\.timeout').hasMatch(fonte), isFalse,
        reason: 'timeout no setAudioSource troca travamento por falha certa');
  });

  test('playbackState recebe eventos por listen, nunca por pipe', () {
    // pipe() equivale a addStream, e enquanto um addStream está ativo o
    // BehaviorSubject rejeita todo add() manual com StateError. Como pause()
    // e _publicarErro() publicam por add(), os dois lançavam sempre — era a
    // causa de a emissora escolhida nunca chegar ao player.
    expect(fonte.contains('.pipe(playbackState)'), isFalse,
        reason: 'pipe(playbackState) quebra todo add() manual de estado');
    expect(fonte.contains('listen(playbackState.add)'), isTrue);
  });
}
