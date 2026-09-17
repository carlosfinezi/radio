import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'emissora.dart';

/// Grade de programação, lida da API pública do AzuraCast.
///
/// Atende a parte da alínea (h) que fala em "acesso à programação" — o app
/// não é só um player, ele mostra o que vai ao ar e quando.
class SchedulePage extends StatefulWidget {
  /// A emissora deixou de ser constante: o BitRádio atende várias, e a
  /// grade precisa ser a de quem está tocando.
  final Emissora emissora;

  const SchedulePage({super.key, required this.emissora});
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late Future<List<_Programa>> _futuro;

  @override
  void initState() {
    super.initState();
    _futuro = _carregar();
  }

  /// RECARREGA QUANDO A EMISSORA MUDA. Sem isto a aba fica presa na grade da
  /// estação anterior.
  ///
  /// `initState` roda UMA vez. Esta página vive dentro de um `IndexedStack`
  /// (ver HomeShell), que constrói todas as abas de uma vez e as mantém vivas;
  /// ao trocar de emissora o Flutter reaproveita este State — mesmo tipo, mesma
  /// posição, sem key — e `_futuro` continua apontando para o resultado antigo.
  ///
  /// O sintoma não é erro nenhum: a aba diz "Nenhum programa agendado" para uma
  /// emissora que tem grade cheia, e só se corrige fechando e reabrindo o app.
  /// Reproduzido em emulador: abrir na Rádio Demonstração (zero programas),
  /// trocar para a Porto do Capim (quatro) e a aba seguir vazia.
  @override
  void didUpdateWidget(SchedulePage anterior) {
    super.didUpdateWidget(anterior);
    // Comparar pelo slug, não pelo objeto: Emissora não implementa ==, então
    // duas instâncias da MESMA estação seriam tidas como diferentes e a grade
    // recarregaria a cada rebuild do HomeShell.
    if (anterior.emissora.slug != widget.emissora.slug) {
      setState(() => _futuro = _carregar());
    }
  }

  Future<List<_Programa>> _carregar() async {
    final r = await http
        .get(Uri.parse(widget.emissora.urlProgramacao))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('Não foi possível carregar a programação (HTTP ${r.statusCode})');
    }
    final lista = jsonDecode(r.body) as List<dynamic>;
    return lista
        .map((e) => _Programa.doJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        // Precisa AGUARDAR o fetch: `() async => setState(...)` retorna
        // imediatamente e o indicador some antes dos dados chegarem.
        onRefresh: () async {
          final novo = _carregar();
          setState(() => _futuro = novo);
          await novo.catchError((_) => <_Programa>[]);
        },
        child: FutureBuilder<List<_Programa>>(
          future: _futuro,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              // Lista rolável mesmo no erro, senão o "puxar para atualizar"
              // não funciona e o usuário fica preso na tela de falha.
              return ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  const Icon(Icons.cloud_off, size: 48),
                  const SizedBox(height: 16),
                  Text('${snap.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Text('Puxe para baixo para tentar de novo.',
                      textAlign: TextAlign.center),
                ],
              );
            }

            final itens = snap.data ?? const <_Programa>[];
            if (itens.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(32),
                children: const [
                  Icon(Icons.event_busy, size: 48),
                  SizedBox(height: 16),
                  Text('Nenhum programa agendado no momento.',
                      textAlign: TextAlign.center),
                ],
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: itens.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = itens[i];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(DateFormat('HH').format(p.inicio)),
                  ),
                  title: Text(p.nome),
                  subtitle: Text(
                    '${DateFormat('dd/MM HH:mm').format(p.inicio)}'
                    ' — ${DateFormat('HH:mm').format(p.fim)}',
                  ),
                  trailing: p.estaNoAr
                      ? const Chip(
                          label: Text('no ar'),
                          visualDensity: VisualDensity.compact,
                        )
                      : null,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Programa {
  final String nome;
  final DateTime inicio;
  final DateTime fim;

  _Programa({required this.nome, required this.inicio, required this.fim});

  /// O AzuraCast devolve `start`/`end` em ISO-8601 com deslocamento de fuso.
  /// Convertemos para o fuso local do aparelho: um ouvinte em outro estado
  /// precisa ver o horário dele, não o do servidor.
  factory _Programa.doJson(Map<String, dynamic> j) => _Programa(
        nome: (j['name'] as String?) ?? 'Programa',
        inicio: DateTime.parse(j['start'] as String).toLocal(),
        fim: DateTime.parse(j['end'] as String).toLocal(),
      );

  bool get estaNoAr {
    final agora = DateTime.now();
    return agora.isAfter(inicio) && agora.isBefore(fim);
  }
}
