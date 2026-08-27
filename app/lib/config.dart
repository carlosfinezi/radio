/// Configuração central do aplicativo.
///
/// Os endpoints apontam para o mesmo servidor validado pela suíte de
/// conformidade (`validation/run.mjs`). Se estas URLs divergirem das que
/// foram medidas nas alíneas (b) e (c) do edital, o app estará entregando
/// algo diferente do que foi auditado — por isso o check `h2` da suíte
/// verifica justamente que este host bate com o testado.
class Config {
  /// Host público da rádio (proxy do HestiaCP, TLS terminado aqui).
  static const String host = 'radio.liciteagora.app';

  static const String stationSlug = 'porto_do_capim';

  /// HLS é o transporte primário: funciona em iOS nativamente, sobrevive a
  /// troca de rede (wifi -> 4G) e escala por cache de segmento.
  static const String streamHls = 'https://$host/hls/$stationSlug/live.m3u8';

  /// Fallback ICY/MP3 para casos em que o HLS falha (proxy corporativo
  /// que bloqueia .m3u8, por exemplo).
  static const String streamIcy = 'https://$host/listen/$stationSlug/radio.mp3';

  /// Metadados públicos do "tocando agora" (não exige autenticação).
  static const String nowPlayingApi = 'https://$host/api/nowplaying/$stationSlug';

  static const String stationName = 'Web Rádio Porto do Capim';
  static const String stationSubtitle = 'Universidade Federal da Paraíba';

  /// Intervalo de atualização dos metadados. 15s é o equilíbrio entre
  /// "a capa muda junto com a música" e não martelar o servidor com um
  /// poll por segundo vindo de cada aparelho instalado.
  static const Duration nowPlayingInterval = Duration(seconds: 15);
}
