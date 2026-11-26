// SPDX-License-Identifier: GPL-3.0-or-later

// Deterministic coverage of the delayed resource-status pill. Timers are
// injected and fired by hand: no real sleeps and no Flutter fake-async pump
// duration is needed to cross the 5s/10s thresholds. Vue's `refDelayed` uses
// `immediate: true`, so the first transition is instant and later ones delay.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_stage_state.dart';
import 'package:anima_control/features/stage/resource_status_island.dart';

const Key _pillKey = Key('resource-status-pill');
const Key _detailKey = Key('resource-status-detail');
const Duration _five = Duration(seconds: 5);
const Duration _ten = Duration(seconds: 10);

class _RecordedTimer {
  _RecordedTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool fired = false;
  bool cancelled = false;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    callback();
  }
}

class _ManualClock {
  final List<_RecordedTimer> timers = <_RecordedTimer>[];

  ResourceCancel create(Duration duration, void Function() callback) {
    final timer = _RecordedTimer(duration, callback);
    timers.add(timer);
    return () => timer.cancelled = true;
  }

  /// Fires the newest live timer scheduled for [duration].
  void fire(Duration duration) {
    timers
        .lastWhere(
          (timer) =>
              !timer.fired && !timer.cancelled && timer.duration == duration,
        )
        .fire();
  }
}

Widget _island(
  _ManualClock clock,
  ModelStageStatus status, {
  List<String> detail = const <String>[],
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          ResourceStatusIsland(
            status: status,
            detail: detail,
            timerFactory: clock.create,
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('first loading transition is immediate, later ones delay', (
    tester,
  ) async {
    final clock = _ManualClock();
    await tester.pumpWidget(_island(clock, ModelStageStatus.none));
    expect(find.byKey(_pillKey), findsNothing);
    expect(clock.timers, isEmpty);

    await tester.pumpWidget(_island(clock, ModelStageStatus.loading));
    await tester.pump();
    expect(find.byKey(_pillKey), findsOneWidget);
    expect(find.text('Resources loading...'), findsOneWidget);
    // No timers for the first transition, matching Vue's immediate flag.
    expect(clock.timers, isEmpty);

    // The next transition is delayed: the pill still shows "Ready!" until
    // its own 5s timer fires.
    await tester.pumpWidget(_island(clock, ModelStageStatus.ready));
    await tester.pump();
    expect(
      clock.timers.map((timer) => timer.duration),
      <Duration>[_five, _ten],
    );
    expect(find.text('Ready!'), findsOneWidget);
    expect(find.byKey(_pillKey), findsOneWidget);

    clock.fire(_five);
    await tester.pump();
    expect(find.byKey(_pillKey), findsNothing);
  });

  testWidgets('loading at mount is shown at once, then later changes delay', (
    tester,
  ) async {
    final clock = _ManualClock();
    await tester.pumpWidget(_island(clock, ModelStageStatus.loading));
    expect(find.byKey(_pillKey), findsOneWidget);
    expect(clock.timers, isEmpty);

    await tester.pumpWidget(_island(clock, ModelStageStatus.ready));
    await tester.pump();
    expect(clock.timers, hasLength(2));
    expect(find.text('Ready!'), findsOneWidget);
    clock.fire(_five);
    await tester.pump();
    expect(find.byKey(_pillKey), findsNothing);
  });

  testWidgets('detail expands after the first load and collapses on tap', (
    tester,
  ) async {
    final clock = _ManualClock();
    await tester.pumpWidget(
      _island(
        clock,
        ModelStageStatus.none,
        detail: const <String>['model.vrm · 100%'],
      ),
    );
    await tester.pumpWidget(
      _island(
        clock,
        ModelStageStatus.loading,
        detail: const <String>['model.vrm · 100%'],
      ),
    );
    await tester.pump();

    expect(find.byKey(_detailKey), findsOneWidget);
    expect(find.text('Stage model: loading'), findsOneWidget);
    expect(find.text('model.vrm · 100%'), findsOneWidget);

    await tester.tap(find.byKey(_pillKey));
    await tester.pump();
    expect(find.byKey(_detailKey), findsNothing);

    await tester.tap(find.byKey(_pillKey));
    await tester.pump();
    expect(find.byKey(_detailKey), findsOneWidget);
  });

  testWidgets('dispose cancels pending timers and leaks no callbacks', (
    tester,
  ) async {
    final clock = _ManualClock();
    await tester.pumpWidget(_island(clock, ModelStageStatus.none));
    await tester.pumpWidget(_island(clock, ModelStageStatus.loading));
    await tester.pump();
    // The next transition is delayed, so timers actually exist.
    await tester.pumpWidget(_island(clock, ModelStageStatus.ready));
    await tester.pump();
    expect(clock.timers, hasLength(2));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(clock.timers.every((timer) => timer.cancelled), isTrue);
    expect(find.byKey(_pillKey), findsNothing);

    // Firing stale callbacks after dispose is inert: no mounted widget, no
    // setState, and no surviving pill.
    for (final timer in clock.timers) {
      timer.fire();
    }
    await tester.pump();
    expect(find.byKey(_pillKey), findsNothing);
  });
}
