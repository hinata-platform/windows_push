import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What the patcher adds to an AppxManifest.xml.
class ManifestPatch {
  /// Creates a patch.
  const ManifestPatch({
    required this.remoteId,
    this.toastClsid,
    this.runtime,
    this.runtimeMinVersion,
    this.displayName,
  });

  /// Application (client) ID of the Entra app registration. WNS starts the
  /// app through a COM server with this class id when a push arrives while it
  /// is closed.
  final String remoteId;

  /// CLSID the shell activates when a toast is clicked. Derived from the
  /// package name when null; see [deriveToastClsid].
  final String? toastClsid;

  /// Major version of the Windows App Runtime framework to depend on, such
  /// as `2`. Null for an app that ships the runtime self-contained.
  final String? runtime;

  /// MinVersion of that dependency. Defaults to [defaultRuntimeMinVersion]
  /// for runtime 2 and is required for any other.
  final String? runtimeMinVersion;

  /// Name shown for the COM servers. Defaults to the manifest's display name.
  final String? displayName;

  /// The Windows App Runtime 2 this package was built and tested against.
  static const String defaultRuntimeMinVersion = '2.3.1.0';
}

/// The outcome of [patchManifest].
class PatchResult {
  /// Creates a result.
  const PatchResult(this.xml, this.changes, this.toastClsid);

  /// The manifest after patching.
  final String xml;

  /// One line per change; empty when the manifest was already patched.
  final List<String> changes;

  /// The toast activator CLSID in use.
  final String toastClsid;
}

/// Thrown when the manifest cannot be patched.
class ManifestPatchException implements Exception {
  /// Creates the exception.
  const ManifestPatchException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => message;
}

const _comNamespace =
    'http://schemas.microsoft.com/appx/manifest/com/windows10';
const _desktopNamespace =
    'http://schemas.microsoft.com/appx/manifest/desktop/windows10';
const _runtimePublisher =
    'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, '
    'S=Washington, C=US';

