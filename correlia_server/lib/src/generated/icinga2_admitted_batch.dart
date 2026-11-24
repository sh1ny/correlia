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

abstract class Icinga2AdmittedBatch
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  Icinga2AdmittedBatch._({
    this.id,
    required this.sourceId,
    required this.batchId,
    required this.admittedAt,
  });

  factory Icinga2AdmittedBatch({
    int? id,
    required _is.UuidValue sourceId,
    required _is.UuidValue batchId,
    required DateTime admittedAt,
  }) = _Icinga2AdmittedBatchImpl;

  factory Icinga2AdmittedBatch.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return Icinga2AdmittedBatch(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      batchId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['batchId'],
      ),
      admittedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['admittedAt'],
      ),
    );
  }

  static final t = Icinga2AdmittedBatchTable();

  static const db = Icinga2AdmittedBatchRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  _is.UuidValue batchId;

  DateTime admittedAt;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [Icinga2AdmittedBatch]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  Icinga2AdmittedBatch copyWith({
    int? id,
    _is.UuidValue? sourceId,
    _is.UuidValue? batchId,
    DateTime? admittedAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Icinga2AdmittedBatch',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'batchId': batchId.toJson(),
      'admittedAt': admittedAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static Icinga2AdmittedBatchInclude include() {
    return Icinga2AdmittedBatchInclude._();
  }

  static Icinga2AdmittedBatchIncludeList includeList({
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    Icinga2AdmittedBatchInclude? include,
  }) {
    return Icinga2AdmittedBatchIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _Icinga2AdmittedBatchImpl extends Icinga2AdmittedBatch {
  _Icinga2AdmittedBatchImpl({
    int? id,
    required _is.UuidValue sourceId,
    required _is.UuidValue batchId,
    required DateTime admittedAt,
  }) : super._(
         id: id,
         sourceId: sourceId,
         batchId: batchId,
         admittedAt: admittedAt,
       );

  /// Returns a shallow copy of this [Icinga2AdmittedBatch]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  Icinga2AdmittedBatch copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    _is.UuidValue? batchId,
    DateTime? admittedAt,
  }) {
    return Icinga2AdmittedBatch(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      batchId: batchId ?? this.batchId,
      admittedAt: admittedAt ?? this.admittedAt,
    );
  }
}

class Icinga2AdmittedBatchUpdateTable
    extends _is.UpdateTable<Icinga2AdmittedBatchTable> {
  Icinga2AdmittedBatchUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> batchId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.batchId,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> admittedAt(DateTime value) =>
      _is.ColumnValue(
        table.admittedAt,
        value,
      );
}

class Icinga2AdmittedBatchTable extends _is.Table<int?> {
  Icinga2AdmittedBatchTable({super.tableRelation})
    : super(tableName: 'icinga2_admitted_batch') {
    updateTable = Icinga2AdmittedBatchUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    batchId = _is.ColumnUuid(
      'batchId',
      this,
    );
    admittedAt = _is.ColumnDateTime(
      'admittedAt',
      this,
    );
  }

  late final Icinga2AdmittedBatchUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnUuid batchId;

  late final _is.ColumnDateTime admittedAt;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    batchId,
    admittedAt,
  ];
}

class Icinga2AdmittedBatchInclude extends _is.IncludeObject {
  Icinga2AdmittedBatchInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => Icinga2AdmittedBatch.t;
}

