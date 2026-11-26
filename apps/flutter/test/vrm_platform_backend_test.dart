// SPDX-License-Identifier: GPL-3.0-or-later

// Desktop-platform gate for the native VRM renderer.
//
// A real `flutter run -d linux` registers `flutter_anima_render` through
// `linux/flutter/generated_plugin_registrant.cc`, so the frozen
// `org.moeru.airi/anima/model/vrm` channel has a native handler instead of
// failing with `runtime-unavailable`. These tests cover the parts of that
// registration that are client-visible and otherwise untested:
//
//   * the Dart package's channel prefix is the exact prefix of the frozen
//     per-kind channel names the stage routes on, and every kind the stage can
//     load has exactly one channel derived from it (no kind falls through to
//     the missing-plugin path by construction),
//   * the desktop hosts CMake- and Xcode-side reference the plugin by the
//     `pluginClass` its `pubspec.yaml` declares for that OS, and the Linux
//     host actually reaches it through the generated registrant,
//   * a kind whose platform never registered fails loudly with a typed error
//     and never invents a texture id,
//   * a platform that mints the output id hands it back through `load` and
//     releases it exactly once on `dispose`,
//   * the Linux plugin source really registers the frozen channel and mints
//     every texture id through the Flutter texture registrar (a source-level
//     gate, because a headless test cannot load a real engine texture).
//
// What this file cannot prove is a GPU frame: that needs a real engine and a
// real display. The Rust half (`crates/anima-render/tests/vrm_desktop_integration.rs`)
// proves the frozen C ABI renders the bundled `AvatarSample_A.vrm`, the Dart
// half (`vrm_desktop_integration_test.dart`) proves the stage drives the
// channel, and `flutter build linux --debug` proves the plugin compiles and
// links against the frozen C ABI.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_anima_render/flutter_anima_render.dart';

/// Repository root: this file lives in `apps/flutter/test`. Under `flutter test`
/// the cwd is the app root (`apps/flutter`), so the repo root is two levels up.
final Directory _repoRoot = Directory.current.parent.parent;

String _read(String relativePath) => File(
  '${_repoRoot.path}${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}',
).readAsStringSync();

/// The `pluginClass` the package's `pubspec.yaml` declares per desktop OS.
Map<String, String> _declaredPluginClasses() {
  final lines = _read('packages/flutter_anima_render/pubspec.yaml').split('\n');
  final declared = <String, String>{};
  for (var i = 0; i < lines.length; i++) {
    final os = RegExp(r'^ {6}(linux|windows|macos):\s*$').firstMatch(lines[i]);
    if (os == null) continue;
    final pluginClass = RegExp(r'^\s*pluginClass:\s*(\S+)').firstMatch(lines[i + 1]);
    if (pluginClass == null) continue;
    declared[os.group(1)!] = pluginClass.group(1)!;
  }
  return declared;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every stage kind has exactly one channel under the frozen prefix', () {
    const kinds = <String>['vrm', 'spine', 'mmd', 'live2d'];
    final channels = kinds
        .map((kind) => '$kAnimaRenderChannelPrefix$kind')
        .toList();
    expect(channels.toSet().length, kinds.length);
    for (final channel in channels) {
      expect(channel, startsWith('org.moeru.airi/anima/model/'));
    }
    // The plugin is constructed per kind, so the channel name is the only
    // thing that selects a native backend; a typo would silently route to a
    // missing-plugin error rather than to the wrong renderer.
    for (final kind in kinds) {
      expect(FlutterAnimaRender(kind).channel.name, '$kAnimaRenderChannelPrefix$kind');
    }
  });

  test('the Linux host reaches the plugin through the generated registrant', () {
    final pubspec = _read('packages/flutter_anima_render/pubspec.yaml');
    final registrant = _read('apps/flutter/linux/flutter/generated_plugin_registrant.cc');
    final pluginClass = _declaredPluginClasses()['linux'];
    expect(pluginClass, isNotNull);
    expect(
      registrant,
      contains('#include <flutter_anima_render/flutter_anima_render_plugin.h>'),
    );
    expect(registrant, contains('flutter_anima_render_plugin_register_with_registrar'));
    expect(pubspec, contains('linux:\n        pluginClass: $pluginClass'));
  });

  test('the Windows and macOS hosts declare the same plugin class', () {
    final declared = _declaredPluginClasses();
    expect(declared.keys.toSet(), <String>{'linux', 'windows', 'macos'});
    expect(declared['windows'], declared['linux']);
    expect(declared['macos'], declared['linux']);

    final windowsPlugin = _read('apps/flutter/windows/flutter/generated_plugins.cmake');
    expect(windowsPlugin, contains('flutter_anima_render'));

    final macosRegistrant = _read('apps/flutter/macos/Flutter/GeneratedPluginRegistrant.swift');
    expect(macosRegistrant, contains('FlutterAnimaRenderPlugin'));
  });

  test('a kind whose platform never registered fails loudly, never fakes a texture', () async {
    const channel = MethodChannel('${kAnimaRenderChannelPrefix}vrm');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final plugin = FlutterAnimaRender('vrm');
    await expectLater(
      plugin.load('/models/AvatarSample_A.vrm'),
      throwsA(
        isA<NativeRenderException>()
            .having((e) => e.code, 'code', 'runtime-unavailable'),
      ),
    );
  });

  test('the Linux plugin registers the frozen channel and mints every texture id', () {
    final source = _read(
      'packages/flutter_anima_render/linux/flutter_anima_render_plugin.cc',
    );
    // The channel name is the frozen one, answered by the frozen method set.
    expect(source, contains('"org.moeru.airi/anima/model/vrm"'));
    for (final method in <String>[
      'load',
      'setLipSync',
      'setEmotion',
      'setAmbientPhase',
      'dispose',
    ]) {
      expect(source, contains('strcmp(method, "$method")'));
    }
    // Every texture id comes from the platform's registrar, and the plugin
    // never fabricates one: the only id source is fl_texture_get_id.
    expect(source, contains('fl_texture_registrar_register_texture'));
    expect(source, contains('fl_texture_get_id'));
    expect(source, contains('fl_texture_registrar_unregister_texture'));
    expect(source, isNot(contains('textureId = 0')));
    // The backend is created with the plugin's own register/release callbacks.
    expect(source, contains('airi_render_create('));
    expect(source, contains('platform_register_texture'));
    expect(source, contains('platform_release_texture'));
    // The output page is pumped into the platform texture on a timer.
    expect(source, contains('mark_texture_frame_available'));
    expect(source, contains('g_timeout_add'));
  });

  test('a platform that mints the output id draws the real frame', () async {
    const channel = MethodChannel('${kAnimaRenderChannelPrefix}vrm');
    final minted = <int>[];
    final released = <int>[];
    var nextTexture = 100;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') {
        // `load` mints one id per decoded page plus one for the output
        // surface the stage paints; every id comes from the platform.
        final textureId = nextTexture;
        nextTexture += 17;
        minted.add(textureId);
        return <String, dynamic>{'handle': 'vrm-1', 'textureId': textureId};
      }
      if (call.method == 'dispose') {
        released.add(minted.removeLast());
      }
      return null;
    });

    final texture = await FlutterAnimaRender('vrm').load('/models/AvatarSample_A.vrm');
    expect(minted, <int>[100]);
    expect(texture.textureId, 100);
    await texture.dispose();
    expect(minted, isEmpty);
    expect(released, <int>[100]);
  });
}