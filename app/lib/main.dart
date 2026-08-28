import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'audio_handler.dart';
import 'config.dart';
import 'emissora.dart';
import 'preferencias.dart';
import 'schedule_page.dart';
import 'selecao_page.dart';

late RadioAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  audioHandler = await AudioService.init(
    builder: () => RadioAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'br.net.onebit.bitradio.audio',
      androidNotificationChannelName: 'BitRádio',
      // Mantém a notificação viva com o app em segundo plano: sem isso o
      // Android mata o processo e o áudio corta ao trocar de app.
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(const BitRadioApp());
}

class BitRadioApp extends StatelessWidget {
  const BitRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Config.appNome,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF12897A),   // mesma cor do ícone e do player web
          brightness: Brightness.dark,
        ),
      ),
      home: const Roteador(),
    );
  }
}

/// Decide a primeira tela: seleção (primeira abertura) ou player.
class Roteador extends StatefulWidget {
  const Roteador({super.key});
  @override
  State<Roteador> createState() => _RoteadorState();
}

class _RoteadorState extends State<Roteador> {
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  Future<void> _iniciar() async {
    // Carrega do disco, não da rede: sem isso o app abriria numa tela de
    // erro quando o ouvinte estivesse sem conexão, em vez de tentar tocar.
    final salva = await Preferencias.emissoraSalva();
    if (salva != null) {
      await audioHandler.trocarEmissora(salva);
    }
    if (mounted) setState(() => _carregando = false);
  }

  Future<void> _abrirSelecao({bool podeVoltar = false}) async {
    final escolhida = await Navigator.of(context).push<Emissora>(
      MaterialPageRoute(builder: (_) => SelecaoPage(podeVoltar: podeVoltar)),
    );
    if (escolhida != null) {
      await audioHandler.trocarEmissora(escolhida);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_carregando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (audioHandler.emissora == null) {
      return _PrimeiraAbertura(aoEscolher: () => _abrirSelecao());
    }
    return HomeShell(aoTrocarEmissora: () => _abrirSelecao(podeVoltar: true));
  }
}

/// Tela de boas-vindas da primeira abertura.
class _PrimeiraAbertura extends StatelessWidget {
  final VoidCallback aoEscolher;
  const _PrimeiraAbertura({required this.aoEscolher});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.podcasts, size: 88, color: cs.primary),
              const SizedBox(height: 24),
              Text(Config.appNome,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Rádios ao vivo, direto do seu aparelho.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: aoEscolher,
                icon: const Icon(Icons.search),
                label: const Text('Escolher emissora'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Casca com abas.
///
/// O app tem deliberadamente mais do que um botão de play. A diretriz 4.2 da
/// App Store ("funcionalidade mínima") rejeita aplicativos que são só um
/// player embrulhado; grade de programação e informações da emissora são o
/// que sustenta a aprovação — e são úteis ao ouvinte de qualquer forma.
class HomeShell extends StatefulWidget {
  final VoidCallback aoTrocarEmissora;
  const HomeShell({super.key, required this.aoTrocarEmissora});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _aba = 0;

  @override
  Widget build(BuildContext context) {
    final e = audioHandler.emissora!;
    return Scaffold(
      appBar: AppBar(
        title: Text(e.nome, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Trocar de emissora',
            icon: const Icon(Icons.swap_horiz),
            onPressed: widget.aoTrocarEmissora,
          ),
        ],
      ),
      body: IndexedStack(
        index: _aba,
        children: [
          const PlayerPage(),
          SchedulePage(emissora: e),
          const AboutPage(),
        ],
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
                      item?.title ?? '—',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item?.artist ?? '',
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 36),

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
                              // pause() e não stop(): mantém a sessão de mídia
                              // viva, para o botão do fone e do carro
                              // continuarem funcionando depois de parar.
                              onPressed: () => tocando
                                  ? audioHandler.pause()
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
    final e = audioHandler.emissora;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(e?.nome ?? Config.appNome,
              style: Theme.of(context).textTheme.headlineSmall),
          if (e != null && e.descricao.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(e.descricao, style: Theme.of(context).textTheme.bodyLarge),
          ],
          const Divider(height: 40),
          const ListTile(
            leading: Icon(Icons.graphic_eq),
            title: Text('Qualidade de transmissão'),
            subtitle: Text('128 kbps ou superior · HLS e MP3'),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Política de privacidade'),
            subtitle: Text(Config.politicaPrivacidade),
          ),
          const ListTile(
            leading: Icon(Icons.mail_outline),
            title: Text('Contato'),
            subtitle: Text(Config.contato),
          ),
        ],
      ),
    );
  }
}
