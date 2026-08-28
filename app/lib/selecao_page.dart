import 'package:flutter/material.dart';

import 'emissora.dart';
import 'preferencias.dart';

/// Escolha da emissora.
///
/// Aparece na primeira abertura e sempre que o ouvinte pedir para trocar.
/// A escolha é gravada no aparelho — nas aberturas seguintes o app vai
/// direto ao player, sem perguntar de novo.
class SelecaoPage extends StatefulWidget {
  /// Quando true, mostra o botão de voltar: o ouvinte veio trocar de rádio,
  /// não está na primeira abertura, e cancelar precisa ser possível.
  final bool podeVoltar;

  const SelecaoPage({super.key, this.podeVoltar = false});

  @override
  State<SelecaoPage> createState() => _SelecaoPageState();
}

class _SelecaoPageState extends State<SelecaoPage> {
  late Future<List<Emissora>> _futuro;

  @override
  void initState() {
    super.initState();
    _futuro = Emissora.buscarTodas();
  }

  Future<void> _escolher(Emissora e) async {
    // Falha ao gravar a preferência não pode impedir a escolha: o ouvinte
    // ouve agora e, no pior caso, escolhe de novo na próxima abertura.
    try {
      await Preferencias.salvarEmissora(e);
    } catch (_) {
      // Segue mesmo assim.
    }
    if (mounted) Navigator.of(context).pop(e);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Escolha uma emissora'),
        automaticallyImplyLeading: widget.podeVoltar,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final novo = Emissora.buscarTodas();
          setState(() => _futuro = novo);
          await novo.catchError((_) => <Emissora>[]);
        },
        child: FutureBuilder<List<Emissora>>(
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
                  const SizedBox(height: 40),
                  Icon(Icons.cloud_off, size: 56, color: cs.outline),
                  const SizedBox(height: 20),
                  Text(
                    'Não foi possível carregar as emissoras.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Verifique sua conexão e puxe para baixo para tentar de novo.',
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }

            final emissoras = snap.data ?? const <Emissora>[];
            if (emissoras.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  const SizedBox(height: 40),
                  Icon(Icons.radio, size: 56, color: cs.outline),
                  const SizedBox(height: 20),
                  const Text(
                    'Nenhuma emissora disponível no momento.',
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: emissoras.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final e = emissoras[i];
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  leading: CircleAvatar(
                    radius: 24,
                    backgroundColor: cs.primaryContainer,
                    child: Icon(Icons.podcasts, color: cs.onPrimaryContainer),
                  ),
                  title: Text(
                    e.nome,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: e.descricao.isNotEmpty
                      ? Text(e.descricao, maxLines: 2, overflow: TextOverflow.ellipsis)
                      : null,
                  trailing: const Icon(Icons.play_circle_outline, size: 30),
                  onTap: () => _escolher(e),
                );
              },
            );
          },
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Text(
          'A emissora escolhida fica salva. Você pode trocar depois pelo menu.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
      ),
    );
  }
}
