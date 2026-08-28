import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'emissora.dart';

/// Handler de áudio que roda em segundo plano.
///
/// Atende ao que as lojas exigem de um app de rádio:
///   1. o áudio continua com a tela bloqueada;
///   2. os controles aparecem na tela de bloqueio e na notificação;
///   3. o título da música acompanha o que está no ar.
///
/// E um quarto que o contrato chama de "contínuo e ininterrupto": queda de
/// rede não pode encerrar a sessão. Ver [_agendarReconexao].
///
/// MULTI-EMISSORA: a estação não é mais constante. Chega por [trocarEmissora],
/// o que permite o ouvinte mudar de rádio sem reiniciar o app.
class RadioAudioHandler extends BaseAudioHandler {
  final _player = AudioPlayer();

  Emissora? _emissora;
  Emissora? get emissora => _emissora;

  Timer? _metadataTimer;
  Timer? _reconexaoTimer;
  Timer? _vigiaTimer;
  StreamSubscription<Object>? _erroSub;
  StreamSubscription<PlaybackState>? _estadoSub;

  /// Quanto o vigia espera pelo som antes de dar o transporte por perdido.
  ///
  /// Não é generoso à toa: em rede móvel ruim o Icecast leva alguns segundos
  /// para encher o buffer, e o HLS ainda precisa buscar a playlist e dois ou
  /// três segmentos antes do primeiro quadro. Um prazo curto derrubaria
  /// conexões que estavam apenas demorando.
  static const Duration _prazoDoVigia = Duration(seconds: 20);

  /// Controla se a fonte precisa ser recarregada antes do próximo play.
  ///
  /// NÃO usar `_player.audioSource == null` para isso: em just_audio 0.10.x
  /// esse getter passa a devolver valor não-nulo após o primeiro load e nunca
  /// mais volta a ser null — nem depois de `stop()`. Confiar nele fazia o app
  /// tocar UMA vez e ficar em silêncio permanente a partir do segundo play.
  bool _precisaCarregar = true;

  /// Se estamos no caminho MP3 porque o HLS falhou.
  bool _usandoFallback = false;

  /// Transportes que já falharam NESTE aparelho, para esta emissora.
  ///
  /// O ExoPlayer quebra no nosso HLS em parte dos aparelhos com "(2)
  /// Unexpected runtime error", e — pior — essa quebra nem sempre emite erro
  /// novo: o player apenas para em `idle`. Voltar a um transporte já reprovado
  /// é entrar num beco sem som e sem aviso, que era exatamente o que a
  /// alternância incondicional fazia: bastava um soluço do Icecast para a
  /// reconexão jogar o Android de volta no HLS e a rádio emudecer de vez.
  ///
  /// A quarentena vale por emissora — [trocarEmissora] a zera, porque outra
  /// estação pode ter HLS saudável.
  final Set<String> _urlsReprovadas = {};

  int _tentativasReconexao = 0;

  // ── Espelhos para a tela de diagnóstico ────────────────────────────────
  // O estado interno do player não é observável de fora, e sem logcat no
  // aparelho do ouvinte é o único jeito de saber por que não sai som.

  /// A sessão de áudio foi configurada com sucesso? Se não, o just_audio
  /// silenciosamente não reproduz nada.
  bool sessaoConfigurada = false;

  /// Motivo da falha ao configurar a sessão, quando houver.
  String? erroSessao;

  /// Último erro vindo do player, mesmo que já tenha sido superado.
  String? ultimoErro;

  /// URL efetivamente entregue ao player.
  String? urlEmUso;

  bool get usandoFallback => _usandoFallback;
  double get volume => _player.volume;

  /// Transportes em quarentena, para a tela de diagnóstico. Se o HLS aparecer
  /// aqui, foi ele que falhou no aparelho — não a rede nem o servidor.
  List<String> get transportesReprovados => _urlsReprovadas.toList();

