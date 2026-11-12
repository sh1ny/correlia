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

abstract class PluginDefinitionHealth
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  PluginDefinitionHealth._({
    this.id,
    required this.hostInstanceId,
    required this.outputId,
    required this.definitionDigest,
    required this.failureTimes,
    required this.backoffStep,
    this.nextStartAt,
    required this.circuit,
    this.nextProbeAt,
    this.lastErrorClass,
  });

  factory PluginDefinitionHealth({
    int? id,
    required String hostInstanceId,
    required String outputId,
    required String definitionDigest,
    required String failureTimes,
    required int backoffStep,
    DateTime? nextStartAt,
    required String circuit,
    DateTime? nextProbeAt,
    String? lastErrorClass,
  }) = _PluginDefinitionHealthImpl;

  factory PluginDefinitionHealth.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return PluginDefinitionHealth(
      id: jsonSerialization['id'] as int?,
      hostInstanceId: jsonSerialization['hostInstanceId'] as String,
      outputId: jsonSerialization['outputId'] as String,
      definitionDigest: jsonSerialization['definitionDigest'] as String,
      failureTimes: jsonSerialization['failureTimes'] as String,
      backoffStep: jsonSerialization['backoffStep'] as int,
      nextStartAt: jsonSerialization['nextStartAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['nextStartAt'],
            ),
      circuit: jsonSerialization['circuit'] as String,
      nextProbeAt: jsonSerialization['nextProbeAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(
              jsonSerialization['nextProbeAt'],
            ),
      lastErrorClass: jsonSerialization['lastErrorClass'] as String?,
    );
  }

  static final t = PluginDefinitionHealthTable();

  static const db = PluginDefinitionHealthRepository._();

  @override
  int? id;

  String hostInstanceId;

  String outputId;

  String definitionDigest;

  String failureTimes;

  int backoffStep;

  DateTime? nextStartAt;

  String circuit;

  DateTime? nextProbeAt;

  String? lastErrorClass;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [PluginDefinitionHealth]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  PluginDefinitionHealth copyWith({
    int? id,
    String? hostInstanceId,
    String? outputId,
    String? definitionDigest,
    String? failureTimes,
    int? backoffStep,
    DateTime? nextStartAt = const _is.$UndefinedDateTime(),
    String? circuit,
    DateTime? nextProbeAt = const _is.$UndefinedDateTime(),
    String? lastErrorClass,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'PluginDefinitionHealth',
      if (id != null) 'id': id,
      'hostInstanceId': hostInstanceId,
      'outputId': outputId,
      'definitionDigest': definitionDigest,
      'failureTimes': failureTimes,
      'backoffStep': backoffStep,
      if (nextStartAt != null) 'nextStartAt': nextStartAt?.toJson(),
      'circuit': circuit,
      if (nextProbeAt != null) 'nextProbeAt': nextProbeAt?.toJson(),
      if (lastErrorClass != null) 'lastErrorClass': lastErrorClass,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static PluginDefinitionHealthInclude include() {
    return PluginDefinitionHealthInclude._();
  }

  static PluginDefinitionHealthIncludeList includeList({
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    PluginDefinitionHealthInclude? include,
  }) {
    return PluginDefinitionHealthIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _PluginDefinitionHealthImpl extends PluginDefinitionHealth {
  _PluginDefinitionHealthImpl({
    int? id,
    required String hostInstanceId,
    required String outputId,
    required String definitionDigest,
    required String failureTimes,
    required int backoffStep,
    DateTime? nextStartAt,
    required String circuit,
    DateTime? nextProbeAt,
    String? lastErrorClass,
  }) : super._(
         id: id,
         hostInstanceId: hostInstanceId,
         outputId: outputId,
         definitionDigest: definitionDigest,
         failureTimes: failureTimes,
         backoffStep: backoffStep,
         nextStartAt: nextStartAt,
         circuit: circuit,
         nextProbeAt: nextProbeAt,
         lastErrorClass: lastErrorClass,
       );

  /// Returns a shallow copy of this [PluginDefinitionHealth]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  PluginDefinitionHealth copyWith({
    Object? id = _Undefined,
    String? hostInstanceId,
    String? outputId,
    String? definitionDigest,
    String? failureTimes,
    int? backoffStep,
    DateTime? nextStartAt = const _is.$UndefinedDateTime(),
    String? circuit,
    DateTime? nextProbeAt = const _is.$UndefinedDateTime(),
    Object? lastErrorClass = _Undefined,
  }) {
    return PluginDefinitionHealth(
      id: id is int? ? id : this.id,
      hostInstanceId: hostInstanceId ?? this.hostInstanceId,
      outputId: outputId ?? this.outputId,
      definitionDigest: definitionDigest ?? this.definitionDigest,
      failureTimes: failureTimes ?? this.failureTimes,
      backoffStep: backoffStep ?? this.backoffStep,
      nextStartAt: nextStartAt is _is.UndefinedSentinel
          ? this.nextStartAt
          : nextStartAt,
      circuit: circuit ?? this.circuit,
      nextProbeAt: nextProbeAt is _is.UndefinedSentinel
          ? this.nextProbeAt
          : nextProbeAt,
      lastErrorClass: lastErrorClass is String?
          ? lastErrorClass
          : this.lastErrorClass,
    );
  }
}

class PluginDefinitionHealthUpdateTable
    extends _is.UpdateTable<PluginDefinitionHealthTable> {
  PluginDefinitionHealthUpdateTable(super.table);

  _is.ColumnValue<String, String> hostInstanceId(String value) =>
      _is.ColumnValue(
        table.hostInstanceId,
        value,
      );

  _is.ColumnValue<String, String> outputId(String value) => _is.ColumnValue(
    table.outputId,
    value,
  );

  _is.ColumnValue<String, String> definitionDigest(String value) =>
      _is.ColumnValue(
        table.definitionDigest,
        value,
      );

  _is.ColumnValue<String, String> failureTimes(String value) => _is.ColumnValue(
    table.failureTimes,
    value,
  );

  _is.ColumnValue<int, int> backoffStep(int value) => _is.ColumnValue(
    table.backoffStep,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> nextStartAt(DateTime? value) =>
      _is.ColumnValue(
        table.nextStartAt,
        value,
      );

  _is.ColumnValue<String, String> circuit(String value) => _is.ColumnValue(
    table.circuit,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> nextProbeAt(DateTime? value) =>
      _is.ColumnValue(
        table.nextProbeAt,
        value,
      );

  _is.ColumnValue<String, String> lastErrorClass(String? value) =>
      _is.ColumnValue(
        table.lastErrorClass,
        value,
      );
}

class PluginDefinitionHealthTable extends _is.Table<int?> {
  PluginDefinitionHealthTable({super.tableRelation})
    : super(tableName: 'plugin_definition_health') {
    updateTable = PluginDefinitionHealthUpdateTable(this);
    hostInstanceId = _is.ColumnString(
      'hostInstanceId',
      this,
    );
    outputId = _is.ColumnString(
      'outputId',
      this,
    );
    definitionDigest = _is.ColumnString(
      'definitionDigest',
      this,
    );
    failureTimes = _is.ColumnString(
      'failureTimes',
      this,
    );
    backoffStep = _is.ColumnInt(
      'backoffStep',
      this,
    );
    nextStartAt = _is.ColumnDateTime(
      'nextStartAt',
      this,
    );
    circuit = _is.ColumnString(
      'circuit',
      this,
    );
    nextProbeAt = _is.ColumnDateTime(
      'nextProbeAt',
      this,
    );
    lastErrorClass = _is.ColumnString(
      'lastErrorClass',
      this,
    );
  }

  late final PluginDefinitionHealthUpdateTable updateTable;

  late final _is.ColumnString hostInstanceId;

  late final _is.ColumnString outputId;

  late final _is.ColumnString definitionDigest;

  late final _is.ColumnString failureTimes;

  late final _is.ColumnInt backoffStep;

  late final _is.ColumnDateTime nextStartAt;

  late final _is.ColumnString circuit;

  late final _is.ColumnDateTime nextProbeAt;

  late final _is.ColumnString lastErrorClass;

  @override
  List<_is.Column> get columns => [
    id,
    hostInstanceId,
    outputId,
    definitionDigest,
    failureTimes,
    backoffStep,
    nextStartAt,
    circuit,
    nextProbeAt,
    lastErrorClass,
  ];
}

class PluginDefinitionHealthInclude extends _is.IncludeObject {
  PluginDefinitionHealthInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => PluginDefinitionHealth.t;
}

class PluginDefinitionHealthIncludeList extends _is.IncludeList {
  PluginDefinitionHealthIncludeList._({
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(PluginDefinitionHealth.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => PluginDefinitionHealth.t;
}

class PluginDefinitionHealthRepository {
  const PluginDefinitionHealthRepository._();

  /// Returns a list of [PluginDefinitionHealth]s matching the given query parameters.
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
  Future<List<PluginDefinitionHealth>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<PluginDefinitionHealth>(
      where: where?.call(PluginDefinitionHealth.t),
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [PluginDefinitionHealth]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `PluginDefinitionHealth.t`.
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
  _ida.Stream<List<PluginDefinitionHealth>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<PluginDefinitionHealth>(
      where: where?.call(PluginDefinitionHealth.t),
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [PluginDefinitionHealth] matching the given query parameters.
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
  Future<PluginDefinitionHealth?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    int? offset,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<PluginDefinitionHealth>(
      where: where?.call(PluginDefinitionHealth.t),
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [PluginDefinitionHealth] by its [id] or null if no such row exists.
  Future<PluginDefinitionHealth?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<PluginDefinitionHealth>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [PluginDefinitionHealth]s in the list and returns the inserted rows.
  ///
  /// The returned [PluginDefinitionHealth]s will have their `id` fields set.
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
  Future<List<PluginDefinitionHealth>> insert(
    _is.DatabaseSession session,
    List<PluginDefinitionHealth> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<PluginDefinitionHealth>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [PluginDefinitionHealth] and returns the inserted row.
  ///
  /// The returned [PluginDefinitionHealth] will have its `id` field set.
  Future<PluginDefinitionHealth> insertRow(
    _is.DatabaseSession session,
    PluginDefinitionHealth row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<PluginDefinitionHealth>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [PluginDefinitionHealth]s in the list and returns the resulting rows.
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
  /// The returned [PluginDefinitionHealth]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginDefinitionHealth>> upsert(
    _is.DatabaseSession session,
    List<PluginDefinitionHealth> rows, {
    required _is.ColumnSelections<PluginDefinitionHealthTable> conflictColumns,
    _is.ColumnSelections<PluginDefinitionHealthTable>? updateColumns,
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<PluginDefinitionHealth>(
      rows,
      conflictColumns: conflictColumns(PluginDefinitionHealth.t),
      updateColumns: updateColumns?.call(PluginDefinitionHealth.t),
      updateWhere: updateWhere?.call(PluginDefinitionHealth.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [PluginDefinitionHealth] and returns the resulting row.
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
  /// The returned [PluginDefinitionHealth] will have its `id` field set.
  Future<PluginDefinitionHealth?> upsertRow(
    _is.DatabaseSession session,
    PluginDefinitionHealth row, {
    required _is.ColumnSelections<PluginDefinitionHealthTable> conflictColumns,
    _is.ColumnSelections<PluginDefinitionHealthTable>? updateColumns,
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<PluginDefinitionHealth>(
      row,
      conflictColumns: conflictColumns(PluginDefinitionHealth.t),
      updateColumns: updateColumns?.call(PluginDefinitionHealth.t),
      updateWhere: updateWhere?.call(PluginDefinitionHealth.t),
      transaction: transaction,
    );
  }

  /// Updates all [PluginDefinitionHealth]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginDefinitionHealth>> update(
    _is.DatabaseSession session,
    List<PluginDefinitionHealth> rows, {
    _is.ColumnSelections<PluginDefinitionHealthTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<PluginDefinitionHealth>(
      rows,
      columns: columns?.call(PluginDefinitionHealth.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [PluginDefinitionHealth]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<PluginDefinitionHealth> updateRow(
    _is.DatabaseSession session,
    PluginDefinitionHealth row, {
    _is.ColumnSelections<PluginDefinitionHealthTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<PluginDefinitionHealth>(
      row,
      columns: columns?.call(PluginDefinitionHealth.t),
      transaction: transaction,
    );
  }

  /// Updates a single [PluginDefinitionHealth] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<PluginDefinitionHealth?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<PluginDefinitionHealthUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<PluginDefinitionHealth>(
      id,
      columnValues: columnValues(PluginDefinitionHealth.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [PluginDefinitionHealth]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginDefinitionHealth>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<PluginDefinitionHealthUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<PluginDefinitionHealthTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<PluginDefinitionHealth>(
      columnValues: columnValues(PluginDefinitionHealth.t.updateTable),
      where: where(PluginDefinitionHealth.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [PluginDefinitionHealth]s in the list and returns the deleted rows.
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
  Future<List<PluginDefinitionHealth>> delete(
    _is.DatabaseSession session,
    List<PluginDefinitionHealth> rows, {
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<PluginDefinitionHealth>(
      rows,
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [PluginDefinitionHealth].
  Future<PluginDefinitionHealth> deleteRow(
    _is.DatabaseSession session,
    PluginDefinitionHealth row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<PluginDefinitionHealth>(
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
  Future<List<PluginDefinitionHealth>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PluginDefinitionHealthTable> where,
    _is.OrderByBuilder<PluginDefinitionHealthTable>? orderBy,
    _is.OrderByListBuilder<PluginDefinitionHealthTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<PluginDefinitionHealth>(
      where: where(PluginDefinitionHealth.t),
      orderBy: orderBy?.call(PluginDefinitionHealth.t),
      orderByList: orderByList?.call(PluginDefinitionHealth.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginDefinitionHealthTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<PluginDefinitionHealth>(
      where: where?.call(PluginDefinitionHealth.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [PluginDefinitionHealth] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PluginDefinitionHealthTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<PluginDefinitionHealth>(
      where: where(PluginDefinitionHealth.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
