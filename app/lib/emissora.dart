import 'dart:convert';
import 'package:http/http.dart' as http;

import 'config.dart';

/// Uma emissora da plataforma.
///
/// Espelha o que `/api/stations` do AzuraCast devolve. Os campos que o app
/// usa vêm prontos da API — não montamos URL de stream por concatenação,
/// porque o servidor já sabe a porta e o mount corretos de cada estação, e
/// errar isso foi justamente o defeito que deixou o endpoint em 404 durante
/// a implantação.
class Emissora {
  final int id;
  final String slug;
  final String nome;
  final String descricao;

  /// URL do stream contínuo (MP3/AAC), vinda da API.
  final String urlStream;

  /// URL do HLS. Pode ser nula se a emissora não tiver HLS habilitado —
  /// nesse caso o app usa só o stream contínuo.
  final String? urlHls;

  const Emissora({
    required this.id,
    required this.slug,
    required this.nome,
    required this.descricao,
    required this.urlStream,
    this.urlHls,
  });

  /// Endpoint público de metadados desta emissora.
  String get urlNowPlaying => '${Config.baseUrl}/api/nowplaying/$slug';

  /// Grade de programação desta emissora.
  String get urlProgramacao => '${Config.baseUrl}/api/station/$slug/schedule';

  /// HLS quando existir, senão o stream contínuo.
  ///
  /// O HLS é preferido por sobreviver a troca de rede (wifi -> 4G) e por
  /// funcionar nativamente no iOS.
  String get urlPreferida => urlHls ?? urlStream;

  factory Emissora.doJson(Map<String, dynamic> j) {
    final hls = j['hls_url'] as String?;
    return Emissora(
      id: j['id'] as int,
      slug: j['shortcode'] as String,
      nome: j['name'] as String,
      descricao: (j['description'] as String?)?.trim() ?? '',
      urlStream: j['listen_url'] as String,
      urlHls: (j['hls_enabled'] == true && hls != null && hls.isNotEmpty) ? hls : null,
    );
  }

  Map<String, dynamic> paraJson() => {
        'id': id,
        'shortcode': slug,
        'name': nome,
        'description': descricao,
        'listen_url': urlStream,
        'hls_url': urlHls,
        'hls_enabled': urlHls != null,
      };

  /// Busca as emissoras disponíveis na plataforma.
  ///
  /// Só retorna as públicas — o AzuraCast já filtra por `is_public`. Uma
  /// emissora marcada como privada não aparece na lista, mas continua
  /// alcançável por link direto, que é como um cliente que não quer
  /// aparecer publicamente divulga a dele.
  static Future<List<Emissora>> buscarTodas() async {
    final r = await http
        .get(Uri.parse(Config.stationsApi))
        .timeout(const Duration(seconds: 20));

    if (r.statusCode != 200) {
      throw Exception('Não foi possível carregar as emissoras (HTTP ${r.statusCode})');
    }

    final lista = jsonDecode(r.body) as List<dynamic>;
    return lista
        .map((e) => Emissora.doJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.nome.toLowerCase().compareTo(b.nome.toLowerCase()));
  }

  /// Busca uma emissora específica pelo slug.
  ///
  /// Usada quando o app é aberto por link direto
  /// (bitradio://emissora/<slug>) e a emissora ainda não está no aparelho.
  static Future<Emissora?> buscarPorSlug(String slug) async {
    try {
      final todas = await buscarTodas();
      for (final e in todas) {
        if (e.slug == slug) return e;
      }
    } catch (_) {
      // Sem rede, quem chama decide o que fazer.
    }
    return null;
  }
}
