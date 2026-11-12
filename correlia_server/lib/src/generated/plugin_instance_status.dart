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

abstract class PluginInstanceStatus
    implements _is.TableRow<int?>, _is.ProtocolSerialization {
  PluginInstanceStatus._({
    this.id,
    required this.hostInstanceId,
    required this.outputId,
    required this.definitionDigest,
    required this.state,
    this.pluginName,
    this.pluginVersion,
    this.pid,
    required this.restartCount,
    required this.crashesInWindow,
    this.lastErrorClass,
    this.lastPluginErrorClass,
    required this.version,
    required this.heartbeatAt,
  });

  factory PluginInstanceStatus({
    int? id,
    required String hostInstanceId,
    required String outputId,
    required String definitionDigest,
    required String state,
    String? pluginName,
    String? pluginVersion,
    int? pid,
    required int restartCount,
    required int crashesInWindow,
    String? lastErrorClass,
    String? lastPluginErrorClass,
    required int version,
    required DateTime heartbeatAt,
  }) = _PluginInstanceStatusImpl;

  factory PluginInstanceStatus.fromJson(
    Map<String, dynamic> jsonSerialization,
  ) {
    return PluginInstanceStatus(
      id: jsonSerialization['id'] as int?,
      hostInstanceId: jsonSerialization['hostInstanceId'] as String,
      outputId: jsonSerialization['outputId'] as String,
      definitionDigest: jsonSerialization['definitionDigest'] as String,
      state: jsonSerialization['state'] as String,
      pluginName: jsonSerialization['pluginName'] as String?,
      pluginVersion: jsonSerialization['pluginVersion'] as String?,
      pid: jsonSerialization['pid'] as int?,
      restartCount: jsonSerialization['restartCount'] as int,
      crashesInWindow: jsonSerialization['crashesInWindow'] as int,
      lastErrorClass: jsonSerialization['lastErrorClass'] as String?,
      lastPluginErrorClass:
          jsonSerialization['lastPluginErrorClass'] as String?,
      version: jsonSerialization['version'] as int,
      heartbeatAt: _is.DateTimeJsonExtension.fromJson(
        jsonSerialization['heartbeatAt'],
      ),
    );
  }

  static final t = PluginInstanceStatusTable();

  static const db = PluginInstanceStatusRepository._();

  @override
  int? id;

  String hostInstanceId;

  String outputId;

  String definitionDigest;

  String state;

  String? pluginName;

  String? pluginVersion;

  int? pid;

  int restartCount;

  int crashesInWindow;

  String? lastErrorClass;

  String? lastPluginErrorClass;

  int version;

  DateTime heartbeatAt;

  @override
  _is.Table<int?> get table => t;

  /// Returns a shallow copy of this [PluginInstanceStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  PluginInstanceStatus copyWith({
    int? id,
    String? hostInstanceId,
    String? outputId,
    String? definitionDigest,
    String? state,
    String? pluginName,
    String? pluginVersion,
    int? pid,
    int? restartCount,
    int? crashesInWindow,
    String? lastErrorClass,
    String? lastPluginErrorClass,
    int? version,
    DateTime? heartbeatAt,
  });
  @override
  Map<String, dynamic> toJson() {
    return {
      '__className__': 'PluginInstanceStatus',
      if (id != null) 'id': id,
      'hostInstanceId': hostInstanceId,
      'outputId': outputId,
      'definitionDigest': definitionDigest,
      'state': state,
      if (pluginName != null) 'pluginName': pluginName,
      if (pluginVersion != null) 'pluginVersion': pluginVersion,
      if (pid != null) 'pid': pid,
      'restartCount': restartCount,
      'crashesInWindow': crashesInWindow,
      if (lastErrorClass != null) 'lastErrorClass': lastErrorClass,
      if (lastPluginErrorClass != null)
        'lastPluginErrorClass': lastPluginErrorClass,
      'version': version,
      'heartbeatAt': heartbeatAt.toJson(),
    };
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {};
  }

  static PluginInstanceStatusInclude include() {
    return PluginInstanceStatusInclude._();
  }

  static PluginInstanceStatusIncludeList includeList({
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    PluginInstanceStatusInclude? include,
  }) {
    return PluginInstanceStatusIncludeList._(
      where: where,
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      include: include,
    );
  }

  @override
  String toString() {
    return _is.SerializationManager.encode(this);
  }
}

