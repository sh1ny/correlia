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

abstract class IngestSecretCommitment
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  IngestSecretCommitment._({
    this.id,
    required this.reference,
    required this.digest,
  });

  factory IngestSecretCommitment({
    int? id,
    required String reference,
    required String digest,
  }) = _IngestSecretCommitmentImpl;

  factory IngestSecretCommitment.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return IngestSecretCommitment(
      id: jsonSerialization['id'] as int?,
      reference: jsonSerialization['reference'] as String,
      digest: jsonSerialization['digest'] as String,
    );
  }

  static final t = IngestSecretCommitmentTable();

  static const db = IngestSecretCommitmentRepository._();

  @override
  int? id;

  String reference;

  String digest;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [IngestSecretCommitment]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  IngestSecretCommitment copyWith({
    int? id,
    String? reference,
    String? digest,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'IngestSecretCommitment',
      if (id != null) 'id': id,
      'reference': reference,
      'digest': digest,
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static IngestSecretCommitmentInclude include() {
    return IngestSecretCommitmentInclude._();
  }

  static IngestSecretCommitmentIncludeList includeList({
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    IngestSecretCommitmentInclude? include,
  }) {
    return IngestSecretCommitmentIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _IngestSecretCommitmentImpl extends IngestSecretCommitment {
  _IngestSecretCommitmentImpl({
    int? id,
    required String reference,
    required String digest,
  }) : super._(
         id: id,
         reference: reference,
         digest: digest,
       );

  /// Returns a shallow copy of this [IngestSecretCommitment]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  IngestSecretCommitment copyWith({
    Object? id = _Undefined,
    String? reference,
    String? digest,
  }) {
    return IngestSecretCommitment(
      id: id is int? ? id : this.id,
      reference: reference ?? this.reference,
      digest: digest ?? this.digest,
    );
  }
}

class IngestSecretCommitmentUpdateTable
    extends _is.UpdateTable<IngestSecretCommitmentTable> {
  IngestSecretCommitmentUpdateTable(super.table);

  _is.ColumnValue<String, String> reference(String value) => _is.ColumnValue(
    table.reference,
    value,
  );

  _is.ColumnValue<String, String> digest(String value) => _is.ColumnValue(
    table.digest,
    value,
  );
}

class IngestSecretCommitmentTable extends _is.Table<int?> {
  IngestSecretCommitmentTable({super.tableRelation})
    : super(tableName: 'ingest_secret_commitment') {
    updateTable = IngestSecretCommitmentUpdateTable(this);
    reference = _is.ColumnString(
      'reference',
      this,
    );
    digest = _is.ColumnString(
      'digest',
      this,
    );
  }

  late final IngestSecretCommitmentUpdateTable updateTable;

  late final _is.ColumnString reference;

  late final _is.ColumnString digest;

  @override
  List<_is.Column> get columns => [
    id,
    reference,
    digest,
  ];
}

class IngestSecretCommitmentInclude extends _is.IncludeObject {
  IngestSecretCommitmentInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => IngestSecretCommitment.t;
}

class IngestSecretCommitmentIncludeList extends _is.IncludeList {
  IngestSecretCommitmentIncludeList._({
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(IngestSecretCommitment.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => IngestSecretCommitment.t;
}

class IngestSecretCommitmentRepository {
  const IngestSecretCommitmentRepository._();

  /// Returns a list of [IngestSecretCommitment]s matching the given query parameters.
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
  Future<List<IngestSecretCommitment>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<IngestSecretCommitment>(
      where: where?.call(IngestSecretCommitment.t),
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [IngestSecretCommitment]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `IngestSecretCommitment.t`.
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
  _ida.Stream<List<IngestSecretCommitment>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<IngestSecretCommitment>(
      where: where?.call(IngestSecretCommitment.t),
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [IngestSecretCommitment] matching the given query parameters.
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
  Future<IngestSecretCommitment?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    int? offset,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<IngestSecretCommitment>(
      where: where?.call(IngestSecretCommitment.t),
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [IngestSecretCommitment] by its [id] or null if no such row exists.
  Future<IngestSecretCommitment?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<IngestSecretCommitment>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [IngestSecretCommitment]s in the list and returns the inserted rows.
  ///
  /// The returned [IngestSecretCommitment]s will have their `id` fields set.
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
  Future<List<IngestSecretCommitment>> insert(
    _is.DatabaseSession session,
    List<IngestSecretCommitment> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<IngestSecretCommitment>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [IngestSecretCommitment] and returns the inserted row.
  ///
  /// The returned [IngestSecretCommitment] will have its `id` field set.
  Future<IngestSecretCommitment> insertRow(
    _is.DatabaseSession session,
    IngestSecretCommitment row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<IngestSecretCommitment>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [IngestSecretCommitment]s in the list and returns the resulting rows.
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
  /// The returned [IngestSecretCommitment]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSecretCommitment>> upsert(
    _is.DatabaseSession session,
    List<IngestSecretCommitment> rows, {
    required _is.ColumnSelections<IngestSecretCommitmentTable> conflictColumns,
    _is.ColumnSelections<IngestSecretCommitmentTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<IngestSecretCommitment>(
      rows,
      conflictColumns: conflictColumns(IngestSecretCommitment.t),
      updateColumns: updateColumns?.call(IngestSecretCommitment.t),
      updateWhere: updateWhere?.call(IngestSecretCommitment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [IngestSecretCommitment] and returns the resulting row.
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
  /// The returned [IngestSecretCommitment] will have its `id` field set.
  Future<IngestSecretCommitment?> upsertRow(
    _is.DatabaseSession session,
    IngestSecretCommitment row, {
    required _is.ColumnSelections<IngestSecretCommitmentTable> conflictColumns,
    _is.ColumnSelections<IngestSecretCommitmentTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<IngestSecretCommitment>(
      row,
      conflictColumns: conflictColumns(IngestSecretCommitment.t),
      updateColumns: updateColumns?.call(IngestSecretCommitment.t),
      updateWhere: updateWhere?.call(IngestSecretCommitment.t),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSecretCommitment]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSecretCommitment>> update(
    _is.DatabaseSession session,
    List<IngestSecretCommitment> rows, {
    _is.ColumnSelections<IngestSecretCommitmentTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<IngestSecretCommitment>(
      rows,
      columns: columns?.call(IngestSecretCommitment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [IngestSecretCommitment]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<IngestSecretCommitment> updateRow(
    _is.DatabaseSession session,
    IngestSecretCommitment row, {
    _is.ColumnSelections<IngestSecretCommitmentTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<IngestSecretCommitment>(
      row,
      columns: columns?.call(IngestSecretCommitment.t),
      transaction: transaction,
    );
  }

  /// Updates a single [IngestSecretCommitment] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<IngestSecretCommitment?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<IngestSecretCommitmentUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<IngestSecretCommitment>(
      id,
      columnValues: columnValues(IngestSecretCommitment.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSecretCommitment]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSecretCommitment>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<IngestSecretCommitmentUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<IngestSecretCommitmentTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<IngestSecretCommitment>(
      columnValues: columnValues(IngestSecretCommitment.t.updateTable),
      where: where(IngestSecretCommitment.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [IngestSecretCommitment]s in the list and returns the deleted rows.
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
  Future<List<IngestSecretCommitment>> delete(
    _is.DatabaseSession session,
    List<IngestSecretCommitment> rows, {
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<IngestSecretCommitment>(
      rows,
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [IngestSecretCommitment].
  Future<IngestSecretCommitment> deleteRow(
    _is.DatabaseSession session,
    IngestSecretCommitment row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<IngestSecretCommitment>(
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
  Future<List<IngestSecretCommitment>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSecretCommitmentTable> where,
    _is.OrderByBuilder<IngestSecretCommitmentTable>? orderBy,
    _is.OrderByListBuilder<IngestSecretCommitmentTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<IngestSecretCommitment>(
      where: where(IngestSecretCommitment.t),
      orderBy: orderBy?.call(IngestSecretCommitment.t),
      orderByList: orderByList?.call(IngestSecretCommitment.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSecretCommitmentTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<IngestSecretCommitment>(
      where: where?.call(IngestSecretCommitment.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [IngestSecretCommitment] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSecretCommitmentTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<IngestSecretCommitment>(
      where: where(IngestSecretCommitment.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