  RadioAudioHandler() {
    _configurarSessaoDeAudio();

    // listen(), NÃO pipe(). ISTO É O QUE FAZIA A RÁDIO NÃO TOCAR.
    //
    // `Stream.pipe(consumer)` equivale a `consumer.addStream(stream)`, e
    // enquanto um addStream está ativo o BehaviorSubject REJEITA todo add()
    // manual com StateError. Como pause() e _publicarErro() publicam estado
    // por add(), os dois lançavam sempre — e a exceção em pause() subia por
    // trocarEmissora(), que nunca completava: a tela de seleção voltava para
    // o início e a emissora nunca era definida. Pior, _publicarErro() também
    // lançava, então nem a mensagem de erro aparecia. O app ficava mudo e
    // sem explicação. (O exemplo oficial do audio_service usa pipe(); ele só
    // funciona lá porque nada mais publica em playbackState.)
    _estadoSub =
        _player.playbackEventStream.map(_transformEvent).listen((estado) {
      // Reprodução estabilizada zera o recuo: sem isto o contador só cresce e
      // a próxima queda esperaria os 30s do fim da escada anterior em vez de
      // reconectar em 2s.
      if (estado.playing &&
          estado.processingState == AudioProcessingState.ready) {
        _tentativasReconexao = 0;
        // Saiu som: o vigia cumpriu o papel e não tem mais o que vigiar.
        _vigiaTimer?.cancel();
      }
      playbackState.add(estado);
    });

    // just_audio 0.10 moveu os erros de `playbackEventStream.onError` para um
    // stream dedicado. Sem escutar aqui, queda de rede, 404 ou troca de wifi
    // para 4G passavam despercebidos: a interface seguia exibindo "AO VIVO"
    // em silêncio.
    _erroSub = _player.errorStream.listen((e) {
      ultimoErro = _descreverErro(e);
      _publicarErro(e.toString());
      _agendarReconexao();
    });
  }

  /// Configura a sessão de áudio do sistema.
  ///
  /// SEM ISTO O ANDROID NÃO EMITE SOM. A documentação do `just_audio.play()`
  /// é explícita: "ativa a sessão de áudio antes da reprodução, e NÃO FAZ
  /// NADA se a ativação falhar por qualquer motivo". Falha silenciosa — sem
  /// exceção, sem erro, sem áudio. O pacote `audio_session` estava declarado
  /// no pubspec e nunca era chamado; no navegador passava despercebido
  /// porque a política de áudio da web é permissiva.
  ///
  /// `music()` é o perfil correto para rádio: pede foco de áudio duradouro,
  /// abaixa o volume quando chega uma notificação em vez de cortar, e
  /// silencia o app quando o ouvinte atende uma ligação.
  Future<void> _configurarSessaoDeAudio() async {
    try {
      final sessao = await AudioSession.instance;
      await sessao.configure(const AudioSessionConfiguration.music());
      sessaoConfigurada = true;

      // Fone desconectado ou saída Bluetooth perdida: pausa em vez de sair
      // tocando alto no viva-voz — comportamento esperado de app de mídia.
      sessao.becomingNoisyEventStream.listen((_) => pause());
    } catch (erro) {
      erroSessao = erro.toString();
      // Sem sessão configurada o áudio pode não sair, mas travar a
      // construção do handler deixaria o app inteiro inutilizável.
    }
  }

  // ── Emissora ───────────────────────────────────────────────────────────

  /// Troca a emissora corrente. Para o que estiver tocando e prepara a nova.
  ///
  /// [tocarEmSeguida] existe porque há dois caminhos até aqui e eles querem
  /// coisas opostas: quem ESCOLHE uma rádio numa lista está dizendo "quero
  /// ouvir isto agora"; quem apenas ABRE o app com uma emissora já salva não
  /// pediu som nenhum ainda. Antes isto tocava só se já estivesse tocando —
  /// e como na primeira abertura nunca está, escolher a rádio deixava o app
  /// parado, sem som e sem erro.
  Future<void> trocarEmissora(Emissora nova, {bool tocarEmSeguida = false}) async {
    final tocava = _player.playing;
    await pause();
    _emissora = nova;
    _precisaCarregar = true;
    _usandoFallback = false;
    // Quarentena é por emissora: a estação anterior pode ter HLS quebrado e
    // esta não. Herdar a reprovação privaria a nova rádio de um caminho bom.
    _urlsReprovadas.clear();
    _tentativasReconexao = 0;
    _publicarItemInicial();
    if (tocava || tocarEmSeguida) await play();
  }

  void _publicarItemInicial() {
    final e = _emissora;
    if (e == null) return;
    mediaItem.add(MediaItem(
      id: e.urlPreferida,
      title: e.nome,
      artist: Config.appNome,
      isLive: true,
      // duration nulo == transmissão contínua, sem barra de progresso
    ));
  }

  // ── Controles de transporte ────────────────────────────────────────────