class _Undefined {}

class _PluginInstanceStatusImpl extends PluginInstanceStatus {
  _PluginInstanceStatusImpl({
    int? id,
    required String hostInstanceId,
    required String outputId,
    required String definitionDigest,
    required String state,
    String? pluginName,
    String? pluginVersion,
    int? pid,
    required int restartCount,
    required int crashesInWindow,
    String? lastErrorClass,
    String? lastPluginErrorClass,
    required int version,
    required DateTime heartbeatAt,
  }) : super._(
         id: id,
         hostInstanceId: hostInstanceId,
         outputId: outputId,
         definitionDigest: definitionDigest,
         state: state,
         pluginName: pluginName,
         pluginVersion: pluginVersion,
         pid: pid,
         restartCount: restartCount,
         crashesInWindow: crashesInWindow,
         lastErrorClass: lastErrorClass,
         lastPluginErrorClass: lastPluginErrorClass,
         version: version,
         heartbeatAt: heartbeatAt,
       );

  /// Returns a shallow copy of this [PluginInstanceStatus]
  /// with some or all fields replaced by the given arguments.
  @_is.useResult
  @override
  PluginInstanceStatus copyWith({
    Object? id = _Undefined,
    String? hostInstanceId,
    String? outputId,
    String? definitionDigest,
    String? state,
    Object? pluginName = _Undefined,
    Object? pluginVersion = _Undefined,
    Object? pid = _Undefined,
    int? restartCount,
    int? crashesInWindow,
    Object? lastErrorClass = _Undefined,
    Object? lastPluginErrorClass = _Undefined,
    int? version,
    DateTime? heartbeatAt,
  }) {
    return PluginInstanceStatus(
      id: id is int? ? id : this.id,
      hostInstanceId: hostInstanceId ?? this.hostInstanceId,
      outputId: outputId ?? this.outputId,
      definitionDigest: definitionDigest ?? this.definitionDigest,
      state: state ?? this.state,
      pluginName: pluginName is String? ? pluginName : this.pluginName,
      pluginVersion: pluginVersion is String?
          ? pluginVersion
          : this.pluginVersion,
      pid: pid is int? ? pid : this.pid,
      restartCount: restartCount ?? this.restartCount,
      crashesInWindow: crashesInWindow ?? this.crashesInWindow,
      lastErrorClass: lastErrorClass is String?
          ? lastErrorClass
          : this.lastErrorClass,
      lastPluginErrorClass: lastPluginErrorClass is String?
          ? lastPluginErrorClass
          : this.lastPluginErrorClass,
      version: version ?? this.version,
      heartbeatAt: heartbeatAt ?? this.heartbeatAt,
    );
  }
}

class PluginInstanceStatusUpdateTable
    extends _is.UpdateTable<PluginInstanceStatusTable> {
  PluginInstanceStatusUpdateTable(super.table);

  _is.ColumnValue<String, String> hostInstanceId(String value) =>
      _is.ColumnValue(
        table.hostInstanceId,
        value,
      );

  _is.ColumnValue<String, String> outputId(String value) => _is.ColumnValue(
    table.outputId,
    value,
  );

  _is.ColumnValue<String, String> definitionDigest(String value) =>
      _is.ColumnValue(
        table.definitionDigest,
        value,
      );

  _is.ColumnValue<String, String> state(String value) => _is.ColumnValue(
    table.state,
    value,
  );

  _is.ColumnValue<String, String> pluginName(String? value) => _is.ColumnValue(
    table.pluginName,
    value,
  );

  _is.ColumnValue<String, String> pluginVersion(String? value) =>
      _is.ColumnValue(
        table.pluginVersion,
        value,
      );

  _is.ColumnValue<int, int> pid(int? value) => _is.ColumnValue(
    table.pid,
    value,
  );

  _is.ColumnValue<int, int> restartCount(int value) => _is.ColumnValue(
    table.restartCount,
    value,
  );

  _is.ColumnValue<int, int> crashesInWindow(int value) => _is.ColumnValue(
    table.crashesInWindow,
    value,
  );

  _is.ColumnValue<String, String> lastErrorClass(String? value) =>
      _is.ColumnValue(
        table.lastErrorClass,
        value,
      );

  _is.ColumnValue<String, String> lastPluginErrorClass(String? value) =>
      _is.ColumnValue(
        table.lastPluginErrorClass,
        value,
      );

  _is.ColumnValue<int, int> version(int value) => _is.ColumnValue(
    table.version,
    value,
  );

  _is.ColumnValue<DateTime, DateTime> heartbeatAt(DateTime value) =>
      _is.ColumnValue(
        table.heartbeatAt,
        value,
      );
}

