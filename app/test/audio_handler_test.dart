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

  test('a sessão de áudio é configurada', () {
    // just_audio.play() "não faz nada se a ativação da sessão de áudio
    // falhar" — silenciosamente, sem exceção. O pacote audio_session estava
    // no pubspec e nunca era chamado: no Android o app abria, dizia AO VIVO
    // e não emitia som nenhum.
    expect(fonte.contains('AudioSessionConfiguration.music()'), isTrue,
        reason: 'sem configure() da sessão o Android não emite som');
  });

  test('playbackState recebe eventos por listen, nunca por pipe', () {
    // pipe() equivale a addStream, e enquanto um addStream está ativo o
    // BehaviorSubject rejeita todo add() manual com StateError. Como pause()
    // e _publicarErro() publicam por add(), os dois lançavam sempre — era a
    // causa de a emissora escolhida nunca chegar ao player.
    expect(fonte.contains('.pipe(playbackState)'), isFalse,
        reason: 'pipe(playbackState) quebra todo add() manual de estado');
    expect(fonte.contains('playbackState.add(estado)'), isTrue);
  });

  test('a reconexão alterna o transporte a cada tentativa', () {
    // Repetir o caminho que acabou de falhar não recupera nada, e quando a
    // repetição não emite erro novo — caso do "(2) Unexpected runtime error"
    // do ExoPlayer no HLS — a cadeia de reconexão morre e o player fica em
    // idle para sempre.
    expect(fonte.contains('_tentativasReconexao.isEven'), isFalse,
        reason: 'alternar só em tentativas pares repete o transporte quebrado');
    expect(fonte.contains('await _alternarTransporte()'), isTrue);
  });

  test('o transporte inicial depende da plataforma', () {
    // O ExoPlayer falha no nosso HLS; o Icecast contínuo toca. No iOS o HLS
    // é nativo e vale o inverso.
    expect(fonte.contains('TargetPlatform.iOS'), isTrue,
        reason: 'Android deve começar pelo stream contínuo');
  });
}
