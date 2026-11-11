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

abstract class PipelineFailure
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  PipelineFailure._({
    this.id,
    required this.rawObservedAt,
    required this.rawId,
    this.configSnapshotId,
    required this.errorClass,
    this.fieldPath,
    required this.createdAt,
  });

  factory PipelineFailure({
    int? id,
    required DateTime rawObservedAt,
    required _is.UuidValue rawId,
    String? configSnapshotId,
    required String errorClass,
    String? fieldPath,
    required DateTime createdAt,
  }) = _PipelineFailureImpl;

  factory PipelineFailure.fromJson(Map<String, dynamic> jsonSerialization) {
    return PipelineFailure(
      id: jsonSerialization['id'] as int?,
      rawObservedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['rawObservedAt'],
      ),
      rawId: _is.UuidValueJsonExtension.fromJson(jsonSerialization['rawId']),
      configSnapshotId: jsonSerialization['configSnapshotId'] as String?,
      errorClass: jsonSerialization['errorClass'] as String,
      fieldPath: jsonSerialization['fieldPath'] as String?,
      createdAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['createdAt'],
      ),
    );
  }

  static final t = PipelineFailureTable();

  static const db = PipelineFailureRepository._();

  @override
  int? id;

  DateTime rawObservedAt;

  _is.UuidValue rawId;

  String? configSnapshotId;

  String errorClass;

  String? fieldPath;

  DateTime createdAt;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [PipelineFailure]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  PipelineFailure copyWith({
    int? id,
    DateTime? rawObservedAt,
    _is.UuidValue? rawId,
    String? configSnapshotId,
    String? errorClass,
    String? fieldPath,
    DateTime? createdAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'PipelineFailure',
      if (id != null) 'id': id,
      'rawObservedAt': rawObservedAt.toJson(),
      'rawId': rawId.toJson(),
      if (configSnapshotId != null) 'configSnapshotId': configSnapshotId,
      'errorClass': errorClass,
      if (fieldPath != null) 'fieldPath': fieldPath,
      'createdAt': createdAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static PipelineFailureInclude include() {
    return PipelineFailureInclude._();
  }

  static PipelineFailureIncludeList includeList({
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    PipelineFailureInclude? include,
  }) {
    return PipelineFailureIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _PipelineFailureImpl extends PipelineFailure {
  _PipelineFailureImpl({
    int? id,
    required DateTime rawObservedAt,
    required _is.UuidValue rawId,
    String? configSnapshotId,
    required String errorClass,
    String? fieldPath,
    required DateTime createdAt,
  }) : super._(
         id: id,
         rawObservedAt: rawObservedAt,
         rawId: rawId,
         configSnapshotId: configSnapshotId,
         errorClass: errorClass,
         fieldPath: fieldPath,
         createdAt: createdAt,
       );

  /// Returns a shallow copy of this [PipelineFailure]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  PipelineFailure copyWith({
    Object? id = _Undefined,
    DateTime? rawObservedAt,
    _is.UuidValue? rawId,
    Object? configSnapshotId = _Undefined,
    String? errorClass,
    Object? fieldPath = _Undefined,
    DateTime? createdAt,
  }) {
    return PipelineFailure(
      id: id is int? ? id : this.id,
      rawObservedAt: rawObservedAt ?? this.rawObservedAt,
      rawId: rawId ?? this.rawId,
      configSnapshotId: configSnapshotId is String?
          ? configSnapshotId
          : this.configSnapshotId,
      errorClass: errorClass ?? this.errorClass,
      fieldPath: fieldPath is String? ? fieldPath : this.fieldPath,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class PipelineFailureUpdateTable extends _is.UpdateTable<PipelineFailureTable> {
  PipelineFailureUpdateTable(super.table);

  _is.ColumnValue<DateTime, DateTime> rawObservedAt(DateTime value) =>
      _is.ColumnValue(
        table.rawObservedAt,
        value,
      );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> rawId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.rawId,
        value,
      );

  _is.ColumnValue<String, String> configSnapshotId(String? value) =>
      _is.ColumnValue(
        table.configSnapshotId,
        value,
      );

  _is.ColumnValue<String, String> errorClass(String value) => _is.ColumnValue(
    table.errorClass,
    value,
  );

  _is.ColumnValue<String, String> fieldPath(String? value) => _is.ColumnValue(
    table.fieldPath,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> createdAt(DateTime value) =>
      _is.ColumnValue(
        table.createdAt,
        value,
      );
}

class PipelineFailureTable extends _is.Table<int?> {
  PipelineFailureTable({super.tableRelation})
    : super(tableName: 'pipeline_failures') {
    updateTable = PipelineFailureUpdateTable(this);
    rawObservedAt = _is.ColumnDateTime(
      'rawObservedAt',
      this,
    );
    rawId = _is.ColumnUuid(
      'rawId',
      this,
    );
    configSnapshotId = _is.ColumnString(
      'configSnapshotId',
      this,
    );
    errorClass = _is.ColumnString(
      'errorClass',
      this,
    );
    fieldPath = _is.ColumnString(
      'fieldPath',
      this,
    );
    createdAt = _is.ColumnDateTime(
      'createdAt',
      this,
    );
  }

  late final PipelineFailureUpdateTable updateTable;

  late final _is.ColumnDateTime rawObservedAt;

  late final _is.ColumnUuid rawId;

  late final _is.ColumnString configSnapshotId;

  late final _is.ColumnString errorClass;

  late final _is.ColumnString fieldPath;

  late final _is.ColumnDateTime createdAt;

  @override
  List<_is.Column> get columns => [
    id,
    rawObservedAt,
    rawId,
    configSnapshotId,
    errorClass,
    fieldPath,
    createdAt,
  ];
}

class PipelineFailureInclude extends _is.IncludeObject {
  PipelineFailureInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => PipelineFailure.t;
}

class PipelineFailureIncludeList extends _is.IncludeList {
  PipelineFailureIncludeList._({
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(PipelineFailure.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => PipelineFailure.t;
}

class PipelineFailureRepository {
  const PipelineFailureRepository._();

  /// Returns a list of [PipelineFailure]s matching the given query parameters.
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
  Future<List<PipelineFailure>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<PipelineFailure>(
      where: where?.call(PipelineFailure.t),
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [PipelineFailure]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `PipelineFailure.t`.
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
  _ida.Stream<List<PipelineFailure>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<PipelineFailure>(
      where: where?.call(PipelineFailure.t),
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [PipelineFailure] matching the given query parameters.
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
  Future<PipelineFailure?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    int? offset,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<PipelineFailure>(
      where: where?.call(PipelineFailure.t),
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [PipelineFailure] by its [id] or null if no such row exists.
  Future<PipelineFailure?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<PipelineFailure>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [PipelineFailure]s in the list and returns the inserted rows.
  ///
  /// The returned [PipelineFailure]s will have their `id` fields set.
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
  Future<List<PipelineFailure>> insert(
    _is.DatabaseSession session,
    List<PipelineFailure> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<PipelineFailure>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [PipelineFailure] and returns the inserted row.
  ///
  /// The returned [PipelineFailure] will have its `id` field set.
  Future<PipelineFailure> insertRow(
    _is.DatabaseSession session,
    PipelineFailure row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<PipelineFailure>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [PipelineFailure]s in the list and returns the resulting rows.
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
  /// The returned [PipelineFailure]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PipelineFailure>> upsert(
    _is.DatabaseSession session,
    List<PipelineFailure> rows, {
    required _is.ColumnSelections<PipelineFailureTable> conflictColumns,
    _is.ColumnSelections<PipelineFailureTable>? updateColumns,
    _is.WhereExpressionBuilder<PipelineFailureTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<PipelineFailure>(
      rows,
      conflictColumns: conflictColumns(PipelineFailure.t),
      updateColumns: updateColumns?.call(PipelineFailure.t),
      updateWhere: updateWhere?.call(PipelineFailure.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [PipelineFailure] and returns the resulting row.
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
  /// The returned [PipelineFailure] will have its `id` field set.
  Future<PipelineFailure?> upsertRow(
    _is.DatabaseSession session,
    PipelineFailure row, {
    required _is.ColumnSelections<PipelineFailureTable> conflictColumns,
    _is.ColumnSelections<PipelineFailureTable>? updateColumns,
    _is.WhereExpressionBuilder<PipelineFailureTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<PipelineFailure>(
      row,
      conflictColumns: conflictColumns(PipelineFailure.t),
      updateColumns: updateColumns?.call(PipelineFailure.t),
      updateWhere: updateWhere?.call(PipelineFailure.t),
      transaction: transaction,
    );
  }

  /// Updates all [PipelineFailure]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PipelineFailure>> update(
    _is.DatabaseSession session,
    List<PipelineFailure> rows, {
    _is.ColumnSelections<PipelineFailureTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<PipelineFailure>(
      rows,
      columns: columns?.call(PipelineFailure.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [PipelineFailure]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<PipelineFailure> updateRow(
    _is.DatabaseSession session,
    PipelineFailure row, {
    _is.ColumnSelections<PipelineFailureTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<PipelineFailure>(
      row,
      columns: columns?.call(PipelineFailure.t),
      transaction: transaction,
    );
  }

  /// Updates a single [PipelineFailure] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<PipelineFailure?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<PipelineFailureUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<PipelineFailure>(
      id,
      columnValues: columnValues(PipelineFailure.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [PipelineFailure]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PipelineFailure>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<PipelineFailureUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<PipelineFailureTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<PipelineFailure>(
      columnValues: columnValues(PipelineFailure.t.updateTable),
      where: where(PipelineFailure.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [PipelineFailure]s in the list and returns the deleted rows.
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
  Future<List<PipelineFailure>> delete(
    _is.DatabaseSession session,
    List<PipelineFailure> rows, {
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<PipelineFailure>(
      rows,
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [PipelineFailure].
  Future<PipelineFailure> deleteRow(
    _is.DatabaseSession session,
    PipelineFailure row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<PipelineFailure>(
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
  Future<List<PipelineFailure>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PipelineFailureTable> where,
    _is.OrderByBuilder<PipelineFailureTable>? orderBy,
    _is.OrderByListBuilder<PipelineFailureTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<PipelineFailure>(
      where: where(PipelineFailure.t),
      orderBy: orderBy?.call(PipelineFailure.t),
      orderByList: orderByList?.call(PipelineFailure.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PipelineFailureTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<PipelineFailure>(
      where: where?.call(PipelineFailure.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [PipelineFailure] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PipelineFailureTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<PipelineFailure>(
      where: where(PipelineFailure.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
