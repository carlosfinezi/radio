/// Configuração da PLATAFORMA, não de uma emissora.
///
/// A primeira versão deste app tinha o slug da estação fixo aqui
/// (`porto_do_capim`), o que amarrava o aplicativo inteiro a um único
/// cliente. Como o BitRádio atende várias emissoras, a estação passou a ser
/// escolhida em tempo de execução e guardada no aparelho — ver
/// `preferencias.dart` e `selecao_page.dart`.
///
/// O que fica aqui é só o que vale para TODAS as emissoras.
class Config {
  /// Nome do produto, exibido na loja e no aparelho.
  static const String appNome = 'BitRádio';

  /// Servidor da plataforma. Todas as emissoras vivem sob este host —
  /// é o mesmo AzuraCast, multi-estação.
  static const String host = 'radio.1bit.net.br';

  static const String baseUrl = 'https://$host';

  /// Lista pública de emissoras. Não exige autenticação.
  static const String stationsApi = '$baseUrl/api/stations';

  /// Intervalo de atualização dos metadados do "tocando agora".
  ///
  /// 15s é o equilíbrio entre a capa mudar junto com a música e não
  /// martelar o servidor com um poll por segundo vindo de cada aparelho
  /// instalado. Com N clientes e M ouvintes, esse número multiplica.
  static const Duration nowPlayingInterval = Duration(seconds: 15);

  /// Contato exibido na tela "Sobre" e nas notas da loja.
  static const String contato = 'atendimento@1bit.net.br';

  /// Política de privacidade — exigida pelas lojas.
  static const String politicaPrivacidade = '$baseUrl/privacidade.html';
}
