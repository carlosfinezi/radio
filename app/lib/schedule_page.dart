import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config.dart';

/// Grade de programação, lida da API pública do AzuraCast.
///
/// Atende a parte da alínea (h) que fala em "acesso à programação" — o app
/// não é só um player, ele mostra o que vai ao ar e quando.
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});
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

  Future<List<_Programa>> _carregar() async {
    final url = 'https://${Config.host}/api/station/${Config.stationSlug}/schedule';
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
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
        onRefresh: () async => setState(() => _futuro = _carregar()),
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
