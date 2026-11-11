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

abstract class DeliveryAttempt
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  DeliveryAttempt._({
    this.id,
    required this.outboxCreatedAt,
    required this.deliveryId,
    required this.attemptNumber,
    required this.claimId,
    required this.startedAt,
    this.finishedAt,
    required this.outcome,
    this.errorClass,
  });

  factory DeliveryAttempt({
    int? id,
    required DateTime outboxCreatedAt,
    required _is.UuidValue deliveryId,
    required int attemptNumber,
    required _is.UuidValue claimId,
    required DateTime startedAt,
    DateTime? finishedAt,
    required String outcome,
    String? errorClass,
  }) = _DeliveryAttemptImpl;

  factory DeliveryAttempt.fromJson(Map<String, dynamic> jsonSerialization) {
    return DeliveryAttempt(
      id: jsonSerialization['id'] as int?,
      outboxCreatedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['outboxCreatedAt'],
      ),
      deliveryId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['deliveryId'],
      ),
      attemptNumber: jsonSerialization['attemptNumber'] as int,
      claimId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['claimId'],
      ),
      startedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['startedAt'],
      ),
      finishedAt: jsonSerialization['finishedAt'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['finishedAt']),
      outcome: jsonSerialization['outcome'] as String,
      errorClass: jsonSerialization['errorClass'] as String?,
    );
  }

  static final t = DeliveryAttemptTable();

  static const db = DeliveryAttemptRepository._();

  @override
  int? id;

  DateTime outboxCreatedAt;

  _is.UuidValue deliveryId;

  int attemptNumber;

  _is.UuidValue claimId;

  DateTime startedAt;

  DateTime? finishedAt;

  String outcome;

  String? errorClass;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [DeliveryAttempt]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  DeliveryAttempt copyWith({
    int? id,
    DateTime? outboxCreatedAt,
    _is.UuidValue? deliveryId,
    int? attemptNumber,
    _is.UuidValue? claimId,
    DateTime? startedAt,
    DateTime? finishedAt = const _is.$UndefinedDateTime(),
    String? outcome,
    String? errorClass,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'DeliveryAttempt',
      if (id != null) 'id': id,
      'outboxCreatedAt': outboxCreatedAt.toJson(),
      'deliveryId': deliveryId.toJson(),
      'attemptNumber': attemptNumber,
      'claimId': claimId.toJson(),
      'startedAt': startedAt.toJson(),
      if (finishedAt != null) 'finishedAt': finishedAt?.toJson(),
      'outcome': outcome,
      if (errorClass != null) 'errorClass': errorClass,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static DeliveryAttemptInclude include() {
    return DeliveryAttemptInclude._();
  }

  static DeliveryAttemptIncludeList includeList({
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    DeliveryAttemptInclude? include,
  }) {
    return DeliveryAttemptIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _DeliveryAttemptImpl extends DeliveryAttempt {
  _DeliveryAttemptImpl({
    int? id,
    required DateTime outboxCreatedAt,
    required _is.UuidValue deliveryId,
    required int attemptNumber,
    required _is.UuidValue claimId,
    required DateTime startedAt,
    DateTime? finishedAt,
    required String outcome,
    String? errorClass,
  }) : super._(
         id: id,
         outboxCreatedAt: outboxCreatedAt,
         deliveryId: deliveryId,
         attemptNumber: attemptNumber,
         claimId: claimId,
         startedAt: startedAt,
         finishedAt: finishedAt,
         outcome: outcome,
         errorClass: errorClass,
       );

  /// Returns a shallow copy of this [DeliveryAttempt]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  DeliveryAttempt copyWith({
    Object? id = _Undefined,
    DateTime? outboxCreatedAt,
    _is.UuidValue? deliveryId,
    int? attemptNumber,
    _is.UuidValue? claimId,
    DateTime? startedAt,
    DateTime? finishedAt = const _is.$UndefinedDateTime(),
    String? outcome,
    Object? errorClass = _Undefined,
  }) {
    return DeliveryAttempt(
      id: id is int? ? id : this.id,
      outboxCreatedAt: outboxCreatedAt ?? this.outboxCreatedAt,
      deliveryId: deliveryId ?? this.deliveryId,
      attemptNumber: attemptNumber ?? this.attemptNumber,
      claimId: claimId ?? this.claimId,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt is _is.UndefinedSentinel
          ? this.finishedAt
          : finishedAt,
      outcome: outcome ?? this.outcome,
      errorClass: errorClass is String? ? errorClass : this.errorClass,
    );
  }
}

class DeliveryAttemptUpdateTable extends _is.UpdateTable<DeliveryAttemptTable> {
  DeliveryAttemptUpdateTable(super.table);

  _is.ColumnValue<DateTime, DateTime> outboxCreatedAt(DateTime value) =>
      _is.ColumnValue(
        table.outboxCreatedAt,
        value,
      );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> deliveryId(
    _is.UuidValue value,
  ) => _is.ColumnValue(
    table.deliveryId,
    value,
  );

  _is.ColumnValue<int, int> attemptNumber(int value) => _is.ColumnValue(
    table.attemptNumber,
    value,
  );

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> claimId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.claimId,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> startedAt(DateTime value) =>
      _is.ColumnValue(
        table.startedAt,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> finishedAt(DateTime? value) =>
      _is.ColumnValue(
        table.finishedAt,
        value,
      );

  _is.ColumnValue<String, String> outcome(String value) => _is.ColumnValue(
    table.outcome,
    value,
  );

  _is.ColumnValue<String, String> errorClass(String? value) => _is.ColumnValue(
    table.errorClass,
    value,
  );
}

class DeliveryAttemptTable extends _is.Table<int?> {
  DeliveryAttemptTable({super.tableRelation})
    : super(tableName: 'delivery_attempts') {
    updateTable = DeliveryAttemptUpdateTable(this);
    outboxCreatedAt = _is.ColumnDateTime(
      'outboxCreatedAt',
      this,
    );
    deliveryId = _is.ColumnUuid(
      'deliveryId',
      this,
    );
    attemptNumber = _is.ColumnInt(
      'attemptNumber',
      this,
    );
    claimId = _is.ColumnUuid(
      'claimId',
      this,
    );
    startedAt = _is.ColumnDateTime(
      'startedAt',
      this,
    );
    finishedAt = _is.ColumnDateTime(
      'finishedAt',
      this,
    );
    outcome = _is.ColumnString(
      'outcome',
      this,
    );
    errorClass = _is.ColumnString(
      'errorClass',
      this,
    );
  }

  late final DeliveryAttemptUpdateTable updateTable;

  late final _is.ColumnDateTime outboxCreatedAt;

  late final _is.ColumnUuid deliveryId;

  late final _is.ColumnInt attemptNumber;

  late final _is.ColumnUuid claimId;

  late final _is.ColumnDateTime startedAt;

  late final _is.ColumnDateTime finishedAt;

  late final _is.ColumnString outcome;

  late final _is.ColumnString errorClass;

  @override
  List<_is.Column> get columns => [
    id,
    outboxCreatedAt,
    deliveryId,
    attemptNumber,
    claimId,
    startedAt,
    finishedAt,
    outcome,
    errorClass,
  ];
}

class DeliveryAttemptInclude extends _is.IncludeObject {
  DeliveryAttemptInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => DeliveryAttempt.t;
}

class DeliveryAttemptIncludeList extends _is.IncludeList {
  DeliveryAttemptIncludeList._({
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(DeliveryAttempt.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => DeliveryAttempt.t;
}

class DeliveryAttemptRepository {
  const DeliveryAttemptRepository._();

  /// Returns a list of [DeliveryAttempt]s matching the given query parameters.
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
  Future<List<DeliveryAttempt>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<DeliveryAttempt>(
      where: where?.call(DeliveryAttempt.t),
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [DeliveryAttempt]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `DeliveryAttempt.t`.
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
  _ida.Stream<List<DeliveryAttempt>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<DeliveryAttempt>(
      where: where?.call(DeliveryAttempt.t),
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [DeliveryAttempt] matching the given query parameters.
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
  Future<DeliveryAttempt?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    int? offset,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<DeliveryAttempt>(
      where: where?.call(DeliveryAttempt.t),
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [DeliveryAttempt] by its [id] or null if no such row exists.
  Future<DeliveryAttempt?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<DeliveryAttempt>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [DeliveryAttempt]s in the list and returns the inserted rows.
  ///
  /// The returned [DeliveryAttempt]s will have their `id` fields set.
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
  Future<List<DeliveryAttempt>> insert(
    _is.DatabaseSession session,
    List<DeliveryAttempt> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<DeliveryAttempt>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [DeliveryAttempt] and returns the inserted row.
  ///
  /// The returned [DeliveryAttempt] will have its `id` field set.
  Future<DeliveryAttempt> insertRow(
    _is.DatabaseSession session,
    DeliveryAttempt row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<DeliveryAttempt>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [DeliveryAttempt]s in the list and returns the resulting rows.
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
  /// The returned [DeliveryAttempt]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<DeliveryAttempt>> upsert(
    _is.DatabaseSession session,
    List<DeliveryAttempt> rows, {
    required _is.ColumnSelections<DeliveryAttemptTable> conflictColumns,
    _is.ColumnSelections<DeliveryAttemptTable>? updateColumns,
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<DeliveryAttempt>(
      rows,
      conflictColumns: conflictColumns(DeliveryAttempt.t),
      updateColumns: updateColumns?.call(DeliveryAttempt.t),
      updateWhere: updateWhere?.call(DeliveryAttempt.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [DeliveryAttempt] and returns the resulting row.
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
  /// The returned [DeliveryAttempt] will have its `id` field set.
  Future<DeliveryAttempt?> upsertRow(
    _is.DatabaseSession session,
    DeliveryAttempt row, {
    required _is.ColumnSelections<DeliveryAttemptTable> conflictColumns,
    _is.ColumnSelections<DeliveryAttemptTable>? updateColumns,
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<DeliveryAttempt>(
      row,
      conflictColumns: conflictColumns(DeliveryAttempt.t),
      updateColumns: updateColumns?.call(DeliveryAttempt.t),
      updateWhere: updateWhere?.call(DeliveryAttempt.t),
      transaction: transaction,
    );
  }

  /// Updates all [DeliveryAttempt]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<DeliveryAttempt>> update(
    _is.DatabaseSession session,
    List<DeliveryAttempt> rows, {
    _is.ColumnSelections<DeliveryAttemptTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<DeliveryAttempt>(
      rows,
      columns: columns?.call(DeliveryAttempt.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [DeliveryAttempt]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<DeliveryAttempt> updateRow(
    _is.DatabaseSession session,
    DeliveryAttempt row, {
    _is.ColumnSelections<DeliveryAttemptTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<DeliveryAttempt>(
      row,
      columns: columns?.call(DeliveryAttempt.t),
      transaction: transaction,
    );
  }

  /// Updates a single [DeliveryAttempt] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<DeliveryAttempt?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<DeliveryAttemptUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<DeliveryAttempt>(
      id,
      columnValues: columnValues(DeliveryAttempt.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [DeliveryAttempt]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<DeliveryAttempt>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<DeliveryAttemptUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<DeliveryAttemptTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<DeliveryAttempt>(
      columnValues: columnValues(DeliveryAttempt.t.updateTable),
      where: where(DeliveryAttempt.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [DeliveryAttempt]s in the list and returns the deleted rows.
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
  Future<List<DeliveryAttempt>> delete(
    _is.DatabaseSession session,
    List<DeliveryAttempt> rows, {
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<DeliveryAttempt>(
      rows,
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [DeliveryAttempt].
  Future<DeliveryAttempt> deleteRow(
    _is.DatabaseSession session,
    DeliveryAttempt row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<DeliveryAttempt>(
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
  Future<List<DeliveryAttempt>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<DeliveryAttemptTable> where,
    _is.OrderByBuilder<DeliveryAttemptTable>? orderBy,
    _is.OrderByListBuilder<DeliveryAttemptTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<DeliveryAttempt>(
      where: where(DeliveryAttempt.t),
      orderBy: orderBy?.call(DeliveryAttempt.t),
      orderByList: orderByList?.call(DeliveryAttempt.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<DeliveryAttemptTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<DeliveryAttempt>(
      where: where?.call(DeliveryAttempt.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [DeliveryAttempt] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<DeliveryAttemptTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<DeliveryAttempt>(
      where: where(DeliveryAttempt.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