final _guid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Adds what Windows App SDK push needs to a packaged app's manifest.
///
/// The `msix` package renders AppxManifest.xml from its own template and has
/// no hook for extra elements, but it splits `msix:build` from `msix:pack`, so
/// the generated manifest can be patched in between. Any other packaging flow
/// works the same way, as long as it runs before makeappx seals the package.
///
/// Three additions:
///
///  1. A COM server with `----WindowsAppRuntimePushServer:` whose class id is
///     the remote id. WNS uses it to start the app to deliver a push.
///  2. `windows.toastNotificationActivation` plus a second COM server with
///     `----AppNotificationActivated:` and the same CLSID. This is how the
///     shell finds the app when a toast is clicked; registering in code alone
///     does not do it.
///  3. The Windows App Runtime framework dependency, unless self-contained.
///
/// Idempotent: patching a patched manifest changes nothing.
PatchResult patchManifest(String xml, ManifestPatch patch) {
  if (!_guid.hasMatch(patch.remoteId)) {
    throw ManifestPatchException(
      'remote id "${patch.remoteId}" is not a GUID. Use the Application '
      '(client) ID of the Entra app registration.',
    );
  }
  final clsid = patch.toastClsid ?? deriveToastClsid(_identityName(xml));
  if (!_guid.hasMatch(clsid)) {
    throw ManifestPatchException('toast CLSID "$clsid" is not a GUID.');
  }
  final changes = <String>[];

  for (final (prefix, uri) in [
    ('com', _comNamespace),
    ('desktop', _desktopNamespace),
  ]) {
    if (!xml.contains('xmlns:$prefix=')) {
      xml = xml.replaceFirstMapped(
        RegExp(r'<Package(\s)'),
        (m) => '<Package xmlns:$prefix="$uri"${m[1]}',
      );
      changes.add('namespace $prefix');
    }
    final ignorable = RegExp(r'IgnorableNamespaces="([^"]*)"').firstMatch(xml);
    if (ignorable != null && !ignorable.group(1)!.split(' ').contains(prefix)) {
      xml = xml.replaceFirst(
        ignorable.group(0)!,
        'IgnorableNamespaces="${'${ignorable.group(1)} $prefix'.trim()}"',
      );
    }
  }

  if (!xml.contains('----WindowsAppRuntimePushServer:')) {
    if (xml.contains('windows.toastNotificationActivation')) {
      // The msix package's own toast_activator option starts the app with
      // its own arguments, which the Windows App SDK never sees.
      throw const ManifestPatchException(
        'the manifest already declares a toast activator. Remove '
        '`toast_activator` from msix_config; this tool adds the one the '
        'Windows App SDK needs.',
      );
    }
    final application = RegExp(
      r'<Application\s[^>]*Executable="([^"]+)"[^>]*>',
    ).firstMatch(xml);
    if (application == null) {
      throw const ManifestPatchException(
        'no <Application> element with an Executable attribute.',
      );
    }
    final executable = application.group(1)!;
    final name = _escape(patch.displayName ?? _displayName(xml) ?? 'App');
    final entries =
        '''
          <com:Extension Category="windows.comServer">
            <com:ComServer>
              <com:ExeServer Executable="$executable" DisplayName="$name"
                Arguments="----WindowsAppRuntimePushServer:">
                <com:Class Id="${patch.remoteId}" DisplayName="$name push" />
              </com:ExeServer>
            </com:ComServer>
          </com:Extension>
          <desktop:Extension Category="windows.toastNotificationActivation">
            <desktop:ToastNotificationActivation ToastActivatorCLSID="$clsid" />
          </desktop:Extension>
          <com:Extension Category="windows.comServer">
            <com:ComServer>
              <com:ExeServer Executable="$executable" DisplayName="$name"
                Arguments="----AppNotificationActivated:">
                <com:Class Id="$clsid" DisplayName="$name notifications" />
              </com:ExeServer>
            </com:ComServer>
          </com:Extension>
''';
    final start = application.start;
    final end = xml.indexOf('</Application>', start);
    if (end < 0) {
      throw const ManifestPatchException('<Application> is never closed.');
    }
    final body = xml.substring(start, end);
    final existing = body.lastIndexOf('</Extensions>');
    if (existing >= 0) {
      // An <Application> holds at most one <Extensions>; join it.
      final at = start + existing;
      xml = '${xml.substring(0, at)}$entries        ${xml.substring(at)}';
    } else {
      xml =
          '${xml.substring(0, end)}  <Extensions>\n$entries        '
          '</Extensions>\n      ${xml.substring(end)}';
    }
    changes
      ..add('push activator class id: ${patch.remoteId}')
      ..add('toast activator CLSID  : $clsid');
  }

  final runtime = patch.runtime;
  if (runtime != null && !xml.contains('Microsoft.WindowsAppRuntime.')) {
    final minVersion =
        patch.runtimeMinVersion ??
        (runtime == '2' ? ManifestPatch.defaultRuntimeMinVersion : null);
    if (minVersion == null || minVersion == '0.0.0.0') {
      // The Store rejects 0.0.0.0, and a guessed version for a runtime this
      // package was never tested with helps nobody.
      throw ManifestPatchException(
        'runtime $runtime needs an explicit, real --runtime-version.',
      );
    }
    if (!xml.contains('</Dependencies>')) {
      throw const ManifestPatchException('no <Dependencies> element.');
    }
    // Appended, never prepended: the schema fixes TargetDeviceFamily first and
    // PackageDependency after, and makeappx rejects the other order with
    // 0x80080204.
    xml = xml.replaceFirst(
      '</Dependencies>',
      '  <PackageDependency Name="Microsoft.WindowsAppRuntime.$runtime" '
          'MinVersion="$minVersion" Publisher="$_runtimePublisher" />\n'
          '    </Dependencies>',
    );
    changes.add(
      'framework dependency   : Microsoft.WindowsAppRuntime.$runtime '
      '>= $minVersion',
    );
  }

  return PatchResult(xml, changes, clsid);
}

/// A stable toast activator CLSID for the package [identityName]: a name-based
/// UUID (version 5) in a namespace of this package.
///
/// It MUST stay the same for the lifetime of the app. The shell finds the COM
/// server for an already delivered toast by it, so changing it breaks every
/// toast the user has not clicked yet.
String deriveToastClsid(String identityName) {
  final digest = sha1.convert([
    ..._namespaceBytes,
    ...utf8.encode(identityName),
  ]);
  final bytes = digest.bytes.sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
          '${hex.substring(20)}'
      .toUpperCase();
}

// Namespace UUID of windows_push toast activators,
// 6f2b8c1e-4d3a-5b7f-9e21-0c8d4a6b3f15.
const _namespaceBytes = [
  0x6f, 0x2b, 0x8c, 0x1e, 0x4d, 0x3a, 0x5b, 0x7f, //
  0x9e, 0x21, 0x0c, 0x8d, 0x4a, 0x6b, 0x3f, 0x15,
];

String _identityName(String xml) {
  final match = RegExp(r'<Identity\s[^>]*Name="([^"]+)"').firstMatch(xml);
  if (match == null) {
    throw const ManifestPatchException(
      'no <Identity Name="…">; pass --toast-clsid instead.',
    );
  }
  return match.group(1)!;
}

String? _displayName(String xml) =>
    RegExp(r'<DisplayName>([^<]+)</DisplayName>').firstMatch(xml)?.group(1);

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');
