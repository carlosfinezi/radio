# Regras de minificação do BitRádio.
#
# POR QUE ESTE ARQUIVO EXISTE:
# Com R8 ligado e sem estas regras, o ExoPlayer/media3 quebrava em tempo de
# execução com um NullPointerException engolido como "(2) Unexpected runtime
# error". O app abria, dizia AO VIVO e não emitia som nenhum — em QUALQUER
# transporte, MP3 contínuo ou HLS, e antes mesmo de abrir conexão de rede.
#
# O stack, capturado por logcat em emulador Android 11:
#
#   E/ExoPlayerImplInternal: Playback error
#     X.n: Unexpected runtime error
#         at X.N.handleMessage(SourceFile:309)
#   Caused by: java.lang.NullPointerException
#         at C1.c.f(Unknown Source:1)
#         at X.U.h(SourceFile:241)
#
# Compilando com isMinifyEnabled = false o erro desaparece e sai som —
# AudioTrack ativo a 44100 Hz estéreo, MediaSession em state=3 (PLAYING).
# Isso isolou o R8 como causa. Não foi remoção de classe: Mp3Extractor,
# ProgressiveMediaPeriod, DefaultAudioSink, MediaCodecAudioRenderer e
# ExoPlayerImpl estavam todos no dex do build quebrado. É a REESCRITA/
# otimização do R8 sobre o media3 que produz o null.
#
# Manter o media3 inteiro custa poucas centenas de KB e devolve a
# minificação a todo o resto do app.
-keep class androidx.media3.** { *; }
-keep interface androidx.media3.** { *; }
-dontwarn androidx.media3.**

# O DefaultMediaSourceFactory instancia estas três por REFLEXÃO, a partir do
# nome completo em string. Renomeá-las faz o Class.forName falhar e o
# transporte correspondente simplesmente deixar de existir, sem erro visível.
-keep class androidx.media3.exoplayer.hls.HlsMediaSource$Factory { *; }
-keep class androidx.media3.exoplayer.dash.DashMediaSource$Factory { *; }
-keep class androidx.media3.exoplayer.smoothstreaming.SsMediaSource$Factory { *; }

# Plugins de áudio: o registro passa por reflexão no GeneratedPluginRegistrant
# e a ponte de plataforma resolve métodos por nome.
-keep class com.ryanheise.** { *; }
-dontwarn com.ryanheise.**