class PluginInstanceStatusTable extends _is.Table<int?> {
  PluginInstanceStatusTable({super.tableRelation})
    : super(tableName: 'plugin_instance_status') {
    updateTable = PluginInstanceStatusUpdateTable(this);
    hostInstanceId = _is.ColumnString(
      'hostInstanceId',
      this,
    );
    outputId = _is.ColumnString(
      'outputId',
      this,
    );
    definitionDigest = _is.ColumnString(
      'definitionDigest',
      this,
    );
    state = _is.ColumnString(
      'state',
      this,
    );
    pluginName = _is.ColumnString(
      'pluginName',
      this,
    );
    pluginVersion = _is.ColumnString(
      'pluginVersion',
      this,
    );
    pid = _is.ColumnInt(
      'pid',
      this,
    );
    restartCount = _is.ColumnInt(
      'restartCount',
      this,
    );
    crashesInWindow = _is.ColumnInt(
      'crashesInWindow',
      this,
    );
    lastErrorClass = _is.ColumnString(
      'lastErrorClass',
      this,
    );
    lastPluginErrorClass = _is.ColumnString(
      'lastPluginErrorClass',
      this,
    );
    version = _is.ColumnInt(
      'version',
      this,
    );
    heartbeatAt = _is.ColumnDateTime(
      'heartbeatAt',
      this,
    );
  }

  late final PluginInstanceStatusUpdateTable updateTable;

  late final _is.ColumnString hostInstanceId;

  late final _is.ColumnString outputId;

  late final _is.ColumnString definitionDigest;

  late final _is.ColumnString state;

  late final _is.ColumnString pluginName;

  late final _is.ColumnString pluginVersion;

  late final _is.ColumnInt pid;

  late final _is.ColumnInt restartCount;

  late final _is.ColumnInt crashesInWindow;

  late final _is.ColumnString lastErrorClass;

  late final _is.ColumnString lastPluginErrorClass;

  late final _is.ColumnInt version;

  late final _is.ColumnDateTime heartbeatAt;

  @override
  List<_is.Column> get columns => [
    id,
    hostInstanceId,
    outputId,
    definitionDigest,
    state,
    pluginName,
    pluginVersion,
    pid,
    restartCount,
    crashesInWindow,
    lastErrorClass,
    lastPluginErrorClass,
    version,
    heartbeatAt,
  ];
}

class PluginInstanceStatusInclude extends _is.IncludeObject {
  PluginInstanceStatusInclude._();

  @override
  Map<String, _is.Include?> get includes => {};

  @override
  _is.Table<int?> get table => PluginInstanceStatus.t;
}

class PluginInstanceStatusIncludeList extends _is.IncludeList {
  PluginInstanceStatusIncludeList._({
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    super.limit,
    super.offset,
    super.orderBy,
    super.orderByList,
    super.include,
  }) {
    super.where = where?.call(PluginInstanceStatus.t);
  }

  @override
  Map<String, _is.Include?> get includes => include?.includes ?? {};

  @override
  _is.Table<int?> get table => PluginInstanceStatus.t;
}

class PluginInstanceStatusRepository {
  const PluginInstanceStatusRepository._();

