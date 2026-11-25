// SPDX-License-Identifier: GPL-3.0-or-later

// Focused, hermetic coverage of background selection, resolution and the
// background layer widget. Uses a temporary directory for the one local image;
// no daemon client, socket, platform channel or network is involved.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_failure.dart';
import 'package:anima_control/features/stage/stage_background.dart';
import 'package:anima_control/features/stage/stage_overlays.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-background-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('StageBackground.tintFromHex', () {
    test('parses RRGGBB and AARRGGBB, with or without a hash', () {
      expect(StageBackground.tintFromHex('#101010').tint, 0xFF101010);
      expect(StageBackground.tintFromHex('102030').tint, 0xFF102030);
      expect(StageBackground.tintFromHex('#80101010').tint, 0x80101010);
    });

    test('invalid or missing input selects no backdrop', () {
      for (final value in <String?>[
        null,
        '',
        '#abc',
        '#nothex',
        '#1234567890',
        'http://example.com/bg.png',
      ]) {
        expect(
          StageBackground.tintFromHex(value).kind,
          StageBackgroundKind.none,
          reason: 'input: $value',
        );
      }
    });
  });

  group('StageBackgroundResolver', () {
    const resolver = StageBackgroundResolver();

    test('no inputs means no backdrop', () async {
      final resolved = await resolver.resolve();
      expect(resolved.kind, StageBackgroundKind.none);
    });

    test('a tint resolves without touching the filesystem', () async {
      final resolved = await resolver.resolve(tint: '#171717');
      expect(resolved.kind, StageBackgroundKind.tint);
      expect(resolved.tint, 0xFF171717);
    });

    test('a local file resolves to an absolute path and fingerprint', () async {
      final file = File('${temp.path}${Platform.pathSeparator}bg.png')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final resolved = await resolver.resolve(imagePath: file.path);
      expect(resolved.kind, StageBackgroundKind.image);
      expect(resolved.imagePath, file.absolute.path);
      expect(resolved.fingerprint, contains(file.absolute.path));
      expect(resolved.fingerprint, contains('4'));
    });

    test('a remote URL fails loudly and is never downloaded', () async {
      await expectLater(
        resolver.resolve(imagePath: 'https://example.com/bg.png'),
        throwsA(
          isA<StageBackgroundException>()
              .having((e) => e.code, 'code', 'remote-background')
              .having((e) => e, 'failure', isA<ModelFailure>()),
        ),
      );
      await expectLater(
        resolver.resolve(imagePath: 'http://example.com/bg.png'),
        throwsA(
          isA<StageBackgroundException>().having(
            (e) => e.code,
            'code',
            'remote-background',
          ),
        ),
      );
    });

    test('a missing file fails loudly; a bad tint fails loudly', () async {
      await expectLater(
        resolver.resolve(
          imagePath: '${temp.path}${Platform.pathSeparator}missing.png',
        ),
        throwsA(
          isA<StageBackgroundException>().having(
            (e) => e.code,
            'code',
            'missing-background',
          ),
        ),
      );
      await expectLater(
        resolver.resolve(tint: 'chartreuse'),
        throwsA(
          isA<StageBackgroundException>().having(
            (e) => e.code,
            'code',
            'invalid-tint',
          ),
        ),
      );
    });
  });

  group('StageBackgroundLayer widget', () {
    Future<void> pumpLayer(WidgetTester tester, StageBackground background) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: <Widget>[
                  StageBackgroundLayer(background: background),
                ],
              ),
            ),
          ),
        );

    testWidgets('none paints nothing', (tester) async {
      await pumpLayer(tester, StageBackground.none);
      expect(
        find.byWidgetPredicate((w) => w is StageBackgroundLayer),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a tint paints the exact stored color', (tester) async {
      await pumpLayer(
        tester,
        const StageBackground(kind: StageBackgroundKind.tint, tint: 0xFF123456),
      );
      final layer = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == const Color(0xFF123456),
      );
      expect(layer, findsOneWidget);
    });

    testWidgets('a local image is painted from the resolved path', (
      tester,
    ) async {
      final file = File('${temp.path}${Platform.pathSeparator}bg.png')
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
      await pumpLayer(
        tester,
        StageBackground(kind: StageBackgroundKind.image, imagePath: file.path),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
      expect((image.image! as FileImage).file.path, file.absolute.path);
      expect(image.fit, BoxFit.cover);
    });

    testWidgets('an undecodable image has a loud errorBuilder', (tester) async {
      final file = File('${temp.path}${Platform.pathSeparator}bad.png')
        ..writeAsStringSync('not an image');
      await pumpLayer(
        tester,
        StageBackground(kind: StageBackgroundKind.image, imagePath: file.path),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.errorBuilder, isNotNull);
      final failure = image.errorBuilder!(
        tester.element(find.byType(Image)),
        Object(),
        StackTrace.empty,
      );
      expect(failure.toString(), contains('_BackgroundFailure'));
    });
  });
}
