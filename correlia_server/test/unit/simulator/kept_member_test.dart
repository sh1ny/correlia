import 'package:correlia_server/event.dart';
import 'package:correlia_server/src/simulator/stored_event_lookup.dart';
import 'package:test/test.dart';

import '../event/fixture.dart';

/// A fixture event whose maps hold the same entries in the given key order.
CanonicalEvent _member({required bool reversed}) {
  final data = eventFixture()['data']! as Map<String, Object?>;
  Map<String, Object?> ordered(Map<String, Object?> map) => {
    for (final key in reversed ? map.keys.toList().reversed : map.keys)
      key: map[key],
  };
  data['labels'] = ordered({'alertname': 'Example', 'severity': 'warning'});
  data['annotations'] = ordered({'runbook': 'r', 'description': 'd'});
  data['extensions'] = ordered({'example.org/a': '1', 'example.org/b': '2'});
  data['identity_fields'] = ordered(
    data['identity_fields']! as Map<String, Object?>,
  );
  return CanonicalEvent.fromJson(data);
}

void main() {
  test('members_equal_up_to_map_key_order_are_one_member', () {
    final first = _member(reversed: false);
    final second = _member(reversed: true);
    // The stored payload's key order need not be the re-decoded member's.
    expect(selectKeptMember([first], second), same(first));
    expect(selectKeptMember([second], first), same(second));
    // Two members that differ only in key order are one member, not ambiguous.
    expect(selectKeptMember([first, second], first), isNotNull);
    expect(selectKeptMember([second, first], second), isNotNull);
  });

  test('members_that_differ_in_list_order_stay_ambiguous', () {
    final data = eventFixture()['data']! as Map<String, Object?>;
    final a = {
      ...data,
      'links': [
        {'href': 'https://x.example/1', 'relation': 'runbook'},
        {'href': 'https://x.example/2', 'relation': 'runbook'},
      ],
    };
    final b = {
      ...data,
      'links': [
        {'href': 'https://x.example/2', 'relation': 'runbook'},
        {'href': 'https://x.example/1', 'relation': 'runbook'},
      ],
    };
    final first = CanonicalEvent.fromJson(a);
    final second = CanonicalEvent.fromJson(b);
    // Links are not part of the invariant, so both match; their order differs.
    expect(selectKeptMember([first, second], first), isNull);
  });
}
