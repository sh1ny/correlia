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

abstract class IngestConfigSnapshot
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  IngestConfigSnapshot._({
    this.id,
    required this.snapshotId,
    required this.revision,
    required this.publicJson,
  });

  factory IngestConfigSnapshot({
    int? id,
    required String snapshotId,
    required int revision,
    required String publicJson,
  }) = _IngestConfigSnapshotImpl;

  factory IngestConfigSnapshot.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return IngestConfigSnapshot(
      id: jsonSerialization['id'] as int?,
      snapshotId: jsonSerialization['snapshotId'] as String,
      revision: jsonSerialization['revision'] as int,
      publicJson: jsonSerialization['publicJson'] as String,
    );
  }

  static final t = IngestConfigSnapshotTable();

  static const db = IngestConfigSnapshotRepository._();

  @override
  int? id;

  String snapshotId;

  int revision;

  String publicJson;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [IngestConfigSnapshot]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  IngestConfigSnapshot copyWith({
    int? id,
    String? snapshotId,
    int? revision,
    String? publicJson,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'IngestConfigSnapshot',
      if (id != null) 'id': id,
      'snapshotId': snapshotId,
      'revision': revision,
      'publicJson': publicJson,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static IngestConfigSnapshotInclude include() {
    return IngestConfigSnapshotInclude._();
  }

  static IngestConfigSnapshotIncludeList includeList({
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    IngestConfigSnapshotInclude? include,
  }) {
    return IngestConfigSnapshotIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _IngestConfigSnapshotImpl extends IngestConfigSnapshot {
  _IngestConfigSnapshotImpl({
    int? id,
    required String snapshotId,
    required int revision,
    required String publicJson,
  }) : super._(
         id: id,
         snapshotId: snapshotId,
         revision: revision,
         publicJson: publicJson,
       );

  /// Returns a shallow copy of this [IngestConfigSnapshot]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  IngestConfigSnapshot copyWith({
    Object? id = _Undefined,
    String? snapshotId,
    int? revision,
    String? publicJson,
  }) {
    return IngestConfigSnapshot(
      id: id is int? ? id : this.id,
      snapshotId: snapshotId ?? this.snapshotId,
      revision: revision ?? this.revision,
      publicJson: publicJson ?? this.publicJson,
    );
  }
}

class IngestConfigSnapshotUpdateTable
    extends _is.UpdateTable<IngestConfigSnapshotTable> {
  IngestConfigSnapshotUpdateTable(super.table);

  _is.ColumnValue<String, String> snapshotId(String value) => _is.ColumnValue(
    table.snapshotId,
    value,
  );

  _is.ColumnValue<int, int> revision(int value) => _is.ColumnValue(
    table.revision,
    value,
  );

  _is.ColumnValue<String, String> publicJson(String value) => _is.ColumnValue(
    table.publicJson,
    value,
  );
}

class IngestConfigSnapshotTable extends _is.Table<int?> {
  IngestConfigSnapshotTable({super.tableRelation})
    : super(tableName: 'ingest_config_snapshot') {
    updateTable = IngestConfigSnapshotUpdateTable(this);
    snapshotId = _is.ColumnString(
      'snapshotId',
      this,
    );
    revision = _is.ColumnInt(
      'revision',
      this,
    );
    publicJson = _is.ColumnString(
      'publicJson',
      this,
    );
  }

  late final IngestConfigSnapshotUpdateTable updateTable;

  late final _is.ColumnString snapshotId;

  late final _is.ColumnInt revision;

  late final _is.ColumnString publicJson;

  @override
  List<_is.Column> get columns => [
    id,
    snapshotId,
    revision,
    publicJson,
  ];
}

class IngestConfigSnapshotInclude extends _is.IncludeObject {
  IngestConfigSnapshotInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => IngestConfigSnapshot.t;
}

class IngestConfigSnapshotIncludeList extends _is.IncludeList {
  IngestConfigSnapshotIncludeList._({
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(IngestConfigSnapshot.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => IngestConfigSnapshot.t;
}

class IngestConfigSnapshotRepository {
  const IngestConfigSnapshotRepository._();

  /// Returns a list of [IngestConfigSnapshot]s matching the given query parameters.
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
  Future<List<IngestConfigSnapshot>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<IngestConfigSnapshot>(
      where: where?.call(IngestConfigSnapshot.t),
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [IngestConfigSnapshot]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `IngestConfigSnapshot.t`.
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
  _ida.Stream<List<IngestConfigSnapshot>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<IngestConfigSnapshot>(
      where: where?.call(IngestConfigSnapshot.t),
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [IngestConfigSnapshot] matching the given query parameters.
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
  Future<IngestConfigSnapshot?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    int? offset,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<IngestConfigSnapshot>(
      where: where?.call(IngestConfigSnapshot.t),
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [IngestConfigSnapshot] by its [id] or null if no such row exists.
  Future<IngestConfigSnapshot?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<IngestConfigSnapshot>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [IngestConfigSnapshot]s in the list and returns the inserted rows.
  ///
  /// The returned [IngestConfigSnapshot]s will have their `id` fields set.
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
  Future<List<IngestConfigSnapshot>> insert(
    _is.DatabaseSession session,
    List<IngestConfigSnapshot> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<IngestConfigSnapshot>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [IngestConfigSnapshot] and returns the inserted row.
  ///
  /// The returned [IngestConfigSnapshot] will have its `id` field set.
  Future<IngestConfigSnapshot> insertRow(
    _is.DatabaseSession session,
    IngestConfigSnapshot row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<IngestConfigSnapshot>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [IngestConfigSnapshot]s in the list and returns the resulting rows.
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
  /// The returned [IngestConfigSnapshot]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestConfigSnapshot>> upsert(
    _is.DatabaseSession session,
    List<IngestConfigSnapshot> rows, {
    required _is.ColumnSelections<IngestConfigSnapshotTable> conflictColumns,
    _is.ColumnSelections<IngestConfigSnapshotTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<IngestConfigSnapshot>(
      rows,
      conflictColumns: conflictColumns(IngestConfigSnapshot.t),
      updateColumns: updateColumns?.call(IngestConfigSnapshot.t),
      updateWhere: updateWhere?.call(IngestConfigSnapshot.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [IngestConfigSnapshot] and returns the resulting row.
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
  /// The returned [IngestConfigSnapshot] will have its `id` field set.
  Future<IngestConfigSnapshot?> upsertRow(
    _is.DatabaseSession session,
    IngestConfigSnapshot row, {
    required _is.ColumnSelections<IngestConfigSnapshotTable> conflictColumns,
    _is.ColumnSelections<IngestConfigSnapshotTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<IngestConfigSnapshot>(
      row,
      conflictColumns: conflictColumns(IngestConfigSnapshot.t),
      updateColumns: updateColumns?.call(IngestConfigSnapshot.t),
      updateWhere: updateWhere?.call(IngestConfigSnapshot.t),
      transaction: transaction,
    );
  }

  /// Updates all [IngestConfigSnapshot]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestConfigSnapshot>> update(
    _is.DatabaseSession session,
    List<IngestConfigSnapshot> rows, {
    _is.ColumnSelections<IngestConfigSnapshotTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<IngestConfigSnapshot>(
      rows,
      columns: columns?.call(IngestConfigSnapshot.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [IngestConfigSnapshot]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<IngestConfigSnapshot> updateRow(
    _is.DatabaseSession session,
    IngestConfigSnapshot row, {
    _is.ColumnSelections<IngestConfigSnapshotTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<IngestConfigSnapshot>(
      row,
      columns: columns?.call(IngestConfigSnapshot.t),
      transaction: transaction,
    );
  }

  /// Updates a single [IngestConfigSnapshot] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<IngestConfigSnapshot?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<IngestConfigSnapshotUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<IngestConfigSnapshot>(
      id,
      columnValues: columnValues(IngestConfigSnapshot.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [IngestConfigSnapshot]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestConfigSnapshot>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<IngestConfigSnapshotUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<IngestConfigSnapshotTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<IngestConfigSnapshot>(
      columnValues: columnValues(IngestConfigSnapshot.t.updateTable),
      where: where(IngestConfigSnapshot.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [IngestConfigSnapshot]s in the list and returns the deleted rows.
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
  Future<List<IngestConfigSnapshot>> delete(
    _is.DatabaseSession session,
    List<IngestConfigSnapshot> rows, {
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<IngestConfigSnapshot>(
      rows,
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [IngestConfigSnapshot].
  Future<IngestConfigSnapshot> deleteRow(
    _is.DatabaseSession session,
    IngestConfigSnapshot row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<IngestConfigSnapshot>(
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
  Future<List<IngestConfigSnapshot>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestConfigSnapshotTable> where,
    _is.OrderByBuilder<IngestConfigSnapshotTable>? orderBy,
    _is.OrderByListBuilder<IngestConfigSnapshotTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<IngestConfigSnapshot>(
      where: where(IngestConfigSnapshot.t),
      orderBy: orderBy?.call(IngestConfigSnapshot.t),
      orderByList: orderByList?.call(IngestConfigSnapshot.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestConfigSnapshotTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<IngestConfigSnapshot>(
      where: where?.call(IngestConfigSnapshot.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [IngestConfigSnapshot] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestConfigSnapshotTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<IngestConfigSnapshot>(
      where: where(IngestConfigSnapshot.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
