// Adds the Windows App SDK push entries to a generated AppxManifest.xml.
//
//   dart run windows_push:patch_manifest --remote-id=<GUID> [--runtime=2]
//       [--manifest=<path>] [--toast-clsid=<GUID>] [--runtime-version=<v>]
//       [--display-name=<name>]
//
// With the msix package, run it between `dart run msix:build` and
// `dart run msix:pack`.
import 'dart:io';

import 'package:windows_push/src/manifest_patcher.dart';

const _defaultManifest = 'build/windows/x64/runner/Release/AppxManifest.xml';

const _usage =
    '''
Usage: dart run windows_push:patch_manifest --remote-id=<GUID> [options]

  --remote-id=<GUID>        Application (client) ID of your Entra app
                            registration (required)
  --runtime=<major>         Depend on the Windows App Runtime framework,
                            e.g. 2. Omit when you ship it self-contained.
  --runtime-version=<v>     MinVersion of that dependency
                            (default ${ManifestPatch.defaultRuntimeMinVersion} for runtime 2)
  --toast-clsid=<GUID>      Toast activator CLSID. Default: derived from the
                            package name. Must never change once shipped.
  --display-name=<name>     Name of the COM servers (default: the package's)
  --manifest=<path>         Default: $_defaultManifest
''';

void main(List<String> args) {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  final remoteId = _arg(args, 'remote-id');
  if (remoteId == null) {
    stderr.write(_usage);
    exit(64);
  }
  final path = _arg(args, 'manifest') ?? _defaultManifest;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
      'No manifest at $path. With the msix package, run '
      '`dart run msix:build` first.',
    );
    exit(66);
  }

  final PatchResult result;
  try {
    result = patchManifest(
      file.readAsStringSync(),
      ManifestPatch(
        remoteId: remoteId,
        toastClsid: _arg(args, 'toast-clsid'),
        runtime: _arg(args, 'runtime'),
        runtimeMinVersion: _arg(args, 'runtime-version'),
        displayName: _arg(args, 'display-name'),
      ),
    );
  } on ManifestPatchException catch (e) {
    stderr.writeln('Cannot patch $path: $e');
    exit(65);
  }

  if (result.changes.isEmpty) {
    stdout.writeln('$path is already patched, nothing to do.');
    return;
  }
  file.writeAsStringSync(result.xml);
  stdout.writeln('Patched $path:');
  for (final change in result.changes) {
    stdout.writeln('  $change');
  }
}

String? _arg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}
