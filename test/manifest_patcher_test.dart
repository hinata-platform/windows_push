import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:windows_push/src/manifest_patcher.dart';

const _appId = 'e89a5a67-af01-4c79-98a7-09e609f0c831';
const _clsid = 'C2EC5161-3E44-44EC-97FF-90DC93713ADF';

void main() {
  final manifest = File('test/fixtures/msix_manifest.xml').readAsStringSync();

  test('adds both activators with the same toast CLSID', () {
    final result = patchManifest(
      manifest,
      const ManifestPatch(appId: _appId, toastClsid: _clsid),
    );
    final xml = result.xml;
    expect(xml, contains('Arguments="----WindowsAppRuntimePushServer:"'));
    expect(xml, contains('<com:Class Id="$_appId"'));
    expect(xml, contains('ToastActivatorCLSID="$_clsid"'));
    expect(xml, contains('Arguments="----AppNotificationActivated:"'));
    expect(xml, contains('<com:Class Id="$_clsid"'));
    expect(xml, contains('Executable="windows_push_example.exe"'));
    expect(xml, contains('DisplayName="Push Example push"'));
    expect(
      RegExp('<Extensions>').allMatches(xml),
      hasLength(1),
      reason: 'an <Application> holds one <Extensions>',
    );
    expect(
      xml.indexOf('</Extensions>'),
      lessThan(xml.indexOf('</Application>')),
    );
  });

  test('joins an <Extensions> the manifest already has', () {
    final withAlias = manifest.replaceFirst(
      '</Application>',
      '<Extensions><uap3:Extension Category="windows.appExecutionAlias" />'
          '</Extensions>\n      </Application>',
    );
    final xml = patchManifest(
      withAlias,
      const ManifestPatch(appId: _appId),
    ).xml;
    expect(RegExp('<Extensions>').allMatches(xml), hasLength(1));
    expect(xml, contains('windows.appExecutionAlias'));
    expect(xml, contains('----AppNotificationActivated:'));
  });

  test('appends the runtime dependency after TargetDeviceFamily', () {
    final xml = patchManifest(
      manifest,
      const ManifestPatch(appId: _appId, runtime: '2'),
    ).xml;
    final family = xml.indexOf('<TargetDeviceFamily');
    final dependency = xml.indexOf(
      '<PackageDependency Name="Microsoft.WindowsAppRuntime.2" '
      'MinVersion="2.3.1.0"',
    );
    expect(dependency, greaterThan(family));
  });

  test('refuses a runtime without a known MinVersion', () {
    expect(
      () => patchManifest(
        manifest,
        const ManifestPatch(appId: _appId, runtime: '3'),
      ),
      throwsA(isA<ManifestPatchException>()),
    );
    expect(
      () => patchManifest(
        manifest,
        const ManifestPatch(
          appId: _appId,
          runtime: '2',
          runtimeMinVersion: '0.0.0.0',
        ),
      ),
      throwsA(isA<ManifestPatchException>()),
    );
  });

  test('leaves out the dependency when self-contained', () {
    final xml = patchManifest(manifest, const ManifestPatch(appId: _appId)).xml;
    expect(xml, isNot(contains('Microsoft.WindowsAppRuntime')));
  });

  test('is idempotent', () {
    const patch = ManifestPatch(appId: _appId, runtime: '2');
    final once = patchManifest(manifest, patch);
    final twice = patchManifest(once.xml, patch);
    expect(twice.changes, isEmpty);
    expect(twice.xml, once.xml);
  });

  test('declares missing namespaces', () {
    final bare = manifest
        .replaceFirst(
          'xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"',
          '',
        )
        .replaceFirst(
          'xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/windows10"',
          '',
        );
    final xml = patchManifest(bare, const ManifestPatch(appId: _appId)).xml;
    expect(xml, contains('xmlns:com='));
    expect(xml, contains('xmlns:desktop='));
    expect(xml, contains('IgnorableNamespaces="uap3 desktop com"'));
  });

  test('rejects a msix toast_activator', () {
    final withToast = manifest.replaceFirst(
      '</Application>',
      '<Extensions><desktop:Extension '
          'Category="windows.toastNotificationActivation" /></Extensions>'
          '</Application>',
    );
    expect(
      () => patchManifest(withToast, const ManifestPatch(appId: _appId)),
      throwsA(isA<ManifestPatchException>()),
    );
  });

  test('rejects a app id that is not a GUID', () {
    expect(
      () => patchManifest(manifest, const ManifestPatch(appId: 'nope')),
      throwsA(isA<ManifestPatchException>()),
    );
  });

  test('derives a stable version 5 CLSID from the package name', () {
    final a = deriveToastClsid('example.windowspush');
    expect(a, deriveToastClsid('example.windowspush'));
    expect(a, isNot(deriveToastClsid('example.other')));
    expect(a[14], '5');
    expect('89AB', contains(a[19]));
    final result = patchManifest(manifest, const ManifestPatch(appId: _appId));
    expect(result.toastClsid, a);
  });
}
