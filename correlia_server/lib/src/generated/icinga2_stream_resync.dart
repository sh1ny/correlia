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

abstract class Icinga2StreamResyncRow
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  Icinga2StreamResyncRow._({
    this.id,
    required this.sourceId,
    int? requestSeq,
  }) : requestSeq = requestSeq ?? 0;

  factory Icinga2StreamResyncRow({
    int? id,
    required _is.UuidValue sourceId,
    int? requestSeq,
  }) = _Icinga2StreamResyncRowImpl;

  factory Icinga2StreamResyncRow.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return Icinga2StreamResyncRow(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      requestSeq: jsonSerialization['requestSeq'] as int?,
    );
  }

  static final t = Icinga2StreamResyncRowTable();

  static const db = Icinga2StreamResyncRowRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  int requestSeq;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [Icinga2StreamResyncRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  Icinga2StreamResyncRow copyWith({
    int? id,
    _is.UuidValue? sourceId,
    int? requestSeq,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'Icinga2StreamResyncRow',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'requestSeq': requestSeq,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static Icinga2StreamResyncRowInclude include() {
    return Icinga2StreamResyncRowInclude._();
  }

  static Icinga2StreamResyncRowIncludeList includeList({
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    Icinga2StreamResyncRowInclude? include,
  }) {
    return Icinga2StreamResyncRowIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _Icinga2StreamResyncRowImpl extends Icinga2StreamResyncRow {
  _Icinga2StreamResyncRowImpl({
    int? id,
    required _is.UuidValue sourceId,
    int? requestSeq,
  }) : super._(
         id: id,
         sourceId: sourceId,
         requestSeq: requestSeq,
       );

  /// Returns a shallow copy of this [Icinga2StreamResyncRow]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  Icinga2StreamResyncRow copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    int? requestSeq,
  }) {
    return Icinga2StreamResyncRow(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      requestSeq: requestSeq ?? this.requestSeq,
    );
  }
}

class Icinga2StreamResyncRowUpdateTable
    extends _is.UpdateTable<Icinga2StreamResyncRowTable> {
  Icinga2StreamResyncRowUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<int, int> requestSeq(int value) => _is.ColumnValue(
    table.requestSeq,
    value,
  );
}

class Icinga2StreamResyncRowTable extends _is.Table<int?> {
  Icinga2StreamResyncRowTable({super.tableRelation})
    : super(tableName: 'icinga2_stream_resync') {
    updateTable = Icinga2StreamResyncRowUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    requestSeq = _is.ColumnInt(
      'requestSeq',
      this,
      hasDefault: true,
    );
  }

  late final Icinga2StreamResyncRowUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnInt requestSeq;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    requestSeq,
  ];
}

class Icinga2StreamResyncRowInclude extends _is.IncludeObject {
  Icinga2StreamResyncRowInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => Icinga2StreamResyncRow.t;
}

class Icinga2StreamResyncRowIncludeList extends _is.IncludeList {
  Icinga2StreamResyncRowIncludeList._({
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(Icinga2StreamResyncRow.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => Icinga2StreamResyncRow.t;
}

class Icinga2StreamResyncRowRepository {
  const Icinga2StreamResyncRowRepository._();

  /// Returns a list of [Icinga2StreamResyncRow]s matching the given query parameters.
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
  Future<List<Icinga2StreamResyncRow>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<Icinga2StreamResyncRow>(
      where: where?.call(Icinga2StreamResyncRow.t),
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [Icinga2StreamResyncRow]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `Icinga2StreamResyncRow.t`.
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
  _ida.Stream<List<Icinga2StreamResyncRow>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<Icinga2StreamResyncRow>(
      where: where?.call(Icinga2StreamResyncRow.t),
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [Icinga2StreamResyncRow] matching the given query parameters.
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
  Future<Icinga2StreamResyncRow?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<Icinga2StreamResyncRow>(
      where: where?.call(Icinga2StreamResyncRow.t),
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [Icinga2StreamResyncRow] by its [id] or null if no such row exists.
  Future<Icinga2StreamResyncRow?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<Icinga2StreamResyncRow>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [Icinga2StreamResyncRow]s in the list and returns the inserted rows.
  ///
  /// The returned [Icinga2StreamResyncRow]s will have their `id` fields set.
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
  Future<List<Icinga2StreamResyncRow>> insert(
    _is.DatabaseSession session,
    List<Icinga2StreamResyncRow> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<Icinga2StreamResyncRow>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [Icinga2StreamResyncRow] and returns the inserted row.
  ///
  /// The returned [Icinga2StreamResyncRow] will have its `id` field set.
  Future<Icinga2StreamResyncRow> insertRow(
    _is.DatabaseSession session,
    Icinga2StreamResyncRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<Icinga2StreamResyncRow>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [Icinga2StreamResyncRow]s in the list and returns the resulting rows.
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
  /// The returned [Icinga2StreamResyncRow]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamResyncRow>> upsert(
    _is.DatabaseSession session,
    List<Icinga2StreamResyncRow> rows, {
    required _is.ColumnSelections<Icinga2StreamResyncRowTable> conflictColumns,
    _is.ColumnSelections<Icinga2StreamResyncRowTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<Icinga2StreamResyncRow>(
      rows,
      conflictColumns: conflictColumns(Icinga2StreamResyncRow.t),
      updateColumns: updateColumns?.call(Icinga2StreamResyncRow.t),
      updateWhere: updateWhere?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [Icinga2StreamResyncRow] and returns the resulting row.
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
  /// The returned [Icinga2StreamResyncRow] will have its `id` field set.
  Future<Icinga2StreamResyncRow?> upsertRow(
    _is.DatabaseSession session,
    Icinga2StreamResyncRow row, {
    required _is.ColumnSelections<Icinga2StreamResyncRowTable> conflictColumns,
    _is.ColumnSelections<Icinga2StreamResyncRowTable>? updateColumns,
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<Icinga2StreamResyncRow>(
      row,
      conflictColumns: conflictColumns(Icinga2StreamResyncRow.t),
      updateColumns: updateColumns?.call(Icinga2StreamResyncRow.t),
      updateWhere: updateWhere?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2StreamResyncRow]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamResyncRow>> update(
    _is.DatabaseSession session,
    List<Icinga2StreamResyncRow> rows, {
    _is.ColumnSelections<Icinga2StreamResyncRowTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<Icinga2StreamResyncRow>(
      rows,
      columns: columns?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [Icinga2StreamResyncRow]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<Icinga2StreamResyncRow> updateRow(
    _is.DatabaseSession session,
    Icinga2StreamResyncRow row, {
    _is.ColumnSelections<Icinga2StreamResyncRowTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<Icinga2StreamResyncRow>(
      row,
      columns: columns?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
    );
  }

  /// Updates a single [Icinga2StreamResyncRow] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<Icinga2StreamResyncRow?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<Icinga2StreamResyncRowUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<Icinga2StreamResyncRow>(
      id,
      columnValues: columnValues(Icinga2StreamResyncRow.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [Icinga2StreamResyncRow]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<Icinga2StreamResyncRow>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<Icinga2StreamResyncRowUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<Icinga2StreamResyncRow>(
      columnValues: columnValues(Icinga2StreamResyncRow.t.updateTable),
      where: where(Icinga2StreamResyncRow.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [Icinga2StreamResyncRow]s in the list and returns the deleted rows.
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
  Future<List<Icinga2StreamResyncRow>> delete(
    _is.DatabaseSession session,
    List<Icinga2StreamResyncRow> rows, {
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<Icinga2StreamResyncRow>(
      rows,
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [Icinga2StreamResyncRow].
  Future<Icinga2StreamResyncRow> deleteRow(
    _is.DatabaseSession session,
    Icinga2StreamResyncRow row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<Icinga2StreamResyncRow>(
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
  Future<List<Icinga2StreamResyncRow>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable> where,
    _is.OrderByBuilder<Icinga2StreamResyncRowTable>? orderBy,
    _is.OrderByListBuilder<Icinga2StreamResyncRowTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<Icinga2StreamResyncRow>(
      where: where(Icinga2StreamResyncRow.t),
      orderBy: orderBy?.call(Icinga2StreamResyncRow.t),
      orderByList: orderByList?.call(Icinga2StreamResyncRow.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<Icinga2StreamResyncRow>(
      where: where?.call(Icinga2StreamResyncRow.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [Icinga2StreamResyncRow] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<Icinga2StreamResyncRowTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<Icinga2StreamResyncRow>(
      where: where(Icinga2StreamResyncRow.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
