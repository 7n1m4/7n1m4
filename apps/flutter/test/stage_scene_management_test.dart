// SPDX-License-Identifier: GPL-3.0-or-later

// Scene management is client-local: the daemon has no background verb. These
// tests drive the real background store and the real picker surface against a
// temp directory — no platform channel, no daemon write, no fabricated files.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/stage_background.dart';
import 'package:anima_control/features/stage/stage_scene_manager.dart';
import 'package:anima_control/features/stage/stage_scenes_screen.dart';

Future<File> _image(Directory dir, String name) =>
    File('${dir.path}${Platform.pathSeparator}$name')
        .writeAsBytes(<int>[0x89, 0x50, 0x4E, 0x47]);

/// The screen's load and mutations do real filesystem I/O, which must run
/// outside the fake-async zone. The indeterminate progress indicator also
/// keeps `pumpAndSettle` from ever settling, so use bounded pumps instead.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-scene-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a tint scene is added and becomes activatable', () async {
    final store = StageSceneStore(storageDirectory: temp);
    final entry = await store.add(tint: '#123456');

    expect(entry.kind, StageBackgroundKind.tint);
    expect(entry.label, contains('#123456'));
    expect(store.entries, <StageSceneEntry>[entry]);

    expect(await store.activate(entry.id), isTrue);
    expect(store.activeId, entry.id);
    expect(store.activeBackground.kind, StageBackgroundKind.tint);
    expect(store.activeBackground.tint, 0xFF123456);
  });

  test('an image scene keeps the chosen file path; removal clears active', () async {
    final store = StageSceneStore(storageDirectory: temp);
    final file = await _image(temp, 'backdrop.png');
    final entry = await store.add(imagePath: file.path);
    expect(entry.kind, StageBackgroundKind.image);
    expect(entry.imagePath, file.absolute.path);

    await store.activate(entry.id);
    expect(store.activeBackground.fingerprint, contains(file.absolute.path));
    expect(await store.remove(entry.id), isTrue);
    expect(store.entries, isEmpty);
    expect(store.activeId, isNull);
    expect(store.activeBackground, StageBackground.none);
  });

  test('a missing image is a loud error, not an empty scene', () async {
    final store = StageSceneStore(storageDirectory: temp);
    await expectLater(
      store.add(
        imagePath: '${temp.path}${Platform.pathSeparator}missing.png',
      ),
      throwsA(
        isA<StageBackgroundException>().having(
          (error) => error.code,
          'code',
          'missing-background',
        ),
      ),
    );
    expect(store.entries, isEmpty);
  });

  test('activating an unknown id fails loudly', () async {
    final store = StageSceneStore(storageDirectory: temp);
    await expectLater(
      store.activate('bg-does-not-exist'),
      throwsA(
        isA<StageSceneException>().having(
          (error) => error.code,
          'code',
          'unknown-scene',
        ),
      ),
    );
  });

  test('entries and active selection survive a store reload', () async {
    final first = StageSceneStore(storageDirectory: temp);
    final tint = await first.add(tint: '#ABCDEF');
    final file = await _image(temp, 'reload.png');
    final image = await first.add(imagePath: file.path);
    await first.activate(image.id);

    final second = StageSceneStore(storageDirectory: temp);
    await second.load();

    expect(second.entries.map((e) => e.id), <String>[tint.id, image.id]);
    expect(second.activeId, image.id);
    expect(second.activeBackground.kind, StageBackgroundKind.image);
  });

  testWidgets('the scenes screen adds, activates and removes backdrops', (
    tester,
  ) async {
    final store = StageSceneStore(storageDirectory: temp);
    await tester.runAsync(store.load);
    final file = (await tester.runAsync(
      () => _image(temp, 'picked.png'),
    ))!;

    int savedCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StageScenesScreen(
          store: store,
          imagePicker: () async => file.path,
          onChanged: () => savedCalls++,
        ),
      ),
    );
    await _flush(tester);

    expect(find.text('No scenes yet'), findsOneWidget);

    await tester.tap(find.text('Add tint'));
    await _flush(tester);
    expect(find.textContaining('#'), findsWidgets);
    expect(store.entries, hasLength(1));

    await tester.tap(find.text('Add image'));
    await _flush(tester);
    expect(store.entries, hasLength(2));

    final imageEntry = store.entries.last;
    await tester.tap(find.text('Activate').last);
    await _flush(tester);
    expect(store.activeId, imageEntry.id);

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await _flush(tester);
    expect(store.entries, hasLength(1));
    expect(savedCalls, greaterThan(0));
  });

  testWidgets('cancelling the image picker adds nothing', (tester) async {
    final store = StageSceneStore(storageDirectory: temp);
    await tester.runAsync(store.load);

    await tester.pumpWidget(
      MaterialApp(
        home: StageScenesScreen(
          store: store,
          imagePicker: () async => null,
        ),
      ),
    );
    await _flush(tester);

    await tester.tap(find.text('Add image'));
    await _flush(tester);

    expect(store.entries, isEmpty);
    expect(find.text('No scenes yet'), findsOneWidget);
  });
}