  @override
  Future<void> play() async {
    if (_emissora == null) return;   // sem emissora escolhida, nada a tocar
    _reconexaoTimer?.cancel();

    // Antes, uma falha aqui subia pela pilha e morria no `onPressed` do botão:
    // o app não tocava, não mostrava erro e não tentava de novo. O ouvinte via
    // um botão de play que aparentemente não fazia nada.
    try {
      if (_precisaCarregar) {
        await _carregarComFallback();
      }
      _iniciarAtualizacaoDeMetadados();
      // NUNCA `await _player.play()`. A documentação do just_audio é
      // explícita: o Future "completa quando a reprodução termina, é pausada
      // ou parada". Numa rádio ao vivo isso nunca acontece — o await ficava
      // pendurado para sempre, travando trocarEmissora(), a abertura do app
      // e a tela de seleção junto com ele.
      unawaited(_player.play());
      _armarVigia();
      _tentativasReconexao = 0;
    } catch (erro) {
      _publicarErro(erro.toString());
      _agendarReconexao();
    }
  }

  /// Numa rádio ao vivo não existe "retomar de onde parou": ao voltar, o
  /// ouvinte tem que ouvir o que está no ar AGORA, não o buffer velho.
  /// Por isso pausar descarta a fonte — mas, diferente de [stop], mantém a
  /// sessão de mídia viva para o botão do fone, do carro e da tela de
  /// bloqueio continuarem funcionando.
  @override
  Future<void> pause() async {
    _metadataTimer?.cancel();
    // Pausa é silêncio pedido pelo ouvinte: o vigia não pode confundi-la com
    // falha e sair reconectando sozinho.
    _vigiaTimer?.cancel();
    await _player.stop();
    _precisaCarregar = true;
    _publicarEstado(playbackState.value.copyWith(
      playing: false,
      controls: [MediaControl.play],
      processingState: AudioProcessingState.ready,
    ));
  }

  @override
  Future<void> stop() async {
    _metadataTimer?.cancel();
    _reconexaoTimer?.cancel();
    _vigiaTimer?.cancel();
    await _player.stop();
    _precisaCarregar = true;
    // NÃO chamar `_player.dispose()` aqui. `_player` é final, criado uma
    // única vez, e dispose marca o objeto como descartado de forma
    // irreversível: todo método posterior vira no-op SILENCIOSO. O handler
    // ficaria morto sem lançar exceção nenhuma.
    await super.stop();
  }

  /// Libera recursos. Só no encerramento do handler.
  Future<void> dispose() async {
    _metadataTimer?.cancel();
    _reconexaoTimer?.cancel();
    _vigiaTimer?.cancel();
    await _erroSub?.cancel();
    await _estadoSub?.cancel();
    await _player.dispose();
  }

  // ── Carga da fonte ─────────────────────────────────────────────────────

  /// Transportes desta emissora, do preferido ao último recurso NESTA
  /// plataforma.
  ///
  /// No Android o ExoPlayer falha ao carregar o nosso HLS com
  /// "(2) Unexpected runtime error" e fica em `idle` — sem som e sem nada na
  /// tela, porque o erro é engolido. O stream contínuo do Icecast toca sem
  /// intercorrência no mesmo aparelho. No iOS vale o inverso: HLS é nativo e
  /// sobrevive à troca de rede, enquanto conexão contínua é problemática.
  ///
  /// A ordem é só preferência: [_transporteDisponivel] pula o que já falhou
  /// aqui, então nenhum ouvinte fica preso no caminho que não funciona no
  /// aparelho dele — nem é devolvido a ele depois.
  List<String> _transportes(Emissora e) {
    final hls = e.urlHls;
    if (hls == null) return [e.urlStream];
    return defaultTargetPlatform == TargetPlatform.iOS
        ? [hls, e.urlStream]
        : [e.urlStream, hls];
  }

  String _transporteInicial(Emissora e) => _transportes(e).first;

  /// Melhor transporte ainda não reprovado, ou null quando todos falharam.
  String? _transporteDisponivel(Emissora e) {
    for (final url in _transportes(e)) {
      if (!_urlsReprovadas.contains(url)) return url;
    }
    return null;
  }

  /// Prepara a fonte de áudio sem BLOQUEAR em cima dela.
  ///
  /// O Future de `setAudioSource` só completa quando a mídia está carregada e
  /// com duração conhecida — e uma rádio ao vivo não tem duração nem fim.
  /// Aguardar ali prendia a troca de emissora por tempo indefinido; um
  /// timeout só trocava o travamento por uma falha garantida.
  ///
  /// A primeira saída para isso foi `preload: false`. ELA ERA A CAUSA DO
  /// SILÊNCIO. O diagnóstico do aparelho mostrou o player em `playing: true`
  /// com `processingState: idle` e "(2) Unexpected runtime error" — e o mesmo
  /// erro no MP3 contínuo E no HLS, o que descarta o transporte como culpado.
  /// Com `preload: false` o just_audio não ativa o player nativo no
  /// setAudioSource: adia tudo para dentro do play(), e é nesse caminho adiado
  /// que o ExoPlayer estoura. Servidor, manifesto, sessão de áudio, volume e
  /// minificação já tinham sido verificados e estavam corretos.
  ///
  /// A regra que importa nunca foi o preload — é NÃO AGUARDAR. Então voltamos
  /// ao preload padrão e simplesmente não esperamos o Future, que numa rádio
  /// ao vivo jamais completa. O que falhar chega por [_player.errorStream] ou
  /// pelo onError abaixo.
  Future<void> _carregarComFallback() async {
    final e = _emissora!;
    await _carregar(_transporteDisponivel(e) ?? _transporteInicial(e));
  }

