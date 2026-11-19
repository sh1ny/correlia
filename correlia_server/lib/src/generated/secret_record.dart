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
import 'dart:typed_data' as _idt;
import 'package:serverpod/serverpod.dart' as _is;

abstract class SecretRecord
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  SecretRecord._({
    this.id,
    required this.reference,
    required this.algorithm,
    required this.nonce,
    required this.ciphertext,
    required this.commitment,
    required this.keyCommitment,
    required this.createdAt,
  });

  factory SecretRecord({
    int? id,
    required String reference,
    required String algorithm,
    required _idt.ByteData nonce,
    required _idt.ByteData ciphertext,
    required String commitment,
    required String keyCommitment,
    required DateTime createdAt,
  }) = _SecretRecordImpl;

  factory SecretRecord.fromJson(Map<String, dynamic> jsonSerialization) {
    return SecretRecord(
      id: jsonSerialization['id'] as int?,
      reference: jsonSerialization['reference'] as String,
      algorithm: jsonSerialization['algorithm'] as String,
      nonce: _is.ByteDataJsonExtension.fromJson(jsonSerialization['nonce']),
      ciphertext: _is.ByteDataJsonExtension.fromJson(
        jsonSerialization['ciphertext'],
      ),
      commitment: jsonSerialization['commitment'] as String,
      keyCommitment: jsonSerialization['keyCommitment'] as String,
      createdAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['createdAt'],
      ),
    );
  }

  static final t = SecretRecordTable();

  static const db = SecretRecordRepository._();

  @override
  int? id;

  String reference;

  String algorithm;

  _idt.ByteData nonce;

  _idt.ByteData ciphertext;

  String commitment;

  String keyCommitment;

  DateTime createdAt;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [SecretRecord]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  SecretRecord copyWith({
    int? id,
    String? reference,
    String? algorithm,
    _idt.ByteData? nonce,
    _idt.ByteData? ciphertext,
    String? commitment,
    String? keyCommitment,
    DateTime? createdAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'SecretRecord',
      if (id != null) 'id': id,
      'reference': reference,
      'algorithm': algorithm,
      'nonce': nonce.toJson(),
      'ciphertext': ciphertext.toJson(),
      'commitment': commitment,
      'keyCommitment': keyCommitment,
      'createdAt': createdAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static SecretRecordInclude include() {
    return SecretRecordInclude._();
  }

  static SecretRecordIncludeList includeList({
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    SecretRecordInclude? include,
  }) {
    return SecretRecordIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _SecretRecordImpl extends SecretRecord {
  _SecretRecordImpl({
    int? id,
    required String reference,
    required String algorithm,
    required _idt.ByteData nonce,
    required _idt.ByteData ciphertext,
    required String commitment,
    required String keyCommitment,
    required DateTime createdAt,
  }) : super._(
         id: id,
         reference: reference,
         algorithm: algorithm,
         nonce: nonce,
         ciphertext: ciphertext,
         commitment: commitment,
         keyCommitment: keyCommitment,
         createdAt: createdAt,
       );

  /// Returns a shallow copy of this [SecretRecord]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  SecretRecord copyWith({
    Object? id = _Undefined,
    String? reference,
    String? algorithm,
    _idt.ByteData? nonce,
    _idt.ByteData? ciphertext,
    String? commitment,
    String? keyCommitment,
    DateTime? createdAt,
  }) {
    return SecretRecord(
      id: id is int? ? id : this.id,
      reference: reference ?? this.reference,
      algorithm: algorithm ?? this.algorithm,
      nonce: nonce ?? this.nonce.clone(),
      ciphertext: ciphertext ?? this.ciphertext.clone(),
      commitment: commitment ?? this.commitment,
      keyCommitment: keyCommitment ?? this.keyCommitment,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class SecretRecordUpdateTable extends _is.UpdateTable<SecretRecordTable> {
  SecretRecordUpdateTable(super.table);

  _is.ColumnValue<String, String> reference(String value) => _is.ColumnValue(
    table.reference,
    value,
  );

  _is.ColumnValue<String, String> algorithm(String value) => _is.ColumnValue(
    table.algorithm,
    value,
  );

  _is.ColumnValue<_idt.ByteData, _idt.ByteData> nonce(_idt.ByteData value) =>
      _is.ColumnValue(
        table.nonce,
        value,
      );

  _is.ColumnValue<_idt.ByteData, _idt.ByteData> ciphertext(
    _idt.ByteData value,
  ) => _is.ColumnValue(
    table.ciphertext,
    value,
  );

  _is.ColumnValue<String, String> commitment(String value) => _is.ColumnValue(
    table.commitment,
    value,
  );

  _is.ColumnValue<String, String> keyCommitment(String value) =>
      _is.ColumnValue(
        table.keyCommitment,
        value,
      );

  _is.ColumnValue<DateTime, DateTime> createdAt(DateTime value) =>
      _is.ColumnValue(
        table.createdAt,
        value,
      );
}

class SecretRecordTable extends _is.Table<int?> {
  SecretRecordTable({super.tableRelation}) : super(tableName: 'secret_record') {
    updateTable = SecretRecordUpdateTable(this);
    reference = _is.ColumnString(
      'reference',
      this,
    );
    algorithm = _is.ColumnString(
      'algorithm',
      this,
    );
    nonce = _is.ColumnByteData(
      'nonce',
      this,
    );
    ciphertext = _is.ColumnByteData(
      'ciphertext',
      this,
    );
    commitment = _is.ColumnString(
      'commitment',
      this,
    );
    keyCommitment = _is.ColumnString(
      'keyCommitment',
      this,
    );
    createdAt = _is.ColumnDateTime(
      'createdAt',
      this,
    );
  }

  late final SecretRecordUpdateTable updateTable;

  late final _is.ColumnString reference;

  late final _is.ColumnString algorithm;

  late final _is.ColumnByteData nonce;

  late final _is.ColumnByteData ciphertext;

  late final _is.ColumnString commitment;

  late final _is.ColumnString keyCommitment;

  late final _is.ColumnDateTime createdAt;

  @override
  List<_is.Column> get columns => [
    id,
    reference,
    algorithm,
    nonce,
    ciphertext,
    commitment,
    keyCommitment,
    createdAt,
  ];
}

class SecretRecordInclude extends _is.IncludeObject {
  SecretRecordInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => SecretRecord.t;
}

class SecretRecordIncludeList extends _is.IncludeList {
  SecretRecordIncludeList._({
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(SecretRecord.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => SecretRecord.t;
}

class SecretRecordRepository {
  const SecretRecordRepository._();

  /// Returns a list of [SecretRecord]s matching the given query parameters.
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
  Future<List<SecretRecord>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<SecretRecord>(
      where: where?.call(SecretRecord.t),
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [SecretRecord]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `SecretRecord.t`.
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
  _ida.Stream<List<SecretRecord>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<SecretRecord>(
      where: where?.call(SecretRecord.t),
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [SecretRecord] matching the given query parameters.
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
  Future<SecretRecord?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    int? offset,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<SecretRecord>(
      where: where?.call(SecretRecord.t),
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [SecretRecord] by its [id] or null if no such row exists.
  Future<SecretRecord?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<SecretRecord>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [SecretRecord]s in the list and returns the inserted rows.
  ///
  /// The returned [SecretRecord]s will have their `id` fields set.
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
  Future<List<SecretRecord>> insert(
    _is.DatabaseSession session,
    List<SecretRecord> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<SecretRecord>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [SecretRecord] and returns the inserted row.
  ///
  /// The returned [SecretRecord] will have its `id` field set.
  Future<SecretRecord> insertRow(
    _is.DatabaseSession session,
    SecretRecord row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<SecretRecord>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [SecretRecord]s in the list and returns the resulting rows.
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
  /// The returned [SecretRecord]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<SecretRecord>> upsert(
    _is.DatabaseSession session,
    List<SecretRecord> rows, {
    required _is.ColumnSelections<SecretRecordTable> conflictColumns,
    _is.ColumnSelections<SecretRecordTable>? updateColumns,
    _is.WhereExpressionBuilder<SecretRecordTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<SecretRecord>(
      rows,
      conflictColumns: conflictColumns(SecretRecord.t),
      updateColumns: updateColumns?.call(SecretRecord.t),
      updateWhere: updateWhere?.call(SecretRecord.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [SecretRecord] and returns the resulting row.
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
  /// The returned [SecretRecord] will have its `id` field set.
  Future<SecretRecord?> upsertRow(
    _is.DatabaseSession session,
    SecretRecord row, {
    required _is.ColumnSelections<SecretRecordTable> conflictColumns,
    _is.ColumnSelections<SecretRecordTable>? updateColumns,
    _is.WhereExpressionBuilder<SecretRecordTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<SecretRecord>(
      row,
      conflictColumns: conflictColumns(SecretRecord.t),
      updateColumns: updateColumns?.call(SecretRecord.t),
      updateWhere: updateWhere?.call(SecretRecord.t),
      transaction: transaction,
    );
  }

  /// Updates all [SecretRecord]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<SecretRecord>> update(
    _is.DatabaseSession session,
    List<SecretRecord> rows, {
    _is.ColumnSelections<SecretRecordTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<SecretRecord>(
      rows,
      columns: columns?.call(SecretRecord.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [SecretRecord]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<SecretRecord> updateRow(
    _is.DatabaseSession session,
    SecretRecord row, {
    _is.ColumnSelections<SecretRecordTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<SecretRecord>(
      row,
      columns: columns?.call(SecretRecord.t),
      transaction: transaction,
    );
  }

  /// Updates a single [SecretRecord] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<SecretRecord?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<SecretRecordUpdateTable> columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<SecretRecord>(
      id,
      columnValues: columnValues(SecretRecord.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [SecretRecord]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<SecretRecord>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<SecretRecordUpdateTable> columnValues,
    required _is.WhereExpressionBuilder<SecretRecordTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<SecretRecord>(
      columnValues: columnValues(SecretRecord.t.updateTable),
      where: where(SecretRecord.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [SecretRecord]s in the list and returns the deleted rows.
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
  Future<List<SecretRecord>> delete(
    _is.DatabaseSession session,
    List<SecretRecord> rows, {
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<SecretRecord>(
      rows,
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [SecretRecord].
  Future<SecretRecord> deleteRow(
    _is.DatabaseSession session,
    SecretRecord row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<SecretRecord>(
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
  Future<List<SecretRecord>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<SecretRecordTable> where,
    _is.OrderByBuilder<SecretRecordTable>? orderBy,
    _is.OrderByListBuilder<SecretRecordTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<SecretRecord>(
      where: where(SecretRecord.t),
      orderBy: orderBy?.call(SecretRecord.t),
      orderByList: orderByList?.call(SecretRecord.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<SecretRecordTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<SecretRecord>(
      where: where?.call(SecretRecord.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [SecretRecord] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<SecretRecordTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<SecretRecord>(
      where: where(SecretRecord.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
