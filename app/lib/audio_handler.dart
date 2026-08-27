import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// Handler de áudio que roda em segundo plano.
///
/// Responsável por três coisas que o edital exige na alínea (h) e que a loja
/// da Apple exige para aprovar o app:
///   1. o áudio continua com a tela bloqueada;
///   2. os controles aparecem na tela de bloqueio / Central de Controle;
///   3. o título da música corrente acompanha o que está no ar.
class RadioAudioHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  Timer? _metadataTimer;

  /// Rádio ao vivo não tem "posição": o ouvinte entra no meio. Por isso
  /// nunca expomos seek nem duração — expor levaria a uma barra de progresso
  /// mentirosa, que é motivo recorrente de rejeição na App Store.
  RadioAudioHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _setInitialMediaItem();
  }

  void _setInitialMediaItem() {
    mediaItem.add(const MediaItem(
      id: Config.streamHls,
      title: Config.stationName,
      artist: Config.stationSubtitle,
      isLive: true,
      // duration nulo == transmissão contínua
    ));
  }

  @override
  Future<void> play() async {
    if (_player.audioSource == null) {
      await _carregarComFallback();
    }
    _iniciarAtualizacaoDeMetadados();
    await _player.play();
  }

  @override
  Future<void> stop() async {
    _metadataTimer?.cancel();
    await _player.stop();
    // Descarta a fonte: ao voltar a tocar queremos o AO VIVO de agora,
    // não retomar do ponto em que o buffer parou minutos atrás.
    await _player.setAudioSource(ConcatenatingAudioSource(children: []),
        preload: false);
    _player.dispose;
    await super.stop();
  }

  @override
  Future<void> pause() => stop(); // numa rádio ao vivo, pausar é parar

  /// Tenta HLS; se falhar, cai para ICY/MP3.
  ///
  /// O fallback não é preciosismo: redes corporativas e alguns provedores
  /// móveis bloqueiam `.m3u8` por inspeção de conteúdo, e sem o segundo
  /// caminho o app simplesmente não toca para esse ouvinte.
  Future<void> _carregarComFallback() async {
    try {
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(Config.streamHls),
            tag: mediaItem.value),
      );
    } catch (_) {
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(Config.streamIcy),
            tag: mediaItem.value),
      );
    }
  }

  void _iniciarAtualizacaoDeMetadados() {
    _metadataTimer?.cancel();
    _atualizarMetadados();
    _metadataTimer =
        Timer.periodic(Config.nowPlayingInterval, (_) => _atualizarMetadados());
  }

  Future<void> _atualizarMetadados() async {
    try {
      final r = await http
          .get(Uri.parse(Config.nowPlayingApi))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final song = data['now_playing']?['song'] as Map<String, dynamic>?;
      if (song == null) return;

      final art = song['art'] as String?;
      mediaItem.add(MediaItem(
        id: Config.streamHls,
        title: (song['title'] as String?)?.isNotEmpty == true
            ? song['title'] as String
            : Config.stationName,
        artist: (song['artist'] as String?)?.isNotEmpty == true
            ? song['artist'] as String
            : Config.stationSubtitle,
        album: Config.stationName,
        artUri: (art != null && art.isNotEmpty) ? Uri.tryParse(art) : null,
        isLive: true,
      ));
    } catch (_) {
      // Falha de metadado NUNCA pode derrubar a reprodução: o ouvinte
      // prefere ouvir sem saber o nome da música a ficar sem áudio.
    }
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        if (_player.playing) MediaControl.stop else MediaControl.play,
      ],
      systemActions: const {MediaAction.stop},
      androidCompactActionIndices: const [0],
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
    );
  }
}