  Future<void> _carregar(String url) async {
    final e = _emissora!;
    urlEmUso = url;
    unawaited(_player.setAudioSource(AudioSource.uri(Uri.parse(url))).then<void>(
      (_) {},
      onError: (Object erro) {
        // Sem este onError a falha viraria erro assíncrono não tratado: some
        // do app e não chega em lugar nenhum que o ouvinte possa relatar.
        ultimoErro = _descreverErro(erro);
        _publicarErro('Falha ao abrir a transmissão.');
        _agendarReconexao();
      },
    ));
    _usandoFallback = url == e.urlStream;
    _precisaCarregar = false;
  }

  /// Reprova o transporte corrente e passa para o melhor que ainda resta.
  ///
  /// ANTES ISTO ALTERNAVA INCONDICIONALMENTE, E ERA O QUE EMUDECIA A RÁDIO.
  /// No Android o app começa no Icecast contínuo, que funciona; bastava um
  /// soluço qualquer — e o Icecast solta a conexão de rotina, na troca de
  /// fonte — para a reconexão empurrar o player para o HLS, o caminho que
  /// quebra no ExoPlayer sem sequer emitir erro novo. Sem erro não havia
  /// reagendamento, e o player ficava em `idle` para sempre: sem som, sem
  /// mensagem na tela e sem nova tentativa. O ouvinte só via a rádio parar.
  ///
  /// Agora quem falha entra em quarentena e não é mais oferecido.
  ///
  /// Retorna false quando não há outro caminho para tentar.
  Future<bool> _alternarTransporte() async {
    final e = _emissora;
    if (e == null) return false;

    final atual = urlEmUso;
    if (atual != null) _urlsReprovadas.add(atual);

    var proximo = _transporteDisponivel(e);
    if (proximo == null) {
      // Todos reprovados. A culpa pode ter sido da rede, não do transporte —
      // um túnel derruba os dois caminhos igualmente. Zera a quarentena e
      // recomeça pelo preferido, senão a rádio nunca mais voltaria.
      _urlsReprovadas.clear();
      proximo = _transporteInicial(e);
    }

    await _carregar(proximo);
    return true;
  }

  // ── Reconexão ──────────────────────────────────────────────────────────

  /// Rede de segurança para a falha MUDA.
  ///
  /// Toda a reconexão deste handler é movida pelo [_player.errorStream]. A
  /// armadilha é que a quebra do HLS no ExoPlayer nem sempre emite erro: o
  /// player apenas para em `idle`. Sem erro não há reagendamento, e a cadeia
  /// inteira morre em silêncio — o defeito que o diagnóstico do aparelho
  /// registrou como `estado_do_player: "idle"` sem nada na tela.
  ///
  /// O vigia não confia em erro nenhum: se passado [_prazoDoVigia] o player
  /// não estiver tocando, trata como falha e reconecta por conta própria.
  void _armarVigia() {
    _vigiaTimer?.cancel();
    _vigiaTimer = Timer(_prazoDoVigia, () {
      if (_player.playing &&
          _player.processingState == ProcessingState.ready) {
        return;
      }
      final url = urlEmUso;
      ultimoErro = 'Sem áudio em ${_prazoDoVigia.inSeconds}s por $url '
          '(estado ${_player.processingState.name}, sem erro do player)';
      _publicarErro('Este caminho não trouxe áudio. Tentando outro…');
      _agendarReconexao();
    });
  }

