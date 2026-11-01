import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:windows_push/windows_push.dart';

/// Application (client) ID of your Entra app registration:
/// `flutter run --dart-define=WNS_REMOTE_ID=<GUID>`.
const remoteId = String.fromEnvironment('WNS_REMOTE_ID');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'windows_push example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _push = WindowsPush.instance;
  StreamSubscription<String>? _clicks;
  bool? _supported;
  String? _channelUri;
  String? _lastClick;

  @override
  void initState() {
    super.initState();
    // Listen first, then ask for the click that started the app: exactly one
    // of the two delivers it.
    _clicks = _push.onNotificationClick.listen(_onClick);
    _push.getInitialNotificationClick().then((argument) {
      if (argument != null) _onClick(argument);
    });
    _load();
  }

  Future<void> _load() async {
    final supported = await _push.isSupported();
    final uri = supported && remoteId.isNotEmpty
        ? await _push.getChannelUri(remoteId: remoteId)
        : null;
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _channelUri = uri;
    });
  }

  void _onClick(String argument) => setState(() => _lastClick = argument);

  @override
  void dispose() {
    _clicks?.cancel();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showToast() async {
    final ok = await _push.showToast(
      tag: 'now',
      title: 'Hello from windows_push',
      body: 'Click me to send this argument back to Dart.',
      argument: 'local:now',
    );
    if (!ok) _toast('Windows did not show the toast. Is the app packaged?');
  }

  Future<void> _scheduleToast() async {
    final ok = await _push.scheduleToast(
      tag: 'later',
      at: DateTime.now().add(const Duration(seconds: 10)),
      title: 'Ten seconds later',
      body: 'Close the app before it arrives, then click it.',
      argument: 'local:later',
    );
    _toast(ok ? 'Toast scheduled for 10 seconds from now.' : 'Not scheduled.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (_supported) {
      null => 'Checking…',
      false =>
        'Push is not available. Run the packaged MSIX build; '
            'a plain flutter run has no package identity.',
      true when remoteId.isEmpty =>
        'Push is available. Pass --dart-define=WNS_REMOTE_ID=<GUID> to get '
            'a channel.',
      true when _channelUri == null => 'Push is available, but no channel.',
      true => 'Push is available.',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('windows_push')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Status', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(status),
          if (_channelUri != null) ...[
            const SizedBox(height: 24),
            Text('Channel URI', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(_channelUri!),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _channelUri!));
                  _toast('Channel URI copied.');
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy channel URI'),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('Last click', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(_lastClick ?? 'No notification clicked yet.'),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: _showToast,
                child: const Text('Show a toast'),
              ),
              OutlinedButton(
                onPressed: _scheduleToast,
                child: const Text('Schedule one in 10 seconds'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
