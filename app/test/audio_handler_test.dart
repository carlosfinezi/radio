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

  test('a fonte é preparada sem BLOQUEAR, e sem preload: false', () {
    // O Future de setAudioSource só completa quando a mídia tem duração
    // conhecida. Uma rádio ao vivo não tem: aguardar ali prende a troca de
    // emissora por tempo indefinido.
    //
    // `preload: false` foi a primeira saída para isso — e era a causa do
    // silêncio. Nesse modo o just_audio não ativa o player nativo no
    // setAudioSource e adia a carga para dentro do play(); o ExoPlayer
    // estourava nesse caminho com "(2) Unexpected runtime error" em QUALQUER
    // transporte, MP3 contínuo ou HLS. A invariante que importa não é o
    // preload, é não aguardar.
    expect(RegExp(r'await\s+_player\s*\.\s*setAudioSource').hasMatch(fonte), isFalse,
        reason: 'await em setAudioSource trava: o Future não completa ao vivo');
    // Só o código: os comentários acima CITAM `preload: false` para explicar
    // por que ele saiu, e citar não é usar.
    final codigo = fonte
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(codigo.contains('preload: false'), isFalse,
        reason: 'preload: false deixa o ExoPlayer estourar na carga adiada');
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

  test('a reconexão nunca reentra num transporte já reprovado', () {
    // Alternar incondicionalmente devolvia o Android ao HLS no primeiro
    // soluço do Icecast — e o HLS quebra no ExoPlayer sem emitir erro novo,
    // então a cadeia morria ali, muda. Quem falha entra em quarentena.
    expect(fonte.contains('_urlsReprovadas.add'), isTrue,
        reason: 'o transporte que falhou precisa entrar em quarentena');
    expect(fonte.contains('_usandoFallback = !_usandoFallback'), isFalse,
        reason: 'alternância incondicional reentra no caminho quebrado');
  });

  test('há vigia de reprodução independente do errorStream', () {
    // A falha do HLS no ExoPlayer nem sempre emite erro: o player apenas
    // para em idle. Uma reconexão movida só por erro nunca é acionada, e a
    // rádio fica muda para sempre, sem nada na tela.
    expect(fonte.contains('_armarVigia()'), isTrue,
        reason: 'sem vigia, a falha muda do HLS não é recuperada');
    expect(
        RegExp(r'unawaited\(_player\.play\(\)\);[^\n]*\n\s*_armarVigia\(\)')
            .hasMatch(fonte),
        isTrue,
        reason: 'o vigia tem que ser armado logo após cada play');
  });
}
