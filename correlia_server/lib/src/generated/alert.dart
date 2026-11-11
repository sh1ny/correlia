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

abstract class AlertRow
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  AlertRow._({
    this.id,
    required this.tenant,
    required this.fingerprint,
    required this.status,
    required this.severity,
    required this.summary,
    required this.sourceInstance,
    this.firingSince,
    this.generatorUrl,
    required this.fenceEffectiveSeconds,
    required this.fenceEffectiveNanos,
    required this.fenceObservedSeconds,
    required this.fenceObservedNanos,
    required this.fenceEventId,
    required this.lastObservedAt,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AlertRow({
    int? id,
    required String tenant,
    required String fingerprint,
    required String status,
    required String severity,
    required String summary,
    required String sourceInstance,
    DateTime? firingSince,
    String? generatorUrl,
    required int fenceEffectiveSeconds,
    required int fenceEffectiveNanos,
    required int fenceObservedSeconds,
    required int fenceObservedNanos,
    required String fenceEventId,
    required DateTime lastObservedAt,
    required int version,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _AlertRowImpl;

  factory AlertRow.fromJson(Map<String, dynamic> jsonSerialization) {
    return AlertRow(
      id: jsonSerialization['id'] as int?,
      tenant: jsonSerialization['tenant'] as String,
      fingerprint: jsonSerialization['fingerprint'] as String,
      status: jsonSerialization['status'] as String,
      severity: jsonSerialization['severity'] as String,
      summary: jsonSerialization['summary'] as String,
      sourceInstance: jsonSerialization['sourceInstance'] as String,
      firingSince: jsonSerialization['firingSince'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['firingSince'],
            ),
      generatorUrl: jsonSerialization['generatorUrl'] as String?,
      fenceEffectiveSeconds: jsonSerialization['fenceEffectiveSeconds'] as int,
      fenceEffectiveNanos: jsonSerialization['fenceEffectiveNanos'] as int,
      fenceObservedSeconds: jsonSerialization['fenceObservedSeconds'] as int,
      fenceObservedNanos: jsonSerialization['fenceObservedNanos'] as int,
      fenceEventId: jsonSerialization['fenceEventId'] as String,
      lastObservedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['lastObservedAt'],
      ),
      version: jsonSerialization['version'] as int,
      createdAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['createdAt'],
      ),
      updatedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['updatedAt'],
      ),
    );
  }

  static final t = AlertRowTable();

  static const db = AlertRowRepository._();

  @override
  int? id;

  String tenant;

  String fingerprint;

  String status;

  String severity;

  String summary;

  String sourceInstance;

  DateTime? firingSince;

  String? generatorUrl;

  int fenceEffectiveSeconds;

  int fenceEffectiveNanos;

  int fenceObservedSeconds;

  int fenceObservedNanos;

  String fenceEventId;

  DateTime lastObservedAt;

  int version;

  DateTime createdAt;

  DateTime updatedAt;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [AlertRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  AlertRow copyWith({
    int? id,
    String? tenant,
    String? fingerprint,
    String? status,
    String? severity,
    String? summary,
    String? sourceInstance,
    DateTime? firingSince = const _is.$UndefinedDateTime(),
    String? generatorUrl,
    int? fenceEffectiveSeconds,
    int? fenceEffectiveNanos,
    int? fenceObservedSeconds,
    int? fenceObservedNanos,
    String? fenceEventId,
    DateTime? lastObservedAt,
    int? version,
    DateTime? createdAt,
    DateTime? updatedAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'AlertRow',
      if (id != null) 'id': id,
      'tenant': tenant,
      'fingerprint': fingerprint,
      'status': status,
      'severity': severity,
      'summary': summary,
      'sourceInstance': sourceInstance,
      if (firingSince != null) 'firingSince': firingSince?.toJson(),
      if (generatorUrl != null) 'generatorUrl': generatorUrl,
      'fenceEffectiveSeconds': fenceEffectiveSeconds,
      'fenceEffectiveNanos': fenceEffectiveNanos,
      'fenceObservedSeconds': fenceObservedSeconds,
      'fenceObservedNanos': fenceObservedNanos,
      'fenceEventId': fenceEventId,
      'lastObservedAt': lastObservedAt.toJson(),
      'version': version,
      'createdAt': createdAt.toJson(),
      'updatedAt': updatedAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static AlertRowInclude include() {
    return AlertRowInclude._();
  }

  static AlertRowIncludeList includeList({
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    AlertRowInclude? include,
  }) {
    return AlertRowIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _AlertRowImpl extends AlertRow {
  _AlertRowImpl({
    int? id,
    required String tenant,
    required String fingerprint,
    required String status,
    required String severity,
    required String summary,
    required String sourceInstance,
    DateTime? firingSince,
    String? generatorUrl,
    required int fenceEffectiveSeconds,
    required int fenceEffectiveNanos,
    required int fenceObservedSeconds,
    required int fenceObservedNanos,
    required String fenceEventId,
    required DateTime lastObservedAt,
    required int version,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : super._(
         id: id,
         tenant: tenant,
         fingerprint: fingerprint,
         status: status,
         severity: severity,
         summary: summary,
         sourceInstance: sourceInstance,
         firingSince: firingSince,
         generatorUrl: generatorUrl,
         fenceEffectiveSeconds: fenceEffectiveSeconds,
         fenceEffectiveNanos: fenceEffectiveNanos,
         fenceObservedSeconds: fenceObservedSeconds,
         fenceObservedNanos: fenceObservedNanos,
         fenceEventId: fenceEventId,
         lastObservedAt: lastObservedAt,
         version: version,
         createdAt: createdAt,
         updatedAt: updatedAt,
       );

  /// Returns a shallow copy of this [AlertRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  AlertRow copyWith({
    Object? id = _Undefined,
    String? tenant,
    String? fingerprint,
    String? status,
    String? severity,
    String? summary,
    String? sourceInstance,
    DateTime? firingSince = const _is.$UndefinedDateTime(),
    Object? generatorUrl = _Undefined,
    int? fenceEffectiveSeconds,
    int? fenceEffectiveNanos,
    int? fenceObservedSeconds,
    int? fenceObservedNanos,
    String? fenceEventId,
    DateTime? lastObservedAt,
    int? version,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AlertRow(
      id: id is int? ? id : this.id,
      tenant: tenant ?? this.tenant,
      fingerprint: fingerprint ?? this.fingerprint,
      status: status ?? this.status,
      severity: severity ?? this.severity,
      summary: summary ?? this.summary,
      sourceInstance: sourceInstance ?? this.sourceInstance,
      firingSince: firingSince is _is.UndefinedSentinel
          ? this.firingSince
          : firingSince,
      generatorUrl: generatorUrl is String? ? generatorUrl : this.generatorUrl,
      fenceEffectiveSeconds:
          fenceEffectiveSeconds ?? this.fenceEffectiveSeconds,
      fenceEffectiveNanos: fenceEffectiveNanos ?? this.fenceEffectiveNanos,
      fenceObservedSeconds: fenceObservedSeconds ?? this.fenceObservedSeconds,
      fenceObservedNanos: fenceObservedNanos ?? this.fenceObservedNanos,
      fenceEventId: fenceEventId ?? this.fenceEventId,
      lastObservedAt: lastObservedAt ?? this.lastObservedAt,
      version: version ?? this.version,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class AlertRowUpdateTable extends _is.UpdateTable<AlertRowTable> {
  AlertRowUpdateTable(super.table);

  _is.ColumnValue<String, String> tenant(String value) => _is.ColumnValue(
    table.tenant,
    value,
  );

  _is.ColumnValue<String, String> fingerprint(String value) => _is.ColumnValue(
    table.fingerprint,
    value,
  );

  _is.ColumnValue<String, String> status(String value) => _is.ColumnValue(
    table.status,
    value,
  );

  _is.ColumnValue<String, String> severity(String value) => _is.ColumnValue(
    table.severity,
    value,
  );

  _is.ColumnValue<String, String> summary(String value) => _is.ColumnValue(
    table.summary,
    value,
  );

  _is.ColumnValue<String, String> sourceInstance(String value) =>
      _is.ColumnValue(
        table.sourceInstance,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> firingSince(DateTime? value) =>
      _is.ColumnValue(
        table.firingSince,
        value,
      );

  _is.ColumnValue<String, String> generatorUrl(String? value) =>
      _is.ColumnValue(
        table.generatorUrl,
        value,
      );

  _is.ColumnValue<int, int> fenceEffectiveSeconds(int value) => _is.ColumnValue(
    table.fenceEffectiveSeconds,
    value,
  );

  _is.ColumnValue<int, int> fenceEffectiveNanos(int value) => _is.ColumnValue(
    table.fenceEffectiveNanos,
    value,
  );

  _is.ColumnValue<int, int> fenceObservedSeconds(int value) => _is.ColumnValue(
    table.fenceObservedSeconds,
    value,
  );

  _is.ColumnValue<int, int> fenceObservedNanos(int value) => _is.ColumnValue(
    table.fenceObservedNanos,
    value,
  );

  _is.ColumnValue<String, String> fenceEventId(String value) => _is.ColumnValue(
    table.fenceEventId,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> lastObservedAt(DateTime value) =>
      _is.ColumnValue(
        table.lastObservedAt,
        value,
      );

  _is.ColumnValue<int, int> version(int value) => _is.ColumnValue(
    table.version,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> createdAt(DateTime value) =>
      _is.ColumnValue(
        table.createdAt,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> updatedAt(DateTime value) =>
      _is.ColumnValue(
        table.updatedAt,
        value,
      );
}

class AlertRowTable extends _is.Table<int?> {
  AlertRowTable({super.tableRelation}) : super(tableName: 'alerts') {
    updateTable = AlertRowUpdateTable(this);
    tenant = _is.ColumnString(
      'tenant',
      this,
    );
    fingerprint = _is.ColumnString(
      'fingerprint',
      this,
    );
    status = _is.ColumnString(
      'status',
      this,
    );
    severity = _is.ColumnString(
      'severity',
      this,
    );
    summary = _is.ColumnString(
      'summary',
      this,
    );
    sourceInstance = _is.ColumnString(
      'sourceInstance',
      this,
    );
    firingSince = _is.ColumnDateTime(
      'firingSince',
      this,
    );
    generatorUrl = _is.ColumnString(
      'generatorUrl',
      this,
    );
    fenceEffectiveSeconds = _is.ColumnInt(
      'fenceEffectiveSeconds',
      this,
    );
    fenceEffectiveNanos = _is.ColumnInt(
      'fenceEffectiveNanos',
      this,
    );
    fenceObservedSeconds = _is.ColumnInt(
      'fenceObservedSeconds',
      this,
    );
    fenceObservedNanos = _is.ColumnInt(
      'fenceObservedNanos',
      this,
    );
    fenceEventId = _is.ColumnString(
      'fenceEventId',
      this,
    );
    lastObservedAt = _is.ColumnDateTime(
      'lastObservedAt',
      this,
    );
    version = _is.ColumnInt(
      'version',
      this,
    );
    createdAt = _is.ColumnDateTime(
      'createdAt',
      this,
    );
    updatedAt = _is.ColumnDateTime(
      'updatedAt',
      this,
    );
  }

  late final AlertRowUpdateTable updateTable;

  late final _is.ColumnString tenant;

  late final _is.ColumnString fingerprint;

  late final _is.ColumnString status;

  late final _is.ColumnString severity;

  late final _is.ColumnString summary;

  late final _is.ColumnString sourceInstance;

  late final _is.ColumnDateTime firingSince;

  late final _is.ColumnString generatorUrl;

  late final _is.ColumnInt fenceEffectiveSeconds;

  late final _is.ColumnInt fenceEffectiveNanos;

  late final _is.ColumnInt fenceObservedSeconds;

  late final _is.ColumnInt fenceObservedNanos;

  late final _is.ColumnString fenceEventId;

  late final _is.ColumnDateTime lastObservedAt;

  late final _is.ColumnInt version;

  late final _is.ColumnDateTime createdAt;

  late final _is.ColumnDateTime updatedAt;

  @override
  List<_is.Column> get columns => [
    id,
    tenant,
    fingerprint,
    status,
    severity,
    summary,
    sourceInstance,
    firingSince,
    generatorUrl,
    fenceEffectiveSeconds,
    fenceEffectiveNanos,
    fenceObservedSeconds,
    fenceObservedNanos,
    fenceEventId,
    lastObservedAt,
    version,
    createdAt,
    updatedAt,
  ];
}

class AlertRowInclude extends _is.IncludeObject {
  AlertRowInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => AlertRow.t;
}

class AlertRowIncludeList extends _is.IncludeList {
  AlertRowIncludeList._({
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(AlertRow.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => AlertRow.t;
}

class AlertRowRepository {
  const AlertRowRepository._();

  /// Returns a list of [AlertRow]s matching the given query parameters.
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
  Future<List<AlertRow>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<AlertRow>(
      where: where?.call(AlertRow.t),
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [AlertRow]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `AlertRow.t`.
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
  _ida.Stream<List<AlertRow>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<AlertRow>(
      where: where?.call(AlertRow.t),
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [AlertRow] matching the given query parameters.
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
  Future<AlertRow?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    int? offset,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<AlertRow>(
      where: where?.call(AlertRow.t),
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [AlertRow] by its [id] or null if no such row exists.
  Future<AlertRow?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<AlertRow>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [AlertRow]s in the list and returns the inserted rows.
  ///
  /// The returned [AlertRow]s will have their `id` fields set.
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
  Future<List<AlertRow>> insert(
    _is.DatabaseSession session,
    List<AlertRow> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<AlertRow>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [AlertRow] and returns the inserted row.
  ///
  /// The returned [AlertRow] will have its `id` field set.
  Future<AlertRow> insertRow(
    _is.DatabaseSession session,
    AlertRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<AlertRow>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [AlertRow]s in the list and returns the resulting rows.
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
  /// The returned [AlertRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AlertRow>> upsert(
    _is.DatabaseSession session,
    List<AlertRow> rows, {
    required _is.ColumnSelections<AlertRowTable> conflictColumns,
    _is.ColumnSelections<AlertRowTable>? updateColumns,
    _is.WhereExpressionBuilder<AlertRowTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<AlertRow>(
      rows,
      conflictColumns: conflictColumns(AlertRow.t),
      updateColumns: updateColumns?.call(AlertRow.t),
      updateWhere: updateWhere?.call(AlertRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [AlertRow] and returns the resulting row.
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
  /// The returned [AlertRow] will have its `id` field set.
  Future<AlertRow?> upsertRow(
    _is.DatabaseSession session,
    AlertRow row, {
    required _is.ColumnSelections<AlertRowTable> conflictColumns,
    _is.ColumnSelections<AlertRowTable>? updateColumns,
    _is.WhereExpressionBuilder<AlertRowTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<AlertRow>(
      row,
      conflictColumns: conflictColumns(AlertRow.t),
      updateColumns: updateColumns?.call(AlertRow.t),
      updateWhere: updateWhere?.call(AlertRow.t),
      transaction: transaction,
    );
  }

  /// Updates all [AlertRow]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AlertRow>> update(
    _is.DatabaseSession session,
    List<AlertRow> rows, {
    _is.ColumnSelections<AlertRowTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<AlertRow>(
      rows,
      columns: columns?.call(AlertRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [AlertRow]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<AlertRow> updateRow(
    _is.DatabaseSession session,
    AlertRow row, {
    _is.ColumnSelections<AlertRowTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<AlertRow>(
      row,
      columns: columns?.call(AlertRow.t),
      transaction: transaction,
    );
  }

  /// Updates a single [AlertRow] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<AlertRow?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<AlertRowUpdateTable> columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<AlertRow>(
      id,
      columnValues: columnValues(AlertRow.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [AlertRow]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<AlertRow>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<AlertRowUpdateTable> columnValues,
    required _is.WhereExpressionBuilder<AlertRowTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<AlertRow>(
      columnValues: columnValues(AlertRow.t.updateTable),
      where: where(AlertRow.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [AlertRow]s in the list and returns the deleted rows.
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
  Future<List<AlertRow>> delete(
    _is.DatabaseSession session,
    List<AlertRow> rows, {
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<AlertRow>(
      rows,
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [AlertRow].
  Future<AlertRow> deleteRow(
    _is.DatabaseSession session,
    AlertRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<AlertRow>(
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
  Future<List<AlertRow>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<AlertRowTable> where,
    _is.OrderByBuilder<AlertRowTable>? orderBy,
    _is.OrderByListBuilder<AlertRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<AlertRow>(
      where: where(AlertRow.t),
      orderBy: orderBy?.call(AlertRow.t),
      orderByList: orderByList?.call(AlertRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<AlertRowTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<AlertRow>(
      where: where?.call(AlertRow.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [AlertRow] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<AlertRowTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<AlertRow>(
      where: where(AlertRow.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
