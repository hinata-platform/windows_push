/// Windows push notifications (WNS) for Flutter.
///
/// `firebase_messaging` has no Windows implementation, so a Windows app
/// registers a WNS *channel URI* with its server where the other platforms
/// register an FCM token. This package mints that URI, routes the argument of
/// a clicked notification to Dart whether the click found the app running or
/// started it, and shows or schedules local toasts that click the same way.
///
/// Everything degrades to `null` or `false` instead of throwing: WNS needs
/// package identity, so a plain `flutter run` legitimately has no channel, and
/// off Windows there is nothing to do at all.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Entry point of the plugin. Use [WindowsPush.instance].
class WindowsPush {
  /// Creates an instance on [channel]. Apps use [instance]; tests can pass a
  /// channel of their own.
  @visibleForTesting
  WindowsPush.withChannel(this._channel);

  WindowsPush._() : _channel = const MethodChannel('windows_push');

  /// The shared instance.
  static final WindowsPush instance = WindowsPush._();

  final MethodChannel _channel;

  StreamController<String>? _clicks;

  bool get _onWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Whether this build can receive pushes: Windows, package identity and a
  /// Windows App Runtime that supports push.
  Future<bool> isSupported() async {
    if (!_onWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The device's channel URI, or `null` when push is unavailable here.
  ///
  /// [remoteId] is the Application (client) ID of the Entra app registration
  /// your server authenticates with; WNS refuses any other. Channels expire
  /// after 30 days and Windows rotates them, so ask on every start and send the
  /// result to your server instead of caching it.
  ///
  /// Only an `https://*.notify.windows.com` URI is returned. Anything else is
  /// treated as unavailable, because a server must never push elsewhere.
  Future<String?> getChannelUri({required String remoteId}) async {
    if (!isGuid(remoteId)) {
      throw ArgumentError.value(remoteId, 'remoteId', 'is not a GUID');
    }
    if (!_onWindows) return null;
    try {
      final uri = await _channel.invokeMethod<String>('getChannelUri', {
        'remoteId': remoteId,
      });
      if (uri == null || uri.isEmpty) return null;
      return isWnsChannelUri(uri) ? uri : null;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('windows_push: channel unavailable (${e.code})');
      return null;
    }
  }

  /// The arguments of notifications clicked while the app runs.
  ///
  /// The argument is the toast's `launch` attribute, as your server or
  /// [showToast] set it. A click that *started* the app is not on this stream
  /// but answered once by [getInitialNotificationClick]; listen first, then
  /// ask for the initial click, and exactly one of the two delivers it.
  Stream<String> get onNotificationClick {
    _clicks ??= StreamController<String>.broadcast(
      onListen: () => _channel.setMethodCallHandler(_handleCall),
      // Without a handler the native side keeps a click buffered, so nothing
      // is lost while nobody listens.
      onCancel: () => _channel.setMethodCallHandler(null),
    );
    return _clicks!.stream;
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method == 'onNotificationClick') {
      final argument = call.arguments;
      if (argument is String && argument.isNotEmpty) {
        _clicks?.add(argument);
      }
      return null;
    }
    throw MissingPluginException();
  }

  /// The argument of the notification whose click started the app, if any.
  ///
  /// Answers once: the argument is removed when it is read.
  Future<String?> getInitialNotificationClick() async {
    if (!_onWindows) return null;
    try {
      final argument = await _channel.invokeMethod<String>(
        'getInitialNotificationClick',
      );
      return argument == null || argument.isEmpty ? null : argument;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Shows a local toast right away.
  ///
  /// [tag] and [group] identify it: showing another toast with both replaces
  /// it, and [cancelToast] removes it. Clicking it delivers [argument] like a
  /// push. The toast leaves Action Center after [expiresAfter]. Returns false
  /// off Windows, without package identity, or when Windows refused.
  Future<bool> showToast({
    required String tag,
    required String title,
    String body = '',
    String argument = '',
    String group = defaultGroup,
    Duration expiresAfter = const Duration(minutes: 10),
  }) {
    return _invokeToast('showToast', {
      'tag': _checkedTag(tag),
      'group': group,
      'title': title,
      'body': body,
      'argument': argument,
      'expireMinutes': _minutes(expiresAfter),
    });
  }

  /// Schedules a local toast for [at]; same contract as [showToast].
  ///
  /// Replaces a pending toast with the same [tag] and [group]. A moment that
  /// already passed shows the toast at once, unless it would have expired.
  Future<bool> scheduleToast({
    required String tag,
    required DateTime at,
    required String title,
    String body = '',
    String argument = '',
    String group = defaultGroup,
    Duration expiresAfter = const Duration(minutes: 10),
  }) {
    return _invokeToast('scheduleToast', {
      'tag': _checkedTag(tag),
      'group': group,
      'at': at.toUtc().millisecondsSinceEpoch,
      'title': title,
      'body': body,
      'argument': argument,
      'expireMinutes': _minutes(expiresAfter),
    });
  }

  /// Removes the toast [tag] in [group], whether still scheduled or shown.
  Future<void> cancelToast(String tag, {String group = defaultGroup}) async {
    if (!_onWindows) return;
    try {
      await _channel.invokeMethod<void>('cancelToast', {
        'tag': tag,
        'group': group,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<bool> _invokeToast(String method, Map<String, Object> args) async {
    if (!_onWindows) return false;
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The group local toasts use unless told otherwise.
  static const String defaultGroup = 'windows_push';

  static String _checkedTag(String tag) {
    // Windows caps tags at 64 characters.
    if (tag.isEmpty || tag.length > 64) {
      throw ArgumentError.value(tag, 'tag', 'must be 1 to 64 characters');
    }
    return tag;
  }

  static int _minutes(Duration duration) =>
      duration.inMinutes < 1 ? 1 : duration.inMinutes;
}

/// Whether [value] is a GUID in the `8-4-4-4-12` form.
@visibleForTesting
bool isGuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);

/// Whether [uri] is a channel a server may push to: HTTPS on a host under
/// `notify.windows.com`, as WNS requires.
@visibleForTesting
bool isWnsChannelUri(String uri) {
  final parsed = Uri.tryParse(uri);
  return parsed != null &&
      parsed.scheme == 'https' &&
      parsed.host.endsWith('.notify.windows.com');
}
