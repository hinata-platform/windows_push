import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:windows_push/windows_push.dart';

const _remoteId = '33fa840e-5c3b-4cc0-8308-227acbecdf0d';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('windows_push_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late WindowsPush push;
  Object? Function(MethodCall call) answer = (_) => null;

  setUp(() {
    calls = [];
    answer = (_) => null;
    push = WindowsPush.withChannel(channel);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('getChannelUri', () {
    test('passes the remote id and returns a WNS URI', () async {
      const uri = 'https://wns2-par02p.notify.windows.com/w/?token=abc';
      answer = (_) => uri;
      expect(await push.getChannelUri(remoteId: _remoteId), uri);
      expect(calls.single.method, 'getChannelUri');
      expect(calls.single.arguments, {'remoteId': _remoteId});
    });

    test('drops a URI that is not on notify.windows.com', () async {
      answer = (_) => 'https://evil.example.com/w/';
      expect(await push.getChannelUri(remoteId: _remoteId), isNull);
      answer = (_) => 'http://wns.notify.windows.com/w/';
      expect(await push.getChannelUri(remoteId: _remoteId), isNull);
    });

    test('reads null and errors as unavailable', () async {
      expect(await push.getChannelUri(remoteId: _remoteId), isNull);
      answer = (_) => throw PlatformException(code: 'x');
      expect(await push.getChannelUri(remoteId: _remoteId), isNull);
    });

    test('rejects a remote id that is not a GUID', () {
      expect(
        () => push.getChannelUri(remoteId: 'client-id'),
        throwsArgumentError,
      );
    });

    test('does nothing off Windows', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(await push.getChannelUri(remoteId: _remoteId), isNull);
      expect(await push.isSupported(), isFalse);
      expect(calls, isEmpty);
    });
  });

  group('clicks', () {
    test(
      'a click while running reaches listeners and is acknowledged',
      () async {
        final clicks = <String>[];
        final subscription = push.onNotificationClick.listen(clicks.add);
        final reply = await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('onNotificationClick', '/issues/HIN-25'),
          ),
          null,
        );
        await Future<void>.delayed(Duration.zero);
        expect(clicks, ['/issues/HIN-25']);
        // A success envelope is what lets the native side clear its buffer.
        expect(channel.codec.decodeEnvelope(reply!), isNull);
        await subscription.cancel();
      },
    );

    test('nobody listening leaves the click unacknowledged', () async {
      final subscription = push.onNotificationClick.listen((_) {});
      await subscription.cancel();
      final reply = await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('onNotificationClick', '/x'),
        ),
        null,
      );
      expect(reply, isNull, reason: 'no handler answers NotImplemented');
    });

    test('the initial click is read once', () async {
      answer = (_) => '/time/focus';
      expect(await push.getInitialNotificationClick(), '/time/focus');
      answer = (_) => null;
      expect(await push.getInitialNotificationClick(), isNull);
    });
  });

  group('toasts', () {
    test('schedules with UTC epoch milliseconds and minutes', () async {
      answer = (_) => true;
      final at = DateTime.utc(2026, 11, 1, 12);
      final ok = await push.scheduleToast(
        tag: 'focus',
        at: at,
        title: 'Done',
        body: 'Focus ended',
        argument: '/time/focus',
        group: 'timer',
        expiresAfter: const Duration(minutes: 5),
      );
      expect(ok, isTrue);
      expect(calls.single.method, 'scheduleToast');
      expect(calls.single.arguments, {
        'tag': 'focus',
        'group': 'timer',
        'at': at.millisecondsSinceEpoch,
        'title': 'Done',
        'body': 'Focus ended',
        'argument': '/time/focus',
        'expireMinutes': 5,
      });
    });

    test('shows in the default group and reports a refusal', () async {
      answer = (_) => false;
      expect(await push.showToast(tag: 't', title: 'Hi'), isFalse);
      expect(
        (calls.single.arguments as Map)['group'],
        WindowsPush.defaultGroup,
      );
    });

    test('rejects a tag Windows would refuse', () {
      expect(() => push.showToast(tag: '', title: 'x'), throwsArgumentError);
      expect(
        () => push.showToast(tag: 'x' * 65, title: 'x'),
        throwsArgumentError,
      );
    });

    test('cancels by tag and group', () async {
      await push.cancelToast('focus', group: 'timer');
      expect(calls.single.arguments, {'tag': 'focus', 'group': 'timer'});
    });
  });

  test('isWnsChannelUri', () {
    expect(isWnsChannelUri('https://a.notify.windows.com/w'), isTrue);
    expect(isWnsChannelUri('https://notify.windows.com.evil.com/w'), isFalse);
    expect(isWnsChannelUri('not a uri'), isFalse);
  });
}
