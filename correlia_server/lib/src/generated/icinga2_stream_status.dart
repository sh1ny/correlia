/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters
// ignore_for_file: invalid_use_of_internal_member

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _ida;
import 'package:serverpod/serverpod.dart' as _is;

abstract class Icinga2StreamStatusRow
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  Icinga2StreamStatusRow._({
    this.id,
    required this.sourceId,
    required this.state,
    this.connectionId,
    int? connectionSeq,
    this.connectedAt,
    this.lastEventAt,
    int? gapCount,
    int? lastGapSeq,
    this.lastGapAt,
    int? oversizeLines,
    this.lagMs,
    this.lastErrorClass,
    int? servedResyncSeq,
    int? syncTimeoutsInARow,
    this.currentSyncId,
    this.lastSyncId,
  }) : connectionSeq = connectionSeq ?? 0,
       gapCount = gapCount ?? 0,
       lastGapSeq = lastGapSeq ?? 0,
       oversizeLines = oversizeLines ?? 0,
       servedResyncSeq = servedResyncSeq ?? 0,
       syncTimeoutsInARow = syncTimeoutsInARow ?? 0;

  factory Icinga2StreamStatusRow({
    int? id,
    required _is.UuidValue sourceId,
    required String state,
    String? connectionId,
    int? connectionSeq,
    DateTime? connectedAt,
    DateTime? lastEventAt,
    int? gapCount,
    int? lastGapSeq,
    DateTime? lastGapAt,
    int? oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    int? servedResyncSeq,
    int? syncTimeoutsInARow,
    _is.UuidValue? currentSyncId,
    _is.UuidValue? lastSyncId,
  }) = _Icinga2StreamStatusRowImpl;

  factory Icinga2StreamStatusRow.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return Icinga2StreamStatusRow(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      state: jsonSerialization['state'] as String,
      connectionId: jsonSerialization['connectionId'] as String?,
      connectionSeq: jsonSerialization['connectionSeq'] as int?,
      connectedAt: jsonSerialization['connectedAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['connectedAt'],
            ),
      lastEventAt: jsonSerialization['lastEventAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['lastEventAt'],
            ),
      gapCount: jsonSerialization['gapCount'] as int?,
      lastGapSeq: jsonSerialization['lastGapSeq'] as int?,
      lastGapAt: jsonSerialization['lastGapAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['lastGapAt']),
      oversizeLines: jsonSerialization['oversizeLines'] as int?,
      lagMs: jsonSerialization['lagMs'] as int?,
      lastErrorClass: jsonSerialization['lastErrorClass'] as String?,
      servedResyncSeq: jsonSerialization['servedResyncSeq'] as int?,
      syncTimeoutsInARow: jsonSerialization['syncTimeoutsInARow'] as int?,
      currentSyncId: jsonSerialization['currentSyncId'] == null
          ? null
          : _is.UuidValueJsonExtension.fromJson(
              jsonSerialization['currentSyncId'],
            ),
      lastSyncId: jsonSerialization['lastSyncId'] == null
          ? null
          : _is.UuidValueJsonExtension.fromJson(
              jsonSerialization['lastSyncId'],
            ),
    );
  }

  static final t = Icinga2StreamStatusRowTable();

  static const db = Icinga2StreamStatusRowRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  String state;

  String? connectionId;

  int connectionSeq;

  DateTime? connectedAt;

  DateTime? lastEventAt;

  int gapCount;

  int lastGapSeq;

  DateTime? lastGapAt;

  int oversizeLines;

  int? lagMs;

  String? lastErrorClass;

  int servedResyncSeq;

  int syncTimeoutsInARow;

  _is.UuidValue? currentSyncId;

  _is.UuidValue? lastSyncId;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [Icinga2StreamStatusRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  Icinga2StreamStatusRow copyWith({
    int? id,
    _is.UuidValue? sourceId,
    String? state,
    String? connectionId,
    int? connectionSeq,
    DateTime? connectedAt = const _is.$UndefinedDateTime(),
    DateTime? lastEventAt = const _is.$UndefinedDateTime(),
    int? gapCount,
    int? lastGapSeq,
    DateTime? lastGapAt = const _is.$UndefinedDateTime(),
    int? oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    int? servedResyncSeq,
    int? syncTimeoutsInARow,
    _is.UuidValue? currentSyncId = const _is.$UndefinedUuidValue(),
    _is.UuidValue? lastSyncId = const _is.$UndefinedUuidValue(),
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Icinga2StreamStatusRow',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'state': state,
      if (connectionId != null) 'connectionId': connectionId,
      'connectionSeq': connectionSeq,
      if (connectedAt != null) 'connectedAt': connectedAt?.toJson(),
      if (lastEventAt != null) 'lastEventAt': lastEventAt?.toJson(),
      'gapCount': gapCount,
      'lastGapSeq': lastGapSeq,
      if (lastGapAt != null) 'lastGapAt': lastGapAt?.toJson(),
      'oversizeLines': oversizeLines,
      if (lagMs != null) 'lagMs': lagMs,
      if (lastErrorClass != null) 'lastErrorClass': lastErrorClass,
      'servedResyncSeq': servedResyncSeq,
      'syncTimeoutsInARow': syncTimeoutsInARow,
      if (currentSyncId != null) 'currentSyncId': currentSyncId?.toJson(),
      if (lastSyncId != null) 'lastSyncId': lastSyncId?.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static Icinga2StreamStatusRowInclude include() {
    return Icinga2StreamStatusRowInclude._();
  }

  static Icinga2StreamStatusRowIncludeList includeList({
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    Icinga2StreamStatusRowInclude? include,
  }) {
    return Icinga2StreamStatusRowIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _Icinga2StreamStatusRowImpl extends Icinga2StreamStatusRow {
  _Icinga2StreamStatusRowImpl({
    int? id,
    required _is.UuidValue sourceId,
    required String state,
    String? connectionId,
    int? connectionSeq,
    DateTime? connectedAt,
    DateTime? lastEventAt,
    int? gapCount,
    int? lastGapSeq,
    DateTime? lastGapAt,
    int? oversizeLines,
    int? lagMs,
    String? lastErrorClass,
    int? servedResyncSeq,
    int? syncTimeoutsInARow,
    _is.UuidValue? currentSyncId,
    _is.UuidValue? lastSyncId,
  }) : super._(
         id: id,
         sourceId: sourceId,
         state: state,
         connectionId: connectionId,
         connectionSeq: connectionSeq,
         connectedAt: connectedAt,
         lastEventAt: lastEventAt,
         gapCount: gapCount,
         lastGapSeq: lastGapSeq,
         lastGapAt: lastGapAt,
         oversizeLines: oversizeLines,
         lagMs: lagMs,
         lastErrorClass: lastErrorClass,
         servedResyncSeq: servedResyncSeq,
         syncTimeoutsInARow: syncTimeoutsInARow,
         currentSyncId: currentSyncId,
         lastSyncId: lastSyncId,
       );

  /// Returns a shallow copy of this [Icinga2StreamStatusRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  Icinga2StreamStatusRow copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    String? state,
    Object? connectionId = _Undefined,
    int? connectionSeq,
    DateTime? connectedAt = const _is.$UndefinedDateTime(),
    DateTime? lastEventAt = const _is.$UndefinedDateTime(),
    int? gapCount,
    int? lastGapSeq,
    DateTime? lastGapAt = const _is.$UndefinedDateTime(),
    int? oversizeLines,
    Object? lagMs = _Undefined,
    Object? lastErrorClass = _Undefined,
    int? servedResyncSeq,
    int? syncTimeoutsInARow,
    _is.UuidValue? currentSyncId = const _is.$UndefinedUuidValue(),
    _is.UuidValue? lastSyncId = const _is.$UndefinedUuidValue(),
  }) {
    return Icinga2StreamStatusRow(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      state: state ?? this.state,
      connectionId: connectionId is String? ? connectionId : this.connectionId,
      connectionSeq: connectionSeq ?? this.connectionSeq,
      connectedAt: connectedAt is _is.UndefinedSentinel
          ? this.connectedAt
          : connectedAt,
      lastEventAt: lastEventAt is _is.UndefinedSentinel
          ? this.lastEventAt
          : lastEventAt,
      gapCount: gapCount ?? this.gapCount,
      lastGapSeq: lastGapSeq ?? this.lastGapSeq,
      lastGapAt: lastGapAt is _is.UndefinedSentinel
          ? this.lastGapAt
          : lastGapAt,
      oversizeLines: oversizeLines ?? this.oversizeLines,
      lagMs: lagMs is int? ? lagMs : this.lagMs,
      lastErrorClass: lastErrorClass is String?
          ? lastErrorClass
          : this.lastErrorClass,
      servedResyncSeq: servedResyncSeq ?? this.servedResyncSeq,
      syncTimeoutsInARow: syncTimeoutsInARow ?? this.syncTimeoutsInARow,
      currentSyncId: currentSyncId is _is.UndefinedSentinel
          ? this.currentSyncId
          : currentSyncId,
      lastSyncId: lastSyncId is _is.UndefinedSentinel
          ? this.lastSyncId
          : lastSyncId,
    );
  }
}

class Icinga2StreamStatusRowUpdateTable
    extends _is.UpdateTable<Icinga2StreamStatusRowTable> {
  Icinga2StreamStatusRowUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<String, String> state(String value) => _is.ColumnValue(
    table.state,
    value,
  );

  _is.ColumnValue<String, String> connectionId(String? value) =>
      _is.ColumnValue(
        table.connectionId,
        value,
      );

  _is.ColumnValue<int, int> connectionSeq(int value) => _is.ColumnValue(
    table.connectionSeq,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> connectedAt(DateTime? value) =>
      _is.ColumnValue(
        table.connectedAt,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> lastEventAt(DateTime? value) =>
      _is.ColumnValue(
        table.lastEventAt,
        value,
      );

  _is.ColumnValue<int, int> gapCount(int value) => _is.ColumnValue(
    table.gapCount,
    value,
  );

  _is.ColumnValue<int, int> lastGapSeq(int value) => _is.ColumnValue(
    table.lastGapSeq,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> lastGapAt(DateTime? value) =>
      _is.ColumnValue(
        table.lastGapAt,
        value,
      );

  _is.ColumnValue<int, int> oversizeLines(int value) => _is.ColumnValue(
    table.oversizeLines,
    value,
  );

  _is.ColumnValue<int, int> lagMs(int? value) => _is.ColumnValue(
    table.lagMs,
    value,
  );

  _is.ColumnValue<String, String> lastErrorClass(String? value) =>
      _is.ColumnValue(
        table.lastErrorClass,
        value,
      );

  _is.ColumnValue<int, int> servedResyncSeq(int value) => _is.ColumnValue(
    table.servedResyncSeq,
    value,
  );

  _is.ColumnValue<int, int> syncTimeoutsInARow(int value) => _is.ColumnValue(
    table.syncTimeoutsInARow,
    value,
  );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> currentSyncId(
    _is.UuidValue? value,
  ) => _is.ColumnValue(
    table.currentSyncId,
    value,
  );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> lastSyncId(
    _is.UuidValue? value,
  ) => _is.ColumnValue(
    table.lastSyncId,
    value,
  );
}

class Icinga2StreamStatusRowTable extends _is.Table<int?> {
  Icinga2StreamStatusRowTable({super.tableRelation})
    : super(tableName: 'icinga2_stream_status') {
    updateTable = Icinga2StreamStatusRowUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    state = _is.ColumnString(
      'state',
      this,
    );
    connectionId = _is.ColumnString(
      'connectionId',
      this,
    );
    connectionSeq = _is.ColumnInt(
      'connectionSeq',
      this,
      hasDefault: true,
    );
    connectedAt = _is.ColumnDateTime(
      'connectedAt',
      this,
    );
    lastEventAt = _is.ColumnDateTime(
      'lastEventAt',
      this,
    );
    gapCount = _is.ColumnInt(
      'gapCount',
      this,
      hasDefault: true,
    );
    lastGapSeq = _is.ColumnInt(
      'lastGapSeq',
      this,
      hasDefault: true,
    );
    lastGapAt = _is.ColumnDateTime(
      'lastGapAt',
      this,
    );
    oversizeLines = _is.ColumnInt(
      'oversizeLines',
      this,
      hasDefault: true,
    );
    lagMs = _is.ColumnInt(
      'lagMs',
      this,
    );
    lastErrorClass = _is.ColumnString(
      'lastErrorClass',
      this,
    );
    servedResyncSeq = _is.ColumnInt(
      'servedResyncSeq',
      this,
      hasDefault: true,
    );
    syncTimeoutsInARow = _is.ColumnInt(
      'syncTimeoutsInARow',
      this,
      hasDefault: true,
    );
    currentSyncId = _is.ColumnUuid(
      'currentSyncId',
      this,
    );
    lastSyncId = _is.ColumnUuid(
      'lastSyncId',
      this,
    );
  }

  late final Icinga2StreamStatusRowUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnString state;

  late final _is.ColumnString connectionId;

  late final _is.ColumnInt connectionSeq;

  late final _is.ColumnDateTime connectedAt;

  late final _is.ColumnDateTime lastEventAt;

  late final _is.ColumnInt gapCount;

  late final _is.ColumnInt lastGapSeq;

  late final _is.ColumnDateTime lastGapAt;

  late final _is.ColumnInt oversizeLines;

  late final _is.ColumnInt lagMs;

  late final _is.ColumnString lastErrorClass;

  late final _is.ColumnInt servedResyncSeq;

  late final _is.ColumnInt syncTimeoutsInARow;

  late final _is.ColumnUuid currentSyncId;

  late final _is.ColumnUuid lastSyncId;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    state,
    connectionId,
    connectionSeq,
    connectedAt,
    lastEventAt,
    gapCount,
    lastGapSeq,
    lastGapAt,
    oversizeLines,
    lagMs,
    lastErrorClass,
    servedResyncSeq,
    syncTimeoutsInARow,
    currentSyncId,
    lastSyncId,
  ];
}

class Icinga2StreamStatusRowInclude extends _is.IncludeObject {
  Icinga2StreamStatusRowInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => Icinga2StreamStatusRow.t;
}

class Icinga2StreamStatusRowIncludeList extends _is.IncludeList {
  Icinga2StreamStatusRowIncludeList._({
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(Icinga2StreamStatusRow.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => Icinga2StreamStatusRow.t;
}

class Icinga2StreamStatusRowRepository {
  const Icinga2StreamStatusRowRepository._();

  /// Returns a list of [Icinga2StreamStatusRow]s matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order of the items use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// The maximum number of items can be set by [limit]. If no limit is set,
  /// all items matching the query will be returned.
  ///
  /// [offset] defines how many items to skip, after which [limit] (or all)
  /// items are read from the database.
  ///
  /// ```dart
  /// var persons = await Persons.db.find(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.firstName,
  ///   limit: 100,
  /// );
  /// ```
  Future<List<Icinga2StreamStatusRow>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<Icinga2StreamStatusRow>(
      where: where?.call(Icinga2StreamStatusRow.t),
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [Icinga2StreamStatusRow]s matching the given query parameters every time the
  /// source tables are modified.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order of the items use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// The maximum number of items can be set by [limit]. If no limit is set,
  /// all items matching the query will be returned.
  ///
  /// [offset] defines how many items to skip, after which [limit] (or all)
  /// items are read from the database.
  ///
  /// Use [throttle] to specify the minimum interval between queries. It can
  /// also be set to `null`, in which case the stream will only be throttled
  /// when its subscription is paused.
  ///
  /// Source tables are collected from the queried table, [where], [orderBy],
  /// [orderByList], and the [include] graph. [alsoTriggerOnTables] is added
  /// to that set. Pass [Table] instances such as `Icinga2StreamStatusRow.t`.
  ///
  /// Raw [Expression] SQL is not inspected. Tables referenced only in raw
  /// SQL must be passed via [alsoTriggerOnTables].
  ///
  /// The stream always reads committed state and never joins an ambient
  /// [Transaction]. Emissions for a write fire after that write commits.
  ///
  /// Currently only supported on SQLite. Calling this method on PostgreSQL
  /// throws an [UnsupportedError].
  ///
  /// ```dart
  /// var subscription = Persons.db.watch(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.firstName,
  ///   limit: 100,
  /// ).listen((persons) {
  ///   // Handle the latest matching rows.
  /// });
  /// ```
  _ida.Stream<List<Icinga2StreamStatusRow>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<Icinga2StreamStatusRow>(
      where: where?.call(Icinga2StreamStatusRow.t),
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [Icinga2StreamStatusRow] matching the given query parameters.
  ///
  /// Use [where] to specify which items to include in the return value.
  /// If none is specified, all items will be returned.
  ///
  /// To specify the order use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// [offset] defines how many items to skip, after which the next one will be picked.
  ///
  /// ```dart
  /// var youngestPerson = await Persons.db.findFirstRow(
  ///   session,
  ///   where: (t) => t.lastName.equals('Jones'),
  ///   orderBy: (t) => t.age,
  /// );
  /// ```
  Future<Icinga2StreamStatusRow?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<Icinga2StreamStatusRow>(
      where: where?.call(Icinga2StreamStatusRow.t),
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [Icinga2StreamStatusRow] by its [id] or null if no such row exists.
  Future<Icinga2StreamStatusRow?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<Icinga2StreamStatusRow>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [Icinga2StreamStatusRow]s in the list and returns the inserted rows.
  ///
  /// The returned [Icinga2StreamStatusRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// insert, none of the rows will be inserted.
  ///
  /// If [ignoreConflicts] is set to `true`, rows that conflict with existing
  /// rows are silently skipped, and only the successfully inserted rows are
  /// returned.
  ///
  /// If [noReturn] is set to `true`, the inserted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> insert(
    _is.DatabaseSession session,
    List<Icinga2StreamStatusRow> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<Icinga2StreamStatusRow>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [Icinga2StreamStatusRow] and returns the inserted row.
  ///
  /// The returned [Icinga2StreamStatusRow] will have its `id` field set.
  Future<Icinga2StreamStatusRow> insertRow(
    _is.DatabaseSession session,
    Icinga2StreamStatusRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<Icinga2StreamStatusRow>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [Icinga2StreamStatusRow]s in the list and returns the resulting rows.
  ///
  /// If a row conflicts on the given [conflictColumns], the existing row is
  /// updated with the new values. Otherwise, a new row is inserted.
  ///
  /// If [updateColumns] is provided, only those columns will be updated on
  /// conflict. If null, all non-conflict, non-id columns are updated.
  ///
  /// If [updateWhere] is provided, the update only applies to rows matching the
  /// given expression. Conflicting rows that don't match are skipped and not
  /// returned, so the resulting list may be shorter than [rows].
  ///
  /// The returned [Icinga2StreamStatusRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> upsert(
    _is.DatabaseSession session,
    List<Icinga2StreamStatusRow> rows, {
    required _is.ColumnSelections<Icinga2StreamStatusRowTable> conflictColumns,
    _is.ColumnSelections<Icinga2StreamStatusRowTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<Icinga2StreamStatusRow>(
      rows,
      conflictColumns: conflictColumns(Icinga2StreamStatusRow.t),
      updateColumns: updateColumns?.call(Icinga2StreamStatusRow.t),
      updateWhere: updateWhere?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [Icinga2StreamStatusRow] and returns the resulting row.
  ///
  /// If the row conflicts on the given [conflictColumns], the existing row is
  /// updated. Otherwise, a new row is inserted.
  ///
  /// If [updateColumns] is provided, only those columns will be updated on
  /// conflict. If null, all non-conflict, non-id columns are updated.
  ///
  /// If [updateWhere] is provided, the update only applies when the existing
  /// row matches the expression. Returns `null` if no row was affected — for
  /// example when [updateWhere] does not match the conflicting row.
  ///
  /// The returned [Icinga2StreamStatusRow] will have its `id` field set.
  Future<Icinga2StreamStatusRow?> upsertRow(
    _is.DatabaseSession session,
    Icinga2StreamStatusRow row, {
    required _is.ColumnSelections<Icinga2StreamStatusRowTable> conflictColumns,
    _is.ColumnSelections<Icinga2StreamStatusRowTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<Icinga2StreamStatusRow>(
      row,
      conflictColumns: conflictColumns(Icinga2StreamStatusRow.t),
      updateColumns: updateColumns?.call(Icinga2StreamStatusRow.t),
      updateWhere: updateWhere?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2StreamStatusRow]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> update(
    _is.DatabaseSession session,
    List<Icinga2StreamStatusRow> rows, {
    _is.ColumnSelections<Icinga2StreamStatusRowTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<Icinga2StreamStatusRow>(
      rows,
      columns: columns?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [Icinga2StreamStatusRow]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<Icinga2StreamStatusRow> updateRow(
    _is.DatabaseSession session,
    Icinga2StreamStatusRow row, {
    _is.ColumnSelections<Icinga2StreamStatusRowTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<Icinga2StreamStatusRow>(
      row,
      columns: columns?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
    );
  }

  /// Updates a single [Icinga2StreamStatusRow] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<Icinga2StreamStatusRow?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<Icinga2StreamStatusRowUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<Icinga2StreamStatusRow>(
      id,
      columnValues: columnValues(Icinga2StreamStatusRow.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2StreamStatusRow]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<Icinga2StreamStatusRowUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<Icinga2StreamStatusRow>(
      columnValues: columnValues(Icinga2StreamStatusRow.t.updateTable),
      where: where(Icinga2StreamStatusRow.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [Icinga2StreamStatusRow]s in the list and returns the deleted rows.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// This is an atomic operation, meaning that if one of the rows fail to
  /// be deleted, none of the rows will be deleted.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> delete(
    _is.DatabaseSession session,
    List<Icinga2StreamStatusRow> rows, {
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<Icinga2StreamStatusRow>(
      rows,
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [Icinga2StreamStatusRow].
  Future<Icinga2StreamStatusRow> deleteRow(
    _is.DatabaseSession session,
    Icinga2StreamStatusRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<Icinga2StreamStatusRow>(
      row,
      transaction: transaction,
    );
  }

  /// Deletes all rows matching the [where] expression.
  ///
  /// To specify the order of the returned rows use [orderBy] or [orderByList]
  /// when sorting by multiple columns.
  ///
  /// If [noReturn] is set to `true`, the deleted rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamStatusRow>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable> where,
    _is.OrderByBuilder<Icinga2StreamStatusRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamStatusRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<Icinga2StreamStatusRow>(
      where: where(Icinga2StreamStatusRow.t),
      orderBy: orderBy?.call(Icinga2StreamStatusRow.t),
      orderByList: orderByList?.call(Icinga2StreamStatusRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<Icinga2StreamStatusRow>(
      where: where?.call(Icinga2StreamStatusRow.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [Icinga2StreamStatusRow] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2StreamStatusRowTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<Icinga2StreamStatusRow>(
      where: where(Icinga2StreamStatusRow.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
