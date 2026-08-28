import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'emissora.dart';

/// Guarda a emissora escolhida no aparelho.
///
/// POR QUE GUARDAR A EMISSORA INTEIRA, E NÃO SÓ O SLUG:
/// Guardando apenas o slug, toda abertura do app precisaria consultar
/// `/api/stations` antes de poder tocar qualquer coisa — e sem rede o
/// aplicativo abriria numa tela de erro em vez de tentar tocar. Com o objeto
/// completo em disco, o app monta o player na hora e revalida em segundo
/// plano.
class Preferencias {
  static const _chaveEmissora = 'emissora_escolhida';

  /// Emissora salva, ou null na primeira execução.
  static Future<Emissora?> emissoraSalva() async {
    final p = await SharedPreferences.getInstance();
    final bruto = p.getString(_chaveEmissora);
    if (bruto == null || bruto.isEmpty) return null;
    try {
      return Emissora.doJson(jsonDecode(bruto) as Map<String, dynamic>);
    } catch (_) {
      // Formato antigo ou corrompido: descarta e trata como primeira
      // execução, em vez de deixar o app travado num estado inválido.
      await p.remove(_chaveEmissora);
      return null;
    }
  }

  static Future<void> salvarEmissora(Emissora e) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_chaveEmissora, jsonEncode(e.paraJson()));
  }

  static Future<void> limpar() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_chaveEmissora);
  }
}
