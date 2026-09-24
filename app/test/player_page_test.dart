// Trava o rótulo que acusava a emissora de um silêncio que era nosso.
//
// `pause()` publica `playing: false` com `processingState: ready` — o MESMO
// par que o app mostra antes do primeiro play. A tela não distinguia isso de
// falha e escrevia "Fora do ar" nos dois casos, anunciando a estação caída
// toda vez que o ouvinte apertava parar.
//
// Exercitar a tela de verdade exigiria subir o AudioService e a plataforma
// nativa junto; aqui verificamos o código, como nos demais testes deste
// diretório.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final fonte = File('lib/main.dart').readAsStringSync();
  final codigo = fonte
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('pausa não é anunciada como emissora fora do ar', () {
    // O comentário do código CITA o rótulo antigo para explicar por que ele
    // saiu; citar não é usar, por isso a checagem roda sobre `codigo`.
    expect(codigo.contains('Fora do ar'), isFalse,
        reason: 'o ouvinte que pausou lê "Fora do ar" e conclui que a rádio '
            'caiu — principalmente pela tela de bloqueio ou pelo carro, onde '
            'ele nem vê que foi ele quem parou');
    expect(codigo.contains("'Pausado'"), isTrue,
        reason: 'silêncio pedido pelo ouvinte precisa de rótulo próprio');
  });

  test('o estado de erro é lido do processingState, não da ausência de som', () {
    // Deduzir falha de "não está tocando" é o que criou o defeito acima:
    // pausado e quebrado são silêncios diferentes.
    expect(codigo.contains('AudioProcessingState.error'), isTrue);
    expect(codigo.contains("'Sem sinal'"), isTrue,
        reason: 'falha real precisa de rótulo distinto de pausa');
  });

  test('há retentativa manual, e ela não é um play()', () {
    // play() sozinho não recupera: depois da falha `_precisaCarregar` continua
    // false (quem o zera é _carregar, que roda antes de o erro chegar), então
    // o botão mandaria tocar exatamente a fonte quebrada e pareceria morto.
    expect(codigo.contains('tentarNovamente()'), isTrue,
        reason: 'sem retentativa manual a única saída do erro é fechar o app, '
            'porque a reconexão automática recua até 30s entre tentativas');
  });

  test('a capa trata URL quebrada', () {
    // A arte vem do AzuraCast e troca a cada música: URL quebrada é rotina,
    // não exceção. Em DecorationImage a falha vira exceção de imagem não
    // tratada a cada poll de 15s e a caixa fica vazia.
    expect(codigo.contains('errorBuilder'), isTrue,
        reason: 'sem errorBuilder a capa quebrada vira exceção repetida');
    expect(RegExp(r'DecorationImage\s*\(\s*\n?\s*image:\s*NetworkImage')
        .hasMatch(codigo), isFalse,
        reason: 'DecorationImage não tem como cair num ícone de reserva');
  });

  test('o botão principal tem rótulo para leitor de tela', () {
    // Sem tooltip o TalkBack anuncia só "botão" no único controle da tela.
    expect(RegExp(r'tooltip:\s*tocando').hasMatch(codigo), isTrue,
        reason: 'o play/stop precisa de rótulo acessível');
  });
}
