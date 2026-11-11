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

abstract class IngestSourceRow
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  IngestSourceRow._({
    this.id,
    required this.sourceId,
    required this.tokenDigest,
    required this.enabled,
    required this.allowPathToken,
  });

  factory IngestSourceRow({
    int? id,
    required _is.UuidValue sourceId,
    required String tokenDigest,
    required bool enabled,
    required bool allowPathToken,
  }) = _IngestSourceRowImpl;

  factory IngestSourceRow.fromJson(Map<String, dynamic> jsonSerialization) {
    return IngestSourceRow(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      tokenDigest: jsonSerialization['tokenDigest'] as String,
      enabled: _is.BoolJsonExtension.fromJson(jsonSerialization['enabled']),
      allowPathToken: _is.BoolJsonExtension.fromJson(
        jsonSerialization['allowPathToken'],
      ),
    );
  }

  static final t = IngestSourceRowTable();

  static const db = IngestSourceRowRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  String tokenDigest;

  bool enabled;

  bool allowPathToken;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [IngestSourceRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  IngestSourceRow copyWith({
    int? id,
    _is.UuidValue? sourceId,
    String? tokenDigest,
    bool? enabled,
    bool? allowPathToken,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'IngestSourceRow',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'tokenDigest': tokenDigest,
      'enabled': enabled,
      'allowPathToken': allowPathToken,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static IngestSourceRowInclude include() {
    return IngestSourceRowInclude._();
  }

  static IngestSourceRowIncludeList includeList({
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    IngestSourceRowInclude? include,
  }) {
    return IngestSourceRowIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _IngestSourceRowImpl extends IngestSourceRow {
  _IngestSourceRowImpl({
    int? id,
    required _is.UuidValue sourceId,
    required String tokenDigest,
    required bool enabled,
    required bool allowPathToken,
  }) : super._(
         id: id,
         sourceId: sourceId,
         tokenDigest: tokenDigest,
         enabled: enabled,
         allowPathToken: allowPathToken,
       );

  /// Returns a shallow copy of this [IngestSourceRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  IngestSourceRow copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    String? tokenDigest,
    bool? enabled,
    bool? allowPathToken,
  }) {
    return IngestSourceRow(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      tokenDigest: tokenDigest ?? this.tokenDigest,
      enabled: enabled ?? this.enabled,
      allowPathToken: allowPathToken ?? this.allowPathToken,
    );
  }
}

class IngestSourceRowUpdateTable extends _is.UpdateTable<IngestSourceRowTable> {
  IngestSourceRowUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<String, String> tokenDigest(String value) => _is.ColumnValue(
    table.tokenDigest,
    value,
  );

  _is.ColumnValue<bool, bool> enabled(bool value) => _is.ColumnValue(
    table.enabled,
    value,
  );

  _is.ColumnValue<bool, bool> allowPathToken(bool value) => _is.ColumnValue(
    table.allowPathToken,
    value,
  );
}

class IngestSourceRowTable extends _is.Table<int?> {
  IngestSourceRowTable({super.tableRelation})
    : super(tableName: 'ingest_source') {
    updateTable = IngestSourceRowUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    tokenDigest = _is.ColumnString(
      'tokenDigest',
      this,
    );
    enabled = _is.ColumnBool(
      'enabled',
      this,
    );
    allowPathToken = _is.ColumnBool(
      'allowPathToken',
      this,
    );
  }

  late final IngestSourceRowUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnString tokenDigest;

  late final _is.ColumnBool enabled;

  late final _is.ColumnBool allowPathToken;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    tokenDigest,
    enabled,
    allowPathToken,
  ];
}

class IngestSourceRowInclude extends _is.IncludeObject {
  IngestSourceRowInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => IngestSourceRow.t;
}

class IngestSourceRowIncludeList extends _is.IncludeList {
  IngestSourceRowIncludeList._({
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(IngestSourceRow.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => IngestSourceRow.t;
}

class IngestSourceRowRepository {
  const IngestSourceRowRepository._();

  /// Returns a list of [IngestSourceRow]s matching the given query parameters.
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
  Future<List<IngestSourceRow>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<IngestSourceRow>(
      where: where?.call(IngestSourceRow.t),
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [IngestSourceRow]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `IngestSourceRow.t`.
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
  _ida.Stream<List<IngestSourceRow>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<IngestSourceRow>(
      where: where?.call(IngestSourceRow.t),
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [IngestSourceRow] matching the given query parameters.
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
  Future<IngestSourceRow?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    int? offset,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<IngestSourceRow>(
      where: where?.call(IngestSourceRow.t),
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [IngestSourceRow] by its [id] or null if no such row exists.
  Future<IngestSourceRow?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<IngestSourceRow>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [IngestSourceRow]s in the list and returns the inserted rows.
  ///
  /// The returned [IngestSourceRow]s will have their `id` fields set.
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
  Future<List<IngestSourceRow>> insert(
    _is.DatabaseSession session,
    List<IngestSourceRow> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<IngestSourceRow>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [IngestSourceRow] and returns the inserted row.
  ///
  /// The returned [IngestSourceRow] will have its `id` field set.
  Future<IngestSourceRow> insertRow(
    _is.DatabaseSession session,
    IngestSourceRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<IngestSourceRow>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [IngestSourceRow]s in the list and returns the resulting rows.
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
  /// The returned [IngestSourceRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceRow>> upsert(
    _is.DatabaseSession session,
    List<IngestSourceRow> rows, {
    required _is.ColumnSelections<IngestSourceRowTable> conflictColumns,
    _is.ColumnSelections<IngestSourceRowTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSourceRowTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<IngestSourceRow>(
      rows,
      conflictColumns: conflictColumns(IngestSourceRow.t),
      updateColumns: updateColumns?.call(IngestSourceRow.t),
      updateWhere: updateWhere?.call(IngestSourceRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [IngestSourceRow] and returns the resulting row.
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
  /// The returned [IngestSourceRow] will have its `id` field set.
  Future<IngestSourceRow?> upsertRow(
    _is.DatabaseSession session,
    IngestSourceRow row, {
    required _is.ColumnSelections<IngestSourceRowTable> conflictColumns,
    _is.ColumnSelections<IngestSourceRowTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSourceRowTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<IngestSourceRow>(
      row,
      conflictColumns: conflictColumns(IngestSourceRow.t),
      updateColumns: updateColumns?.call(IngestSourceRow.t),
      updateWhere: updateWhere?.call(IngestSourceRow.t),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSourceRow]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceRow>> update(
    _is.DatabaseSession session,
    List<IngestSourceRow> rows, {
    _is.ColumnSelections<IngestSourceRowTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<IngestSourceRow>(
      rows,
      columns: columns?.call(IngestSourceRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [IngestSourceRow]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<IngestSourceRow> updateRow(
    _is.DatabaseSession session,
    IngestSourceRow row, {
    _is.ColumnSelections<IngestSourceRowTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<IngestSourceRow>(
      row,
      columns: columns?.call(IngestSourceRow.t),
      transaction: transaction,
    );
  }

  /// Updates a single [IngestSourceRow] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<IngestSourceRow?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<IngestSourceRowUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<IngestSourceRow>(
      id,
      columnValues: columnValues(IngestSourceRow.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSourceRow]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceRow>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<IngestSourceRowUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<IngestSourceRowTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<IngestSourceRow>(
      columnValues: columnValues(IngestSourceRow.t.updateTable),
      where: where(IngestSourceRow.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [IngestSourceRow]s in the list and returns the deleted rows.
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
  Future<List<IngestSourceRow>> delete(
    _is.DatabaseSession session,
    List<IngestSourceRow> rows, {
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<IngestSourceRow>(
      rows,
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [IngestSourceRow].
  Future<IngestSourceRow> deleteRow(
    _is.DatabaseSession session,
    IngestSourceRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<IngestSourceRow>(
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
  Future<List<IngestSourceRow>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSourceRowTable> where,
    _is.OrderByBuilder<IngestSourceRowTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<IngestSourceRow>(
      where: where(IngestSourceRow.t),
      orderBy: orderBy?.call(IngestSourceRow.t),
      orderByList: orderByList?.call(IngestSourceRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceRowTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<IngestSourceRow>(
      where: where?.call(IngestSourceRow.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [IngestSourceRow] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSourceRowTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<IngestSourceRow>(
      where: where(IngestSourceRow.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
