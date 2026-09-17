// Trava a regressão da grade presa na emissora anterior.
//
// SchedulePage vive dentro de um IndexedStack, que constrói todas as abas de
// uma vez e as mantém vivas. Ao trocar de emissora o Flutter reaproveita o
// State — mesmo tipo, mesma posição, sem key — e o Future criado no initState
// continua apontando para a grade da estação antiga.
//
// O sintoma é ausência, não erro: a aba diz "Nenhum programa agendado" para
// quem tem grade cheia, e só se corrige reabrindo o app. Exercitar isso de
// verdade exigiria bombar a rede e montar a árvore inteira; aqui verificamos o
// código, como nos demais testes deste diretório.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final fonte = File('lib/schedule_page.dart').readAsStringSync();
  final codigo = fonte
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
      .join('\n');

  test('a grade recarrega quando a emissora muda', () {
    expect(codigo.contains('didUpdateWidget'), isTrue,
        reason: 'sem didUpdateWidget a aba fica presa na grade da emissora '
            'anterior até o app ser reaberto');
    expect(RegExp(r'didUpdateWidget[\s\S]{0,400}_carregar\(\)').hasMatch(codigo),
        isTrue,
        reason: 'didUpdateWidget precisa refazer o fetch, não só existir');
  });

  test('a troca é detectada pelo slug, não pelo objeto', () {
    // Emissora não implementa ==, então comparar instâncias daria "mudou" a
    // cada rebuild do HomeShell e a grade recarregaria sem parar, martelando
    // a API a cada troca de aba.
    expect(codigo.contains('emissora.slug'), isTrue,
        reason: 'comparar o objeto recarrega a grade a cada rebuild');
  });

  test('o fetch usa o endpoint da emissora corrente', () {
    // widget.emissora, nunca uma cópia guardada no State: guardar em campo
    // reintroduz exatamente o defeito que este arquivo trava.
    expect(codigo.contains('widget.emissora.urlProgramacao'), isTrue);
  });
}
