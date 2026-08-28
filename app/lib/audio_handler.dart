import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
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
  StreamSubscription<Object>? _erroSub;

  /// Controla se a fonte precisa ser recarregada antes do próximo play.
  ///
  /// NÃO usar `_player.audioSource == null` para isso: em just_audio 0.10.x
  /// esse getter passa a devolver valor não-nulo após o primeiro load e nunca
  /// mais volta a ser null — nem depois de `stop()`. Confiar nele fazia o app
  /// tocar UMA vez e ficar em silêncio permanente a partir do segundo play.
  bool _precisaCarregar = true;

  /// Se estamos no caminho MP3 porque o HLS falhou.
  bool _usandoFallback = false;

  int _tentativasReconexao = 0;

  RadioAudioHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);

    // just_audio 0.10 moveu os erros de `playbackEventStream.onError` para um
    // stream dedicado. Sem escutar aqui, queda de rede, 404 ou troca de wifi
    // para 4G passavam despercebidos: a interface seguia exibindo "AO VIVO"
    // em silêncio.
    _erroSub = _player.errorStream.listen((e) {
      _publicarErro(e.toString());
      _agendarReconexao();
    });
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
    await _player.stop();
    _precisaCarregar = true;
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [MediaControl.play],
      processingState: AudioProcessingState.ready,
    ));
  }

  @override
  Future<void> stop() async {
    _metadataTimer?.cancel();
    _reconexaoTimer?.cancel();
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
    await _erroSub?.cancel();
    await _player.dispose();
  }

  // ── Carga da fonte ─────────────────────────────────────────────────────

  /// Tempo máximo esperando uma fonte ficar pronta antes de tentar a outra.
  ///
  /// ESTE TIMEOUT É O QUE FAZ O FALLBACK EXISTIR DE VERDADE. `setAudioSource`
  /// não lança quando o HLS está inacessível ou com a janela de segmentos
  /// vencida: o Future simplesmente não completa, o player fica em buffering
  /// para sempre e o `catch` abaixo nunca roda. O sintoma é o pior possível —
  /// sem som e sem mensagem de erro.
  static const _limiteCarga = Duration(seconds: 12);

  /// Tenta HLS; se falhar ou demorar, cai para o stream contínuo.
  ///
  /// O fallback não é preciosismo: redes corporativas e alguns provedores
  /// móveis bloqueiam `.m3u8` por inspeção de conteúdo, e sem o segundo
  /// caminho o app simplesmente não toca para esse ouvinte.
  Future<void> _carregarComFallback() async {
    final e = _emissora!;
    final hls = e.urlHls;

    if (hls != null) {
      try {
        await _player
            .setAudioSource(AudioSource.uri(Uri.parse(hls)))
            .timeout(_limiteCarga);
        _usandoFallback = false;
        _precisaCarregar = false;
        return;
      } catch (_) {
        // Cai para o stream contínuo logo abaixo.
      }
    }

    await _player
        .setAudioSource(AudioSource.uri(Uri.parse(e.urlStream)))
        .timeout(_limiteCarga);
    _usandoFallback = true;
    _precisaCarregar = false;
  }

  // ── Reconexão ──────────────────────────────────────────────────────────

  /// Recuo exponencial limitado a 30s.
  ///
  /// A cada segunda tentativa alterna o transporte: se o problema for o
  /// caminho (proxy bloqueando .m3u8, por exemplo), insistir no mesmo nunca
  /// recupera.
  void _agendarReconexao() {
    final e = _emissora;
    if (e == null) return;

    _reconexaoTimer?.cancel();
    _tentativasReconexao++;

    final segundos = (1 << (_tentativasReconexao.clamp(1, 5))).clamp(2, 30);
    _reconexaoTimer = Timer(Duration(seconds: segundos), () async {
      try {
        if (_tentativasReconexao.isEven && e.urlHls != null) {
          final url = _usandoFallback ? e.urlHls! : e.urlStream;
          await _player.setAudioSource(AudioSource.uri(Uri.parse(url)));
          _usandoFallback = !_usandoFallback;
          _precisaCarregar = false;
        } else {
          _precisaCarregar = true;
          await _carregarComFallback();
        }
        unawaited(_player.play());   // ver play(): não completa em stream ao vivo
        _tentativasReconexao = 0;
      } catch (erro) {
        _publicarErro(erro.toString());
        _agendarReconexao();
      }
    });
  }

  void _publicarErro(String msg) {
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.error,
      errorMessage: msg,
      controls: [MediaControl.play],
      playing: false,
    ));
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