  /// Returns a list of [PluginInstanceStatus]s matching the given query parameters.
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
  Future<List<PluginInstanceStatus>> find(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.find<PluginInstanceStatus>(
      where: where?.call(PluginInstanceStatus.t),
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      limit: limit,
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Emits [PluginInstanceStatus]s matching the given query parameters every time the
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
  /// to that set. Pass [Table] instances such as `PluginInstanceStatus.t`.
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
  _ida.Stream<List<PluginInstanceStatus>> watch(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    Duration? throttle = const Duration(milliseconds: 30),
    Iterable<_is.Table>? alsoTriggerOnTables,
  }) {
    return session.db.watch<PluginInstanceStatus>(
      where: where?.call(PluginInstanceStatus.t),
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      limit: limit,
      offset: offset,
      throttle: throttle,
      alsoTriggerOnTables: alsoTriggerOnTables,
    );
  }

  /// Returns the first matching [PluginInstanceStatus] matching the given query parameters.
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
  Future<PluginInstanceStatus?> findFirstRow(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    int? offset,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findFirstRow<PluginInstanceStatus>(
      where: where?.call(PluginInstanceStatus.t),
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      offset: offset,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Finds a single [PluginInstanceStatus] by its [id] or null if no such row exists.
  Future<PluginInstanceStatus?> findById(
    _is.DatabaseSession session,
    int id, {
    _is.Transaction? transaction,
    _is.LockMode? lockMode,
    _is.LockBehavior? lockBehavior,
  }) async {
    return session.db.findById<PluginInstanceStatus>(
      id,
      transaction: transaction,
      lockMode: lockMode,
      lockBehavior: lockBehavior,
    );
  }

  /// Inserts all [PluginInstanceStatus]s in the list and returns the inserted rows.
  ///
  /// The returned [PluginInstanceStatus]s will have their `id` fields set.
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
  Future<List<PluginInstanceStatus>> insert(
    _is.DatabaseSession session,
    List<PluginInstanceStatus> rows, {
    _is.Transaction? transaction,
    bool ignoreConflicts = false,
    bool noReturn = false,
  }) async {
    return session.db.insert<PluginInstanceStatus>(
      rows,
      transaction: transaction,
      ignoreConflicts: ignoreConflicts,
      noReturn: noReturn,
    );
  }

  /// Inserts a single [PluginInstanceStatus] and returns the inserted row.
  ///
  /// The returned [PluginInstanceStatus] will have its `id` field set.
  Future<PluginInstanceStatus> insertRow(
    _is.DatabaseSession session,
    PluginInstanceStatus row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.insertRow<PluginInstanceStatus>(
      row,
      transaction: transaction,
    );
  }

  /// Upserts all [PluginInstanceStatus]s in the list and returns the resulting rows.
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
  /// The returned [PluginInstanceStatus]s will have their `id` fields set.
  ///
  /// This is an atomic operation, meaning that if one of the rows fails,
  /// none of the rows will be affected.
  ///
  /// If [noReturn] is set to `true`, the resulting rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginInstanceStatus>> upsert(
    _is.DatabaseSession session,
    List<PluginInstanceStatus> rows, {
    required _is.ColumnSelections<PluginInstanceStatusTable> conflictColumns,
    _is.ColumnSelections<PluginInstanceStatusTable>? updateColumns,
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? updateWhere,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.upsert<PluginInstanceStatus>(
      rows,
      conflictColumns: conflictColumns(PluginInstanceStatus.t),
      updateColumns: updateColumns?.call(PluginInstanceStatus.t),
      updateWhere: updateWhere?.call(PluginInstanceStatus.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Upserts a single [PluginInstanceStatus] and returns the resulting row.
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
  /// The returned [PluginInstanceStatus] will have its `id` field set.
  Future<PluginInstanceStatus?> upsertRow(
    _is.DatabaseSession session,
    PluginInstanceStatus row, {
    required _is.ColumnSelections<PluginInstanceStatusTable> conflictColumns,
    _is.ColumnSelections<PluginInstanceStatusTable>? updateColumns,
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? updateWhere,
    _is.Transaction? transaction,
  }) async {
    return session.db.upsertRow<PluginInstanceStatus>(
      row,
      conflictColumns: conflictColumns(PluginInstanceStatus.t),
      updateColumns: updateColumns?.call(PluginInstanceStatus.t),
      updateWhere: updateWhere?.call(PluginInstanceStatus.t),
      transaction: transaction,
    );
  }

  /// Updates all [PluginInstanceStatus]s in the list and returns the updated rows. If
  /// [columns] is provided, only those columns will be updated. Defaults to
  /// all columns.
  /// This is an atomic operation, meaning that if one of the rows fails to
  /// update, none of the rows will be updated.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginInstanceStatus>> update(
    _is.DatabaseSession session,
    List<PluginInstanceStatus> rows, {
    _is.ColumnSelections<PluginInstanceStatusTable>? columns,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.update<PluginInstanceStatus>(
      rows,
      columns: columns?.call(PluginInstanceStatus.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Updates a single [PluginInstanceStatus]. The row needs to have its id set.
  /// Optionally, a list of [columns] can be provided to only update those
  /// columns. Defaults to all columns.
  Future<PluginInstanceStatus> updateRow(
    _is.DatabaseSession session,
    PluginInstanceStatus row, {
    _is.ColumnSelections<PluginInstanceStatusTable>? columns,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateRow<PluginInstanceStatus>(
      row,
      columns: columns?.call(PluginInstanceStatus.t),
      transaction: transaction,
    );
  }

  /// Updates a single [PluginInstanceStatus] by its [id] with the specified [columnValues].
  /// Returns the updated row or null if no row with the given id exists.
  Future<PluginInstanceStatus?> updateById(
    _is.DatabaseSession session,
    int id, {
    required _is.ColumnValueListBuilder<PluginInstanceStatusUpdateTable>
    columnValues,
    _is.Transaction? transaction,
  }) async {
    return session.db.updateById<PluginInstanceStatus>(
      id,
      columnValues: columnValues(PluginInstanceStatus.t.updateTable),
      transaction: transaction,
    );
  }

  /// Updates all [PluginInstanceStatus]s matching the [where] expression with the specified [columnValues].
  /// Returns the list of updated rows.
  ///
  /// If [noReturn] is set to `true`, the updated rows are not read back from
  /// the database and an empty list is returned. This avoids the overhead of
  /// transferring and deserializing the rows when the result is not needed.
  Future<List<PluginInstanceStatus>> updateWhere(
    _is.DatabaseSession session, {
    required _is.ColumnValueListBuilder<PluginInstanceStatusUpdateTable>
    columnValues,
    required _is.WhereExpressionBuilder<PluginInstanceStatusTable> where,
    int? limit,
    int? offset,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.updateWhere<PluginInstanceStatus>(
      columnValues: columnValues(PluginInstanceStatus.t.updateTable),
      where: where(PluginInstanceStatus.t),
      limit: limit,
      offset: offset,
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes all [PluginInstanceStatus]s in the list and returns the deleted rows.
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
  Future<List<PluginInstanceStatus>> delete(
    _is.DatabaseSession session,
    List<PluginInstanceStatus> rows, {
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.delete<PluginInstanceStatus>(
      rows,
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Deletes a single [PluginInstanceStatus].
  Future<PluginInstanceStatus> deleteRow(
    _is.DatabaseSession session,
    PluginInstanceStatus row, {
    _is.Transaction? transaction,
  }) async {
    return session.db.deleteRow<PluginInstanceStatus>(
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
  Future<List<PluginInstanceStatus>> deleteWhere(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PluginInstanceStatusTable> where,
    _is.OrderByBuilder<PluginInstanceStatusTable>? orderBy,
    _is.OrderByListBuilder<PluginInstanceStatusTable>? orderByList,
    _is.Transaction? transaction,
    bool noReturn = false,
  }) async {
    return session.db.deleteWhere<PluginInstanceStatus>(
      where: where(PluginInstanceStatus.t),
      orderBy: orderBy?.call(PluginInstanceStatus.t),
      orderByList: orderByList?.call(PluginInstanceStatus.t),
      transaction: transaction,
      noReturn: noReturn,
    );
  }

  /// Counts the number of rows matching the [where] expression. If omitted,
  /// will return the count of all rows in the table.
  Future<int> count(
    _is.DatabaseSession session, {
    _is.WhereExpressionBuilder<PluginInstanceStatusTable>? where,
    int? limit,
    _is.Transaction? transaction,
  }) async {
    return session.db.count<PluginInstanceStatus>(
      where: where?.call(PluginInstanceStatus.t),
      limit: limit,
      transaction: transaction,
    );
  }

  /// Acquires row-level locks on [PluginInstanceStatus] rows matching the [where] expression.
  Future<void> lockRows(
    _is.DatabaseSession session, {
    required _is.WhereExpressionBuilder<PluginInstanceStatusTable> where,
    required _is.LockMode lockMode,
    required _is.Transaction transaction,
    _is.LockBehavior lockBehavior = _is.LockBehavior.wait,
  }) async {
    return session.db.lockRows<PluginInstanceStatus>(
      where: where(PluginInstanceStatus.t),
      lockMode: lockMode,
      lockBehavior: lockBehavior,
      transaction: transaction,
    );
  }
}
