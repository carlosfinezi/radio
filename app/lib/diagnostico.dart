import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'main.dart' show audioHandler;

/// Tela de diagnóstico da reprodução.
///
/// POR QUE EXISTE: o app pode exibir "AO VIVO" e não emitir som — o estado do
/// player e a saída de áudio são coisas diferentes. No aparelho do ouvinte não
/// há logcat à mão, e sem esses números a investigação vira adivinhação.
///
/// Mostra o que o player realmente pensa que está fazendo e copia tudo para a
/// área de transferência. Nada é enviado pela rede e nada sai daqui sem o
/// ouvinte tocar em "Copiar": não há identificador de aparelho nem dado
/// pessoal, apenas o estado interno da reprodução.
class DiagnosticoPage extends StatelessWidget {
  const DiagnosticoPage({super.key});

  Map<String, dynamic> _coletar() {
    final h = audioHandler;
    final estado = h.playbackState.value;
    final e = h.emissora;
    return {
      'emissora': e?.slug,
      'url_em_uso': h.urlEmUso,
      'url_hls': e?.urlHls,
      'url_stream': e?.urlStream,
      'usando_stream_continuo': h.usandoFallback,
      // Se o HLS aparecer aqui, foi ele que falhou NESTE aparelho — não a
      // rede nem o servidor. É o dado que separa as duas hipóteses.
      'transportes_reprovados': h.transportesReprovados,
      'sessao_de_audio_configurada': h.sessaoConfigurada,
      'erro_da_sessao': h.erroSessao,
      'player_tocando': estado.playing,
      'estado_do_player': estado.processingState.name,
      'volume': h.volume,
      'erro_exibido': estado.errorMessage,
      'ultimo_erro_do_player': h.ultimoErro,
      'faixa_no_ar': h.mediaItem.value?.title,
    };
  }

  @override
  Widget build(BuildContext context) {
    final dados = _coletar();
    final texto = const JsonEncoder.withIndent('  ').convert(dados);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Se o som não estiver saindo, copie estas informações e envie para '
            '${Config.contato}. Elas descrevem apenas o estado da reprodução — '
            'nenhum dado pessoal.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          for (final entrada in dados.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entrada.key,
                      style: TextStyle(fontSize: 12, color: cs.outline)),
                  SelectableText(
                    '${entrada.value}',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: texto));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Diagnóstico copiado.')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar diagnóstico'),
          ),
        ],
      ),
    );
  }
}
