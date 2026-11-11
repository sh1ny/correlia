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

abstract class ObservationKeyRow
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  ObservationKeyRow._({
    this.id,
    required this.eventId,
    required this.fingerprint,
    required this.sourceTime,
    required this.firstSeenAt,
    required this.disposition,
  });

  factory ObservationKeyRow({
    int? id,
    required _is.UuidValue eventId,
    required String fingerprint,
    required DateTime sourceTime,
    required DateTime firstSeenAt,
    required String disposition,
  }) = _ObservationKeyRowImpl;

  factory ObservationKeyRow.fromJson(Map<String, dynamic> jsonSerialization) {
    return ObservationKeyRow(
      id: jsonSerialization['id'] as int?,
      eventId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['eventId'],
      ),
      fingerprint: jsonSerialization['fingerprint'] as String,
      sourceTime: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['sourceTime'],
      ),
      firstSeenAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['firstSeenAt'],
      ),
      disposition: jsonSerialization['disposition'] as String,
    );
  }

  static final t = ObservationKeyRowTable();

  static const db = ObservationKeyRowRepository._();

  @override
  int? id;

  _is.UuidValue eventId;

  String fingerprint;

  DateTime sourceTime;

  DateTime firstSeenAt;

  String disposition;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [ObservationKeyRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  ObservationKeyRow copyWith({
    int? id,
    _is.UuidValue? eventId,
    String? fingerprint,
    DateTime? sourceTime,
    DateTime? firstSeenAt,
    String? disposition,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'ObservationKeyRow',
      if (id != null) 'id': id,
      'eventId': eventId.toJson(),
      'fingerprint': fingerprint,
      'sourceTime': sourceTime.toJson(),
      'firstSeenAt': firstSeenAt.toJson(),
      'disposition': disposition,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static ObservationKeyRowInclude include() {
    return ObservationKeyRowInclude._();
  }

  static ObservationKeyRowIncludeList includeList({
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    ObservationKeyRowInclude? include,
  }) {
    return ObservationKeyRowIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _ObservationKeyRowImpl extends ObservationKeyRow {
  _ObservationKeyRowImpl({
    int? id,
    required _is.UuidValue eventId,
    required String fingerprint,
    required DateTime sourceTime,
    required DateTime firstSeenAt,
    required String disposition,
  }) : super._(
         id: id,
         eventId: eventId,
         fingerprint: fingerprint,
         sourceTime: sourceTime,
         firstSeenAt: firstSeenAt,
         disposition: disposition,
       );

  /// Returns a shallow copy of this [ObservationKeyRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  ObservationKeyRow copyWith({
    Object? id = _Undefined,
    _is.UuidValue? eventId,
    String? fingerprint,
    DateTime? sourceTime,
    DateTime? firstSeenAt,
    String? disposition,
  }) {
    return ObservationKeyRow(
      id: id is int? ? id : this.id,
      eventId: eventId ?? this.eventId,
      fingerprint: fingerprint ?? this.fingerprint,
      sourceTime: sourceTime ?? this.sourceTime,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      disposition: disposition ?? this.disposition,
    );
  }
}

class ObservationKeyRowUpdateTable
    extends _is.UpdateTable<ObservationKeyRowTable> {
  ObservationKeyRowUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> eventId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.eventId,
        value,
      );

  _is.ColumnValue<String, String> fingerprint(String value) => _is.ColumnValue(
    table.fingerprint,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> sourceTime(DateTime value) =>
      _is.ColumnValue(
        table.sourceTime,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> firstSeenAt(DateTime value) =>
      _is.ColumnValue(
        table.firstSeenAt,
        value,
      );

  _is.ColumnValue<String, String> disposition(String value) => _is.ColumnValue(
    table.disposition,
    value,
  );
}

class ObservationKeyRowTable extends _is.Table<int?> {
  ObservationKeyRowTable({super.tableRelation})
    : super(tableName: 'observation_keys') {
    updateTable = ObservationKeyRowUpdateTable(this);
    eventId = _is.ColumnUuid(
      'eventId',
      this,
    );
    fingerprint = _is.ColumnString(
      'fingerprint',
      this,
    );
    sourceTime = _is.ColumnDateTime(
      'sourceTime',
      this,
    );
    firstSeenAt = _is.ColumnDateTime(
      'firstSeenAt',
      this,
    );
    disposition = _is.ColumnString(
      'disposition',
      this,
    );
  }

  late final ObservationKeyRowUpdateTable updateTable;

  late final _is.ColumnUuid eventId;

  late final _is.ColumnString fingerprint;

  late final _is.ColumnDateTime sourceTime;

  late final _is.ColumnDateTime firstSeenAt;

  late final _is.ColumnString disposition;

  @override
  List<_is.Column> get columns => [
    id,
    eventId,
    fingerprint,
    sourceTime,
    firstSeenAt,
    disposition,
  ];
}

class ObservationKeyRowInclude extends _is.IncludeObject {
  ObservationKeyRowInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => ObservationKeyRow.t;
}

class ObservationKeyRowIncludeList extends _is.IncludeList {
  ObservationKeyRowIncludeList._({
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(ObservationKeyRow.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => ObservationKeyRow.t;
}

class ObservationKeyRowRepository {
  const ObservationKeyRowRepository._();

  /// Returns a list of [ObservationKeyRow]s matching the given query parameters.
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
  Future<List<ObservationKeyRow>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<ObservationKeyRow>(
      where: where?.call(ObservationKeyRow.t),
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [ObservationKeyRow]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `ObservationKeyRow.t`.
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
  _ida.Stream<List<ObservationKeyRow>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<ObservationKeyRow>(
      where: where?.call(ObservationKeyRow.t),
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [ObservationKeyRow] matching the given query parameters.
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
  Future<ObservationKeyRow?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    int? offset,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<ObservationKeyRow>(
      where: where?.call(ObservationKeyRow.t),
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [ObservationKeyRow] by its [id] or null if no such row exists.
  Future<ObservationKeyRow?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<ObservationKeyRow>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [ObservationKeyRow]s in the list and returns the inserted rows.
  ///
  /// The returned [ObservationKeyRow]s will have their `id` fields set.
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
  Future<List<ObservationKeyRow>> insert(
    _is.DatabaseSession session,
    List<ObservationKeyRow> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<ObservationKeyRow>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [ObservationKeyRow] and returns the inserted row.
  ///
  /// The returned [ObservationKeyRow] will have its `id` field set.
  Future<ObservationKeyRow> insertRow(
    _is.DatabaseSession session,
    ObservationKeyRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<ObservationKeyRow>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [ObservationKeyRow]s in the list and returns the resulting rows.
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
  /// The returned [ObservationKeyRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<ObservationKeyRow>> upsert(
    _is.DatabaseSession session,
    List<ObservationKeyRow> rows, {
    required _is.ColumnSelections<ObservationKeyRowTable> conflictColumns,
    _is.ColumnSelections<ObservationKeyRowTable>? updateColumns,
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<ObservationKeyRow>(
      rows,
      conflictColumns: conflictColumns(ObservationKeyRow.t),
      updateColumns: updateColumns?.call(ObservationKeyRow.t),
      updateWhere: updateWhere?.call(ObservationKeyRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [ObservationKeyRow] and returns the resulting row.
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
  /// The returned [ObservationKeyRow] will have its `id` field set.
  Future<ObservationKeyRow?> upsertRow(
    _is.DatabaseSession session,
    ObservationKeyRow row, {
    required _is.ColumnSelections<ObservationKeyRowTable> conflictColumns,
    _is.ColumnSelections<ObservationKeyRowTable>? updateColumns,
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<ObservationKeyRow>(
      row,
      conflictColumns: conflictColumns(ObservationKeyRow.t),
      updateColumns: updateColumns?.call(ObservationKeyRow.t),
      updateWhere: updateWhere?.call(ObservationKeyRow.t),
      transaction: transaction,
    );
  }

  /// Updates all [ObservationKeyRow]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<ObservationKeyRow>> update(
    _is.DatabaseSession session,
    List<ObservationKeyRow> rows, {
    _is.ColumnSelections<ObservationKeyRowTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<ObservationKeyRow>(
      rows,
      columns: columns?.call(ObservationKeyRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [ObservationKeyRow]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<ObservationKeyRow> updateRow(
    _is.DatabaseSession session,
    ObservationKeyRow row, {
    _is.ColumnSelections<ObservationKeyRowTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<ObservationKeyRow>(
      row,
      columns: columns?.call(ObservationKeyRow.t),
      transaction: transaction,
    );
  }

  /// Updates a single [ObservationKeyRow] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<ObservationKeyRow?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<ObservationKeyRowUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<ObservationKeyRow>(
      id,
      columnValues: columnValues(ObservationKeyRow.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [ObservationKeyRow]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<ObservationKeyRow>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<ObservationKeyRowUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<ObservationKeyRowTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<ObservationKeyRow>(
      columnValues: columnValues(ObservationKeyRow.t.updateTable),
      where: where(ObservationKeyRow.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [ObservationKeyRow]s in the list and returns the deleted rows.
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
  Future<List<ObservationKeyRow>> delete(
    _is.DatabaseSession session,
    List<ObservationKeyRow> rows, {
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<ObservationKeyRow>(
      rows,
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [ObservationKeyRow].
  Future<ObservationKeyRow> deleteRow(
    _is.DatabaseSession session,
    ObservationKeyRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<ObservationKeyRow>(
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
  Future<List<ObservationKeyRow>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<ObservationKeyRowTable> where,
    _is.OrderByBuilder<ObservationKeyRowTable>? orderBy,
    _is.OrderByListBuilder<ObservationKeyRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<ObservationKeyRow>(
      where: where(ObservationKeyRow.t),
      orderBy: orderBy?.call(ObservationKeyRow.t),
      orderByList: orderByList?.call(ObservationKeyRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<ObservationKeyRowTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<ObservationKeyRow>(
      where: where?.call(ObservationKeyRow.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [ObservationKeyRow] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<ObservationKeyRowTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<ObservationKeyRow>(
      where: where(ObservationKeyRow.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
