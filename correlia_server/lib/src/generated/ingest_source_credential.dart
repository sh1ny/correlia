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

abstract class IngestSourceCredential
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  IngestSourceCredential._({
    this.id,
    required this.sourceId,
    required this.reference,
    required this.type,
    required this.digest,
    this.notBefore,
    this.notAfter,
  });

  factory IngestSourceCredential({
    int? id,
    required _is.UuidValue sourceId,
    required String reference,
    required String type,
    required String digest,
    DateTime? notBefore,
    DateTime? notAfter,
  }) = _IngestSourceCredentialImpl;

  factory IngestSourceCredential.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return IngestSourceCredential(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      reference: jsonSerialization['reference'] as String,
      type: jsonSerialization['type'] as String,
      digest: jsonSerialization['digest'] as String,
      notBefore: jsonSerialization['notBefore'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['notBefore']),
      notAfter: jsonSerialization['notAfter'] == null
          ? null
          : _is.DateTimeJsonExtension.fromJson(jsonSerialization['notAfter']),
    );
  }

  static final t = IngestSourceCredentialTable();

  static const db = IngestSourceCredentialRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  String reference;

  String type;

  String digest;

  DateTime? notBefore;

  DateTime? notAfter;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [IngestSourceCredential]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  IngestSourceCredential copyWith({
    int? id,
    _is.UuidValue? sourceId,
    String? reference,
    String? type,
    String? digest,
    DateTime? notBefore = const _is.$UndefinedDateTime(),
    DateTime? notAfter = const _is.$UndefinedDateTime(),
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'IngestSourceCredential',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'reference': reference,
      'type': type,
      'digest': digest,
      if (notBefore != null) 'notBefore': notBefore?.toJson(),
      if (notAfter != null) 'notAfter': notAfter?.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static IngestSourceCredentialInclude include() {
    return IngestSourceCredentialInclude._();
  }

  static IngestSourceCredentialIncludeList includeList({
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    IngestSourceCredentialInclude? include,
  }) {
    return IngestSourceCredentialIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _IngestSourceCredentialImpl extends IngestSourceCredential {
  _IngestSourceCredentialImpl({
    int? id,
    required _is.UuidValue sourceId,
    required String reference,
    required String type,
    required String digest,
    DateTime? notBefore,
    DateTime? notAfter,
  }) : super._(
         id: id,
         sourceId: sourceId,
         reference: reference,
         type: type,
         digest: digest,
         notBefore: notBefore,
         notAfter: notAfter,
       );

  /// Returns a shallow copy of this [IngestSourceCredential]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  IngestSourceCredential copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    String? reference,
    String? type,
    String? digest,
    DateTime? notBefore = const _is.$UndefinedDateTime(),
    DateTime? notAfter = const _is.$UndefinedDateTime(),
  }) {
    return IngestSourceCredential(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      reference: reference ?? this.reference,
      type: type ?? this.type,
      digest: digest ?? this.digest,
      notBefore: notBefore is _is.UndefinedSentinel
          ? this.notBefore
          : notBefore,
      notAfter: notAfter is _is.UndefinedSentinel ? this.notAfter : notAfter,
    );
  }
}

class IngestSourceCredentialUpdateTable
    extends _is.UpdateTable<IngestSourceCredentialTable> {
  IngestSourceCredentialUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<String, String> reference(String value) => _is.ColumnValue(
    table.reference,
    value,
  );

  _is.ColumnValue<String, String> type(String value) => _is.ColumnValue(
    table.type,
    value,
  );

  _is.ColumnValue<String, String> digest(String value) => _is.ColumnValue(
    table.digest,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> notBefore(DateTime? value) =>
      _is.ColumnValue(
        table.notBefore,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> notAfter(DateTime? value) =>
      _is.ColumnValue(
        table.notAfter,
        value,
      );
}

class IngestSourceCredentialTable extends _is.Table<int?> {
  IngestSourceCredentialTable({super.tableRelation})
    : super(tableName: 'ingest_source_credential') {
    updateTable = IngestSourceCredentialUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    reference = _is.ColumnString(
      'reference',
      this,
    );
    type = _is.ColumnString(
      'type',
      this,
    );
    digest = _is.ColumnString(
      'digest',
      this,
    );
    notBefore = _is.ColumnDateTime(
      'notBefore',
      this,
    );
    notAfter = _is.ColumnDateTime(
      'notAfter',
      this,
    );
  }

  late final IngestSourceCredentialUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnString reference;

  late final _is.ColumnString type;

  late final _is.ColumnString digest;

  late final _is.ColumnDateTime notBefore;

  late final _is.ColumnDateTime notAfter;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    reference,
    type,
    digest,
    notBefore,
    notAfter,
  ];
}

class IngestSourceCredentialInclude extends _is.IncludeObject {
  IngestSourceCredentialInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => IngestSourceCredential.t;
}

class IngestSourceCredentialIncludeList extends _is.IncludeList {
  IngestSourceCredentialIncludeList._({
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(IngestSourceCredential.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => IngestSourceCredential.t;
}

class IngestSourceCredentialRepository {
  const IngestSourceCredentialRepository._();

  /// Returns a list of [IngestSourceCredential]s matching the given query parameters.
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
  Future<List<IngestSourceCredential>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<IngestSourceCredential>(
      where: where?.call(IngestSourceCredential.t),
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [IngestSourceCredential]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `IngestSourceCredential.t`.
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
  _ida.Stream<List<IngestSourceCredential>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<IngestSourceCredential>(
      where: where?.call(IngestSourceCredential.t),
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [IngestSourceCredential] matching the given query parameters.
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
  Future<IngestSourceCredential?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    int? offset,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<IngestSourceCredential>(
      where: where?.call(IngestSourceCredential.t),
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [IngestSourceCredential] by its [id] or null if no such row exists.
  Future<IngestSourceCredential?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<IngestSourceCredential>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [IngestSourceCredential]s in the list and returns the inserted rows.
  ///
  /// The returned [IngestSourceCredential]s will have their `id` fields set.
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
  Future<List<IngestSourceCredential>> insert(
    _is.DatabaseSession session,
    List<IngestSourceCredential> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<IngestSourceCredential>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [IngestSourceCredential] and returns the inserted row.
  ///
  /// The returned [IngestSourceCredential] will have its `id` field set.
  Future<IngestSourceCredential> insertRow(
    _is.DatabaseSession session,
    IngestSourceCredential row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<IngestSourceCredential>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [IngestSourceCredential]s in the list and returns the resulting rows.
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
  /// The returned [IngestSourceCredential]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceCredential>> upsert(
    _is.DatabaseSession session,
    List<IngestSourceCredential> rows, {
    required _is.ColumnSelections<IngestSourceCredentialTable> conflictColumns,
    _is.ColumnSelections<IngestSourceCredentialTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<IngestSourceCredential>(
      rows,
      conflictColumns: conflictColumns(IngestSourceCredential.t),
      updateColumns: updateColumns?.call(IngestSourceCredential.t),
      updateWhere: updateWhere?.call(IngestSourceCredential.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [IngestSourceCredential] and returns the resulting row.
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
  /// The returned [IngestSourceCredential] will have its `id` field set.
  Future<IngestSourceCredential?> upsertRow(
    _is.DatabaseSession session,
    IngestSourceCredential row, {
    required _is.ColumnSelections<IngestSourceCredentialTable> conflictColumns,
    _is.ColumnSelections<IngestSourceCredentialTable>? updateColumns,
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<IngestSourceCredential>(
      row,
      conflictColumns: conflictColumns(IngestSourceCredential.t),
      updateColumns: updateColumns?.call(IngestSourceCredential.t),
      updateWhere: updateWhere?.call(IngestSourceCredential.t),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSourceCredential]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceCredential>> update(
    _is.DatabaseSession session,
    List<IngestSourceCredential> rows, {
    _is.ColumnSelections<IngestSourceCredentialTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<IngestSourceCredential>(
      rows,
      columns: columns?.call(IngestSourceCredential.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [IngestSourceCredential]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<IngestSourceCredential> updateRow(
    _is.DatabaseSession session,
    IngestSourceCredential row, {
    _is.ColumnSelections<IngestSourceCredentialTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<IngestSourceCredential>(
      row,
      columns: columns?.call(IngestSourceCredential.t),
      transaction: transaction,
    );
  }

  /// Updates a single [IngestSourceCredential] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<IngestSourceCredential?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<IngestSourceCredentialUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<IngestSourceCredential>(
      id,
      columnValues: columnValues(IngestSourceCredential.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [IngestSourceCredential]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<IngestSourceCredential>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<IngestSourceCredentialUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<IngestSourceCredentialTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<IngestSourceCredential>(
      columnValues: columnValues(IngestSourceCredential.t.updateTable),
      where: where(IngestSourceCredential.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [IngestSourceCredential]s in the list and returns the deleted rows.
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
  Future<List<IngestSourceCredential>> delete(
    _is.DatabaseSession session,
    List<IngestSourceCredential> rows, {
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<IngestSourceCredential>(
      rows,
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [IngestSourceCredential].
  Future<IngestSourceCredential> deleteRow(
    _is.DatabaseSession session,
    IngestSourceCredential row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<IngestSourceCredential>(
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
  Future<List<IngestSourceCredential>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSourceCredentialTable> where,
    _is.OrderByBuilder<IngestSourceCredentialTable>? orderBy,
    _is.OrderByListBuilder<IngestSourceCredentialTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<IngestSourceCredential>(
      where: where(IngestSourceCredential.t),
      orderBy: orderBy?.call(IngestSourceCredential.t),
      orderByList: orderByList?.call(IngestSourceCredential.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<IngestSourceCredentialTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<IngestSourceCredential>(
      where: where?.call(IngestSourceCredential.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [IngestSourceCredential] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<IngestSourceCredentialTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<IngestSourceCredential>(
      where: where(IngestSourceCredential.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
