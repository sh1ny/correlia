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

abstract class TransportKey
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  TransportKey._({
    this.id,
    required this.sourceId,
    required this.key,
    required this.bodySha256,
    required this.firstSeenAt,
    required this.expiresAt,
    required this.rawObservedAt,
    required this.rawId,
  });

  factory TransportKey({
    int? id,
    required _is.UuidValue sourceId,
    required String key,
    required String bodySha256,
    required DateTime firstSeenAt,
    required DateTime expiresAt,
    required DateTime rawObservedAt,
    required _is.UuidValue rawId,
  }) = _TransportKeyImpl;

  factory TransportKey.fromJson(Map<String, dynamic> jsonSerialization) {
    return TransportKey(
      id: jsonSerialization['id'] as int?,
      sourceId: _is.UuidValueJsonExtension.fromJson(
        jsonSerialization['sourceId'],
      ),
      key: jsonSerialization['key'] as String,
      bodySha256: jsonSerialization['bodySha256'] as String,
      firstSeenAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['firstSeenAt'],
      ),
      expiresAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['expiresAt'],
      ),
      rawObservedAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['rawObservedAt'],
      ),
      rawId: _is.UuidValueJsonExtension.fromJson(jsonSerialization['rawId']),
    );
  }

  static final t = TransportKeyTable();

  static const db = TransportKeyRepository._();

  @override
  int? id;

  _is.UuidValue sourceId;

  String key;

  String bodySha256;

  DateTime firstSeenAt;

  DateTime expiresAt;

  DateTime rawObservedAt;

  _is.UuidValue rawId;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [TransportKey]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  TransportKey copyWith({
    int? id,
    _is.UuidValue? sourceId,
    String? key,
    String? bodySha256,
    DateTime? firstSeenAt,
    DateTime? expiresAt,
    DateTime? rawObservedAt,
    _is.UuidValue? rawId,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'TransportKey',
      if (id != null) 'id': id,
      'sourceId': sourceId.toJson(),
      'key': key,
      'bodySha256': bodySha256,
      'firstSeenAt': firstSeenAt.toJson(),
      'expiresAt': expiresAt.toJson(),
      'rawObservedAt': rawObservedAt.toJson(),
      'rawId': rawId.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static TransportKeyInclude include() {
    return TransportKeyInclude._();
  }

  static TransportKeyIncludeList includeList({
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    TransportKeyInclude? include,
  }) {
    return TransportKeyIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _TransportKeyImpl extends TransportKey {
  _TransportKeyImpl({
    int? id,
    required _is.UuidValue sourceId,
    required String key,
    required String bodySha256,
    required DateTime firstSeenAt,
    required DateTime expiresAt,
    required DateTime rawObservedAt,
    required _is.UuidValue rawId,
  }) : super._(
         id: id,
         sourceId: sourceId,
         key: key,
         bodySha256: bodySha256,
         firstSeenAt: firstSeenAt,
         expiresAt: expiresAt,
         rawObservedAt: rawObservedAt,
         rawId: rawId,
       );

  /// Returns a shallow copy of this [TransportKey]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  TransportKey copyWith({
    Object? id = _Undefined,
    _is.UuidValue? sourceId,
    String? key,
    String? bodySha256,
    DateTime? firstSeenAt,
    DateTime? expiresAt,
    DateTime? rawObservedAt,
    _is.UuidValue? rawId,
  }) {
    return TransportKey(
      id: id is int? ? id : this.id,
      sourceId: sourceId ?? this.sourceId,
      key: key ?? this.key,
      bodySha256: bodySha256 ?? this.bodySha256,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rawObservedAt: rawObservedAt ?? this.rawObservedAt,
      rawId: rawId ?? this.rawId,
    );
  }
}

class TransportKeyUpdateTable extends _is.UpdateTable<TransportKeyTable> {
  TransportKeyUpdateTable(super.table);

  _is.ColumnValue<_is.UuidValue, _is.UuidValue> sourceId(_is.UuidValue value) =>
      _is.ColumnValue(
        table.sourceId,
        value,
      );

  _is.ColumnValue<String, String> key(String value) => _is.ColumnValue(
    table.key,
    value,
  );

  _is.ColumnValue<String, String> bodySha256(String value) => _is.ColumnValue(
    table.bodySha256,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> firstSeenAt(DateTime value) =>
      _is.ColumnValue(
        table.firstSeenAt,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> expiresAt(DateTime value) =>
      _is.ColumnValue(
        table.expiresAt,
        value,
      );

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
}

class TransportKeyTable extends _is.Table<int?> {
  TransportKeyTable({super.tableRelation})
    : super(tableName: 'transport_keys') {
    updateTable = TransportKeyUpdateTable(this);
    sourceId = _is.ColumnUuid(
      'sourceId',
      this,
    );
    key = _is.ColumnString(
      'key',
      this,
    );
    bodySha256 = _is.ColumnString(
      'bodySha256',
      this,
    );
    firstSeenAt = _is.ColumnDateTime(
      'firstSeenAt',
      this,
    );
    expiresAt = _is.ColumnDateTime(
      'expiresAt',
      this,
    );
    rawObservedAt = _is.ColumnDateTime(
      'rawObservedAt',
      this,
    );
    rawId = _is.ColumnUuid(
      'rawId',
      this,
    );
  }

  late final TransportKeyUpdateTable updateTable;

  late final _is.ColumnUuid sourceId;

  late final _is.ColumnString key;

  late final _is.ColumnString bodySha256;

  late final _is.ColumnDateTime firstSeenAt;

  late final _is.ColumnDateTime expiresAt;

  late final _is.ColumnDateTime rawObservedAt;

  late final _is.ColumnUuid rawId;

  @override
  List<_is.Column> get columns => [
    id,
    sourceId,
    key,
    bodySha256,
    firstSeenAt,
    expiresAt,
    rawObservedAt,
    rawId,
  ];
}

class TransportKeyInclude extends _is.IncludeObject {
  TransportKeyInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => TransportKey.t;
}

class TransportKeyIncludeList extends _is.IncludeList {
  TransportKeyIncludeList._({
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(TransportKey.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => TransportKey.t;
}

class TransportKeyRepository {
  const TransportKeyRepository._();

  /// Returns a list of [TransportKey]s matching the given query parameters.
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
  Future<List<TransportKey>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<TransportKey>(
      where: where?.call(TransportKey.t),
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [TransportKey]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `TransportKey.t`.
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
  _ida.Stream<List<TransportKey>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<TransportKey>(
      where: where?.call(TransportKey.t),
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [TransportKey] matching the given query parameters.
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
  Future<TransportKey?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    int? offset,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<TransportKey>(
      where: where?.call(TransportKey.t),
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [TransportKey] by its [id] or null if no such row exists.
  Future<TransportKey?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<TransportKey>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [TransportKey]s in the list and returns the inserted rows.
  ///
  /// The returned [TransportKey]s will have their `id` fields set.
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
  Future<List<TransportKey>> insert(
    _is.DatabaseSession session,
    List<TransportKey> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<TransportKey>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [TransportKey] and returns the inserted row.
  ///
  /// The returned [TransportKey] will have its `id` field set.
  Future<TransportKey> insertRow(
    _is.DatabaseSession session,
    TransportKey row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<TransportKey>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [TransportKey]s in the list and returns the resulting rows.
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
  /// The returned [TransportKey]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<TransportKey>> upsert(
    _is.DatabaseSession session,
    List<TransportKey> rows, {
    required _is.ColumnSelections<TransportKeyTable> conflictColumns,
    _is.ColumnSelections<TransportKeyTable>? updateColumns,
    _is.WhereExpressionBuilder<TransportKeyTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<TransportKey>(
      rows,
      conflictColumns: conflictColumns(TransportKey.t),
      updateColumns: updateColumns?.call(TransportKey.t),
      updateWhere: updateWhere?.call(TransportKey.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [TransportKey] and returns the resulting row.
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
  /// The returned [TransportKey] will have its `id` field set.
  Future<TransportKey?> upsertRow(
    _is.DatabaseSession session,
    TransportKey row, {
    required _is.ColumnSelections<TransportKeyTable> conflictColumns,
    _is.ColumnSelections<TransportKeyTable>? updateColumns,
    _is.WhereExpressionBuilder<TransportKeyTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<TransportKey>(
      row,
      conflictColumns: conflictColumns(TransportKey.t),
      updateColumns: updateColumns?.call(TransportKey.t),
      updateWhere: updateWhere?.call(TransportKey.t),
      transaction: transaction,
    );
  }

  /// Updates all [TransportKey]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<TransportKey>> update(
    _is.DatabaseSession session,
    List<TransportKey> rows, {
    _is.ColumnSelections<TransportKeyTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<TransportKey>(
      rows,
      columns: columns?.call(TransportKey.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [TransportKey]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<TransportKey> updateRow(
    _is.DatabaseSession session,
    TransportKey row, {
    _is.ColumnSelections<TransportKeyTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<TransportKey>(
      row,
      columns: columns?.call(TransportKey.t),
      transaction: transaction,
    );
  }

  /// Updates a single [TransportKey] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<TransportKey?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<TransportKeyUpdateTable> columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<TransportKey>(
      id,
      columnValues: columnValues(TransportKey.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [TransportKey]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<TransportKey>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<TransportKeyUpdateTable> columnValues,
    required _is.WhereExpressionBuilder<TransportKeyTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<TransportKey>(
      columnValues: columnValues(TransportKey.t.updateTable),
      where: where(TransportKey.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [TransportKey]s in the list and returns the deleted rows.
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
  Future<List<TransportKey>> delete(
    _is.DatabaseSession session,
    List<TransportKey> rows, {
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<TransportKey>(
      rows,
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [TransportKey].
  Future<TransportKey> deleteRow(
    _is.DatabaseSession session,
    TransportKey row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<TransportKey>(
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
  Future<List<TransportKey>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<TransportKeyTable> where,
    _is.OrderByBuilder<TransportKeyTable>? orderBy,
    _is.OrderByListBuilder<TransportKeyTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<TransportKey>(
      where: where(TransportKey.t),
      orderBy: orderBy?.call(TransportKey.t),
      orderByList: orderByList?.call(TransportKey.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<TransportKeyTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<TransportKey>(
      where: where?.call(TransportKey.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [TransportKey] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<TransportKeyTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<TransportKey>(
      where: where(TransportKey.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