class Icinga2AdmittedBatchIncludeList extends _is.IncludeList {
  Icinga2AdmittedBatchIncludeList._({
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(Icinga2AdmittedBatch.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => Icinga2AdmittedBatch.t;
}

class Icinga2AdmittedBatchRepository {
  const Icinga2AdmittedBatchRepository._();

  /// Returns a list of [Icinga2AdmittedBatch]s matching the given query parameters.
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
  Future<List<Icinga2AdmittedBatch>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<Icinga2AdmittedBatch>(
      where: where?.call(Icinga2AdmittedBatch.t),
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [Icinga2AdmittedBatch]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `Icinga2AdmittedBatch.t`.
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
  _ida.Stream<List<Icinga2AdmittedBatch>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<Icinga2AdmittedBatch>(
      where: where?.call(Icinga2AdmittedBatch.t),
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [Icinga2AdmittedBatch] matching the given query parameters.
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
  Future<Icinga2AdmittedBatch?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    int? offset,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<Icinga2AdmittedBatch>(
      where: where?.call(Icinga2AdmittedBatch.t),
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [Icinga2AdmittedBatch] by its [id] or null if no such row exists.
  Future<Icinga2AdmittedBatch?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<Icinga2AdmittedBatch>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [Icinga2AdmittedBatch]s in the list and returns the inserted rows.
  ///
  /// The returned [Icinga2AdmittedBatch]s will have their `id` fields set.
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
  Future<List<Icinga2AdmittedBatch>> insert(
    _is.DatabaseSession session,
    List<Icinga2AdmittedBatch> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<Icinga2AdmittedBatch>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [Icinga2AdmittedBatch] and returns the inserted row.
  ///
  /// The returned [Icinga2AdmittedBatch] will have its `id` field set.
  Future<Icinga2AdmittedBatch> insertRow(
    _is.DatabaseSession session,
    Icinga2AdmittedBatch row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<Icinga2AdmittedBatch>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [Icinga2AdmittedBatch]s in the list and returns the resulting rows.
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
  /// The returned [Icinga2AdmittedBatch]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2AdmittedBatch>> upsert(
    _is.DatabaseSession session,
    List<Icinga2AdmittedBatch> rows, {
    required _is.ColumnSelections<Icinga2AdmittedBatchTable> conflictColumns,
    _is.ColumnSelections<Icinga2AdmittedBatchTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<Icinga2AdmittedBatch>(
      rows,
      conflictColumns: conflictColumns(Icinga2AdmittedBatch.t),
      updateColumns: updateColumns?.call(Icinga2AdmittedBatch.t),
      updateWhere: updateWhere?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [Icinga2AdmittedBatch] and returns the resulting row.
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
  /// The returned [Icinga2AdmittedBatch] will have its `id` field set.
  Future<Icinga2AdmittedBatch?> upsertRow(
    _is.DatabaseSession session,
    Icinga2AdmittedBatch row, {
    required _is.ColumnSelections<Icinga2AdmittedBatchTable> conflictColumns,
    _is.ColumnSelections<Icinga2AdmittedBatchTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<Icinga2AdmittedBatch>(
      row,
      conflictColumns: conflictColumns(Icinga2AdmittedBatch.t),
      updateColumns: updateColumns?.call(Icinga2AdmittedBatch.t),
      updateWhere: updateWhere?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2AdmittedBatch]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2AdmittedBatch>> update(
    _is.DatabaseSession session,
    List<Icinga2AdmittedBatch> rows, {
    _is.ColumnSelections<Icinga2AdmittedBatchTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<Icinga2AdmittedBatch>(
      rows,
      columns: columns?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [Icinga2AdmittedBatch]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<Icinga2AdmittedBatch> updateRow(
    _is.DatabaseSession session,
    Icinga2AdmittedBatch row, {
    _is.ColumnSelections<Icinga2AdmittedBatchTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<Icinga2AdmittedBatch>(
      row,
      columns: columns?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
    );
  }

  /// Updates a single [Icinga2AdmittedBatch] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<Icinga2AdmittedBatch?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<Icinga2AdmittedBatchUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<Icinga2AdmittedBatch>(
      id,
      columnValues: columnValues(Icinga2AdmittedBatch.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2AdmittedBatch]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2AdmittedBatch>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<Icinga2AdmittedBatchUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<Icinga2AdmittedBatch>(
      columnValues: columnValues(Icinga2AdmittedBatch.t.updateTable),
      where: where(Icinga2AdmittedBatch.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [Icinga2AdmittedBatch]s in the list and returns the deleted rows.
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
  Future<List<Icinga2AdmittedBatch>> delete(
    _is.DatabaseSession session,
    List<Icinga2AdmittedBatch> rows, {
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<Icinga2AdmittedBatch>(
      rows,
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [Icinga2AdmittedBatch].
  Future<Icinga2AdmittedBatch> deleteRow(
    _is.DatabaseSession session,
    Icinga2AdmittedBatch row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<Icinga2AdmittedBatch>(
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
  Future<List<Icinga2AdmittedBatch>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable> where,
    _is.OrderByBuilder<Icinga2AdmittedBatchTable>? orderBy,
    _is.OrderByListBuilder<Icinga2AdmittedBatchTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<Icinga2AdmittedBatch>(
      where: where(Icinga2AdmittedBatch.t),
      orderBy: orderBy?.call(Icinga2AdmittedBatch.t),
      orderByList: orderByList?.call(Icinga2AdmittedBatch.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<Icinga2AdmittedBatch>(
      where: where?.call(Icinga2AdmittedBatch.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [Icinga2AdmittedBatch] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2AdmittedBatchTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<Icinga2AdmittedBatch>(
      where: where(Icinga2AdmittedBatch.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
