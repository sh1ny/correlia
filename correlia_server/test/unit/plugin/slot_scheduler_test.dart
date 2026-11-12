import 'package:correlia_server/src/plugin/slot_scheduler.dart';
import 'package:test/test.dart';

void main() {
  test('more_busy_outputs_than_slots', () {
    var now = DateTime.utc(2026);
    final scheduler = SlotScheduler(clock: () => now);
    final keys = List.generate(
      17,
      (i) => PluginKey('o${i.toString().padLeft(2, '0')}', 'a'),
    );
    for (final key in keys.take(16)) {
      scheduler.admit(key);
      scheduler.ready(key);
    }
    expect(scheduler.rotationFor(keys.last), isNull);
    var waiting = keys.last;
    final admitted = <PluginKey>{};
    for (var i = 0; i < keys.length; i++) {
      now = now.add(const Duration(seconds: 60));
      final victim = scheduler.rotationFor(waiting)!;
      scheduler.release(victim);
      scheduler.admit(waiting);
      scheduler.ready(waiting);
      admitted.add(waiting);
      expect(scheduler.running, hasLength(16));
      waiting = victim;
    }
    expect(admitted, keys.toSet());
  });

  test('idle_active_output_releases_slot', () {
    var now = DateTime.utc(2026);
    final scheduler = SlotScheduler(clock: () => now);
    final keys = List.generate(
      17,
      (i) => PluginKey('o${i.toString().padLeft(2, '0')}', 'a'),
    );
    for (final key in keys.take(16)) {
      scheduler.admit(key);
      scheduler.ready(key);
    }
    now = now.add(const Duration(seconds: 59));
    for (final key in keys.skip(1).take(15)) {
      scheduler.due(key);
    }
    now = now.add(const Duration(seconds: 1));
    expect(scheduler.idleForRelease(keys.first), isTrue);
    expect(scheduler.idleForRelease(keys[1]), isFalse);
    scheduler.release(keys.first);
    scheduler.admit(keys.last);
    expect(scheduler.running, hasLength(16));
    expect(scheduler.running, contains(keys.last));
    scheduler.release(keys.last);
    scheduler.admit(keys.first);
    expect(scheduler.running, contains(keys.first));
  });

  test('five_busy_definitions_of_one_output', () {
    var now = DateTime.utc(2026);
    final scheduler = SlotScheduler(clock: () => now);
    final keys = List.generate(5, (i) => PluginKey('a', '$i'));
    for (final key in keys.take(4)) {
      scheduler.admit(key);
      scheduler.ready(key);
    }
    expect(scheduler.canAdmit(keys.last), isFalse);
    var waiting = keys.last;
    final turns = <PluginKey, int>{};
    for (var turn = 0; turn < 10; turn++) {
      now = now.add(const Duration(seconds: 60));
      final victim = scheduler.rotationFor(waiting)!;
      scheduler.release(victim);
      scheduler.admit(waiting);
      scheduler.ready(waiting);
      turns.update(waiting, (count) => count + 1, ifAbsent: () => 1);
      expect(scheduler.running, hasLength(4));
      waiting = victim;
    }
    expect(turns.keys.toSet(), keys.toSet());
    expect(turns.values, everyElement(2));
  });

  test('probe_under_slot_contention', () {
    var now = DateTime.utc(2026);
    final scheduler = SlotScheduler(clock: () => now, workerLimit: 1);
    const probe = PluginKey('a', '1');
    scheduler.admit(probe, probing: true);
    now = now.add(const Duration(seconds: 5));
    scheduler.ready(probe);
    now = now.add(const Duration(seconds: 59));
    expect(scheduler.rotationFor(const PluginKey('b', '1')), isNull);
    now = now.add(const Duration(seconds: 1));
    expect(scheduler.rotationFor(const PluginKey('b', '1')), probe);
  });

  test('healthy_definition_at_end_of_long_queue', () {
    var now = DateTime.utc(2026);
    final scheduler = SlotScheduler(clock: () => now);
    final keys = List.generate(
      300,
      (i) => PluginKey(i.toString().padLeft(3, '0'), 'a'),
    );
    for (final key in keys.take(16)) {
      scheduler.admit(key);
      scheduler.ready(key);
    }
    expect(scheduler.running, hasLength(16));
    now = now.add(const Duration(seconds: 60));
    scheduler.release(scheduler.rotationFor(keys[16])!);
    final seen = <PluginKey>[];
    for (var i = 16; i < keys.length; i++) {
      final next = scheduler.nextFrom(keys)!;
      seen.add(next);
      scheduler.admit(next);
      expect(scheduler.running, hasLength(16));
      if (next != keys.last) scheduler.release(next);
    }
    expect(seen.last, keys.last);
    expect(seen, hasLength(284));
    expect(scheduler.running, contains(keys.last));
  });

  test('healthy_behind_unavailable_historical', () {
    final scheduler = SlotScheduler(clock: () => DateTime.utc(2026));
    final keys = List.generate(5, (i) => PluginKey('a', '$i'));
    for (var i = 0; i < 5; i++) {
      final next = scheduler.nextFrom(keys)!;
      scheduler.admit(next);
      scheduler.release(next);
      if (i == 4) expect(next, keys.last);
    }
    expect(scheduler.running, isEmpty);
  });
}
