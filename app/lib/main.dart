import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'audio_handler.dart';
import 'config.dart';
import 'schedule_page.dart';

late RadioAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'br.ufpb.radioportodocapim.audio',
      androidNotificationChannelName: 'Web Rádio Porto do Capim',
      // Mantém a notificação viva com o app em segundo plano: sem isso o
      // Android mata o processo e o áudio corta ao trocar de app.
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(const RadioApp());
}

class RadioApp extends StatelessWidget {
  const RadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Config.stationName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00695C),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

/// Casca com abas.
///
/// O app tem deliberadamente mais do que um botão de play. A diretriz 4.2
/// da App Store ("funcionalidade mínima") rejeita aplicativos que são só um
/// player embrulhado; grade de programação e informações da emissora são o
/// que sustenta a aprovação — e são úteis ao ouvinte de qualquer forma.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _aba = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _aba,
        children: const [PlayerPage(), SchedulePage(), AboutPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _aba,
        onDestinationSelected: (i) => setState(() => _aba = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.radio), label: 'Ao vivo'),
          NavigationDestination(icon: Icon(Icons.schedule), label: 'Programação'),
          NavigationDestination(icon: Icon(Icons.info_outline), label: 'Sobre'),
        ],
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Capa / metadados ──────────────────────────────────────
            StreamBuilder<MediaItem?>(
              stream: audioHandler.mediaItem,
              builder: (context, snap) {
                final item = snap.data;
                return Column(
                  children: [
                    Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: cs.surfaceContainerHighest,
                        image: item?.artUri != null
                            ? DecorationImage(
                                image: NetworkImage(item!.artUri.toString()),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: item?.artUri == null
                          ? Icon(Icons.radio, size: 88, color: cs.onSurfaceVariant)
                          : null,
                    ),
                    const SizedBox(height: 28),
                    Text(
                      item?.title ?? Config.stationName,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item?.artist ?? Config.stationSubtitle,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 36),

            // ── Controle ──────────────────────────────────────────────
            StreamBuilder<PlaybackState>(
              stream: audioHandler.playbackState,
              builder: (context, snap) {
                final state = snap.data;
                final tocando = state?.playing ?? false;
                final carregando =
                    state?.processingState == AudioProcessingState.loading ||
                        state?.processingState == AudioProcessingState.buffering;

                return Column(
                  children: [
                    SizedBox(
                      width: 84,
                      height: 84,
                      child: carregando
                          ? const Center(child: CircularProgressIndicator())
                          : IconButton.filled(
                              iconSize: 48,
                              onPressed: () => tocando
                                  ? audioHandler.stop()
                                  : audioHandler.play(),
                              icon: Icon(tocando ? Icons.stop : Icons.play_arrow),
                            ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: tocando ? Colors.redAccent : cs.outline,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          carregando
                              ? 'Conectando…'
                              : tocando
                                  ? 'AO VIVO'
                                  : 'Fora do ar',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(Config.stationName,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(Config.stationSubtitle,
              style: Theme.of(context).textTheme.bodyLarge),
          const Divider(height: 40),
          const ListTile(
            leading: Icon(Icons.graphic_eq),
            title: Text('Qualidade de transmissão'),
            subtitle: Text('128 kbps · HLS e MP3'),
          ),
          const ListTile(
            leading: Icon(Icons.language),
            title: Text('Ouça pelo navegador'),
            subtitle: Text('https://${Config.host}'),
          ),
        ],
      ),
    );
  }
}