  /// Recuo exponencial limitado a 30s, TROCANDO O TRANSPORTE A CADA
  /// TENTATIVA — mas nunca de volta para um que já falhou.
  ///
  /// Antes só alternava em tentativas pares, então a primeira retentativa
  /// repetia o caminho que acabara de falhar. Quando essa repetição não
  /// emitia erro novo — que é o caso do "(2) Unexpected runtime error" do
  /// ExoPlayer no HLS — a cadeia de reconexão morria ali e o player ficava
  /// em `idle` para sempre: sem som, sem erro na tela e sem nova tentativa.
  ///
  /// Alternar sempre corrigiu isso pela metade: passou a reentrar no
  /// transporte quebrado a cada segunda tentativa. Quem escolhe o próximo
  /// caminho agora é [_alternarTransporte], que mantém a quarentena.
  void _agendarReconexao() {
    if (_emissora == null) return;

    _reconexaoTimer?.cancel();
    _tentativasReconexao++;

    final segundos = (1 << (_tentativasReconexao.clamp(1, 5))).clamp(2, 30);
    _reconexaoTimer = Timer(Duration(seconds: segundos), () async {
      try {
        // Se o transporte atual falhou, o outro é a aposta melhor. Só
        // recarrega o mesmo quando não existe alternativa.
        if (!await _alternarTransporte()) {
          _precisaCarregar = true;
          await _carregarComFallback();
        }
        unawaited(_player.play());   // ver play(): não completa em stream ao vivo
        _armarVigia();               // a retentativa também pode falhar calada
      } catch (erro) {
        _publicarErro(erro.toString());
        _agendarReconexao();
      }
    });
  }

  /// Extrai tudo que o erro carrega, não só o `toString()`.
  ///
  /// "(2) Unexpected runtime error" é o que o `PlayerException.toString()`
  /// devolve, e ele ESCONDE a exceção que realmente estourou dentro do
  /// ExoPlayer — o 2 é só `TYPE_UNEXPECTED`. Sem logcat no aparelho do
  /// ouvinte, o `details`/`stacktrace` que vem pela ponte é a única chance de
  /// saber a causa em vez de deduzi-la.
  String _descreverErro(Object erro) {
    final b = StringBuffer('${erro.runtimeType}: $erro');
    if (erro is PlatformException) {
      b.write(' | code=${erro.code}');
      if (erro.details != null) b.write(' | details=${erro.details}');
      if (erro.stacktrace != null) b.write(' | stack=${erro.stacktrace}');
    } else if (erro is PlayerException) {
      b.write(' | code=${erro.code}');
    }
    return b.toString();
  }

  void _publicarErro(String msg) {
    _publicarEstado(playbackState.value.copyWith(
      processingState: AudioProcessingState.error,
      errorMessage: msg,
      controls: [MediaControl.play],
      playing: false,
    ));
  }

  /// Publica estado sem deixar que uma falha aqui derrube quem chamou.
  ///
  /// Publicar estado é acessório; trocar de emissora e tocar são o essencial.
  /// Antes, uma exceção neste ponto abortava a troca de emissora inteira.
  void _publicarEstado(PlaybackState estado) {
    try {
      playbackState.add(estado);
    } catch (_) {
      // Sessão de mídia já encerrada — nada a publicar.
    }
  }

  // ── Metadados ──────────────────────────────────────────────────────────

  void _iniciarAtualizacaoDeMetadados() {
    _metadataTimer?.cancel();
    _atualizarMetadados();
    _metadataTimer =
        Timer.periodic(Config.nowPlayingInterval, (_) => _atualizarMetadados());
  }

  Future<void> _atualizarMetadados() async {
    final e = _emissora;
    if (e == null) return;
    try {
      final r = await http
          .get(Uri.parse(e.urlNowPlaying))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final song = data['now_playing']?['song'] as Map<String, dynamic>?;
      if (song == null) return;

      final art = song['art'] as String?;
      final titulo = song['title'] as String?;
      final artista = song['artist'] as String?;

      mediaItem.add(MediaItem(
        id: e.urlPreferida,
        title: (titulo != null && titulo.isNotEmpty) ? titulo : e.nome,
        artist: (artista != null && artista.isNotEmpty) ? artista : e.nome,
        album: e.nome,
        artUri: (art != null && art.isNotEmpty) ? Uri.tryParse(art) : null,
        isLive: true,
      ));
    } catch (_) {
      // Falha de metadado NUNCA pode derrubar a reprodução: o ouvinte
      // prefere ouvir sem saber o nome da música a ficar sem áudio.
    }
  }

  // ── Estado ─────────────────────────────────────────────────────────────

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.play, MediaAction.pause, MediaAction.stop},
      androidCompactActionIndices: const [0],
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: _player.playing,
      // Transmissão ao vivo não tem posição navegável. Publicamos zero para
      // a tela de bloqueio não desenhar uma barra de progresso mentirosa —
      // motivo recorrente de rejeição na App Store.
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
    );
  }
}
