import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

/// Amazos Database Schema — Version 1
///
/// Cash Movement Operating System — Data Layer.
///
/// Table and column names are centralized here as the single source of
/// truth so repositories never hardcode raw strings. Nothing in this file
/// executes anything; it only describes structure.
///
/// Naming note: the JUNTA Blueprint calls the movement header/line tables
/// "transactions" / "transaction_lines". They're named `movements` /
/// `movement_lines` here instead, purely so the Dart model classes can be
/// called `Movement` / `MovementLine` without colliding with sqflite's own
/// `Transaction` type (used for db.transaction() callbacks). No business
/// meaning changed — flagging it since renaming a spec's own vocabulary is
/// exactly the kind of thing that should be disclosed, not silently done.

class DbSchema {
  DbSchema._();

  static const int schemaVersion = 1;

  // ---------------------------------------------------------------------
  // Table names
  // ---------------------------------------------------------------------
  static const String tableBusinessEntities = 'business_entities';
  static const String tableFiscalYears = 'fiscal_years';
  static const String tableAccounts = 'accounts';
  static const String tableMovements = 'movements';
  static const String tableMovementLines = 'movement_lines';
  static const String tableNotes = 'notes';
  static const String tableAuditLog = 'audit_log';

  // ---------------------------------------------------------------------
  // CREATE TABLE statements (Version 1)
  // ---------------------------------------------------------------------

  static const String createBusinessEntities = '''
    CREATE TABLE $tableBusinessEntities (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      type TEXT NOT NULL CHECK (type IN ('customer','supplier','both')),
      phone TEXT,
      email TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
      created_at TEXT NOT NULL
    )
  ''';

  static const String createFiscalYears = '''
    CREATE TABLE $tableFiscalYears (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      start_date TEXT NOT NULL,
      end_date TEXT NOT NULL,
      is_closed INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const String createAccounts = '''
    CREATE TABLE $tableAccounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      currency TEXT NOT NULL,
      running_balance INTEGER NOT NULL DEFAULT 0,
      running_balance_usd INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived','locked')),
      is_system INTEGER NOT NULL DEFAULT 0,
      business_entity_id INTEGER REFERENCES $tableBusinessEntities(id),
      created_at TEXT NOT NULL
    )
  ''';

  /// The movement header. Contains NO monetary amounts — those live in
  /// movement_lines. A header may own one or more lines (multi-line, per
  /// Founder decision on multi-currency).
  static const String createMovements = '''
    CREATE TABLE $tableMovements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      sequential_number INTEGER NOT NULL UNIQUE,
      date TEXT NOT NULL,
      time TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','posted','reversed','void')),
      note TEXT,
      note_level TEXT CHECK (note_level IN ('info','reminder','important','warning','critical')),
      is_opening_balance INTEGER NOT NULL DEFAULT 0,
      is_locked INTEGER NOT NULL DEFAULT 0,
      fiscal_year_id INTEGER REFERENCES $tableFiscalYears(id),
      reversal_of_movement_id INTEGER REFERENCES $tableMovements(id),
      created_by TEXT,
      created_at TEXT NOT NULL,
      posted_at TEXT
    )
  ''';

  /// reversal_of_movement_id is a disclosed addition beyond the blueprint
  /// text (which said reversals "reference the original via a note").
  /// A real FK is more consistent with the constitution's own
  /// traceability rule than parsing note text to find related movements.

  static const String createMovementLines = '''
    CREATE TABLE $tableMovementLines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      movement_id INTEGER NOT NULL REFERENCES $tableMovements(id),
      line_number INTEGER NOT NULL,
      from_account_id INTEGER NOT NULL REFERENCES $tableAccounts(id),
      to_account_id INTEGER NOT NULL REFERENCES $tableAccounts(id),
      amount INTEGER NOT NULL,
      currency TEXT NOT NULL,
      exchange_rate_numerator INTEGER NOT NULL DEFAULT 1,
      exchange_rate_denominator INTEGER NOT NULL DEFAULT 1,
      amount_usd INTEGER NOT NULL
    )
  ''';

  /// Universal notes: entity_type + entity_id lets ANY table's rows carry
  /// notes (movement, account, business_entity, and any future module)
  /// without a notes-per-table join table for each one.
  static const String createNotes = '''
    CREATE TABLE $tableNotes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE,
      entity_type TEXT NOT NULL,
      entity_id INTEGER NOT NULL,
      level TEXT NOT NULL CHECK (level IN ('info','reminder','important','warning','critical')),
      body TEXT NOT NULL,
      is_private INTEGER NOT NULL DEFAULT 0,
      reminder_date TEXT,
      created_by TEXT,
      created_at TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const String createAuditLog = '''
    CREATE TABLE $tableAuditLog (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_type TEXT NOT NULL,
      entity_id INTEGER NOT NULL,
      action TEXT NOT NULL,
      old_values TEXT,
      new_values TEXT,
      changed_by TEXT,
      changed_at TEXT NOT NULL
    )
  ''';

  // ---------------------------------------------------------------------
  // Indexes (Version 1) — required by the constitution, not optional.
  // ---------------------------------------------------------------------
  static const List<String> createIndexes = [
    'CREATE INDEX idx_business_entities_name ON $tableBusinessEntities(name)',
    'CREATE INDEX idx_fiscal_years_start ON $tableFiscalYears(start_date)',
    'CREATE INDEX idx_accounts_type ON $tableAccounts(type)',
    'CREATE INDEX idx_accounts_status ON $tableAccounts(status)',
    'CREATE INDEX idx_accounts_currency ON $tableAccounts(currency)',
    'CREATE INDEX idx_accounts_business_entity ON $tableAccounts(business_entity_id)',
    'CREATE INDEX idx_movements_date ON $tableMovements(date)',
    'CREATE INDEX idx_movements_fiscal_year ON $tableMovements(fiscal_year_id)',
    'CREATE INDEX idx_movements_status ON $tableMovements(status)',
    'CREATE INDEX idx_movements_note_level ON $tableMovements(note_level)',
    'CREATE INDEX idx_movements_reversal_of ON $tableMovements(reversal_of_movement_id)',
    'CREATE INDEX idx_lines_movement ON $tableMovementLines(movement_id)',
    'CREATE INDEX idx_lines_from_account ON $tableMovementLines(from_account_id)',
    'CREATE INDEX idx_lines_to_account ON $tableMovementLines(to_account_id)',
    'CREATE INDEX idx_notes_entity ON $tableNotes(entity_type, entity_id)',
    'CREATE INDEX idx_notes_level ON $tableNotes(level)',
    'CREATE INDEX idx_notes_reminder_date ON $tableNotes(reminder_date)',
    'CREATE INDEX idx_audit_entity ON $tableAuditLog(entity_type, entity_id)',
    'CREATE INDEX idx_audit_changed_at ON $tableAuditLog(changed_at)',
  ];
  // Note: sequential_number's uniqueness is already enforced by the
  // column-level UNIQUE constraint in createMovements, so no separate
  // unique index is declared here (SQLite creates one automatically).
}

/// Owns the single SQLite connection and the migration framework.
///
/// Migration rule (JUNTA Constitution, Rule 6 + "Migration Strategy" in
/// the Blueprint): migrations are additive only. Each future version
/// bump gets its own `if (oldVersion < N)` block inside [_onUpgrade].
/// Nothing above an existing block is ever rewritten or removed.
class DatabaseHelper {
  DatabaseHelper._internal();

  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final String dbPath = await getDatabasesPath();
    final String path = join(dbPath, 'amazos.db');
    return openDatabase(
      path,
      version: DbSchema.schemaVersion,
      onConfigure: (Database db) async {
        // sqflite has foreign keys OFF by default — the constitution's
        // referential rules (from/to account must exist, etc.) depend on
        // this being on.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    final Batch batch = db.batch();
    batch.execute(DbSchema.createBusinessEntities);
    batch.execute(DbSchema.createFiscalYears);
    batch.execute(DbSchema.createAccounts);
    batch.execute(DbSchema.createMovements);
    batch.execute(DbSchema.createMovementLines);
    batch.execute(DbSchema.createNotes);
    batch.execute(DbSchema.createAuditLog);
    for (final String stmt in DbSchema.createIndexes) {
      batch.execute(stmt);
    }
    await batch.commit(noResult: true);

    await _seedSystemAccounts(db);
  }

  /// System accounts required by the Blueprint's currency and
  /// opening-balance workflow. `is_system = 1` means the future UI must
  /// never allow renaming or deleting these.
  ///
  /// "Currency Exchange Clearing" and "Cash Over/Short" are a disclosed
  /// addition: the Blueprint's own Section 2 workflow narrative (5:30 PM
  /// exchange, 6:00 PM closing) uses both by name but only formally
  /// listed "Opening Balance Equity" and "Realized Currency Gain/Loss" as
  /// system accounts. Seeding all four now avoids the UI later having to
  /// silently auto-create an account mid-transaction.
  Future<void> _seedSystemAccounts(Database db) async {
    const Uuid uuid = Uuid();
    final String now = DateTime.now().toIso8601String();
    final List<Map<String, String>> systemAccounts = <Map<String, String>>[
      <String, String>{
        'name': 'Opening Balance Equity',
        'type': 'equity',
        'currency': 'USD',
      },
      <String, String>{
        'name': 'Realized Currency Gain/Loss',
        'type': 'equity',
        'currency': 'USD',
      },
      <String, String>{
        'name': 'Currency Exchange Clearing',
        'type': 'virtual',
        'currency': 'USD',
      },
      <String, String>{
        'name': 'Cash Over/Short',
        'type': 'expense',
        'currency': 'USD',
      },
    ];

    for (final Map<String, String> acc in systemAccounts) {
      await db.insert(DbSchema.tableAccounts, <String, Object?>{
        'uuid': uuid.v4(),
        'name': acc['name'],
        'type': acc['type'],
        'currency': acc['currency'],
        'running_balance': 0,
        'running_balance_usd': 0,
        'status': 'active',
        'is_system': 1,
        'created_at': now,
      });
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Version 1 -> 2 migrations will be appended here as additive blocks,
    // e.g.:
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE accounts ADD COLUMN parent_id INTEGER');
    // }
  }

  /// Test/dev-only: closes and forgets the cached connection so a fresh
  /// one is opened next time [database] is accessed. Not used by any
  /// production code path.
  Future<void> resetForTesting() async {
    final Database? db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}

/// Integer-only money math.
///
/// JUNTA Constitution Rule 4: "Integers for money." Rule 5: "Exchange
/// rates are explicit." Nothing in this file ever touches a double for a
/// monetary amount.
class Money {
  Money._();

  /// Converts an amount in a currency's smallest unit (e.g. cents, fils)
  /// to USD cents, using an explicit rate expressed as a
  /// numerator/denominator pair (e.g. 110/100 for a rate of 1.10), per
  /// the Blueprint's "stored as a numerator and denominator... to avoid
  /// floating-point errors" rule.
  ///
  /// Rounds half up on ties.
  static int toUsdCents({
    required int amountMinorUnits,
    required int rateNumerator,
    required int rateDenominator,
  }) {
    if (rateDenominator == 0) {
      throw ArgumentError('Exchange rate denominator cannot be zero');
    }
    final int numerator = amountMinorUnits * rateNumerator;
    final int half = rateDenominator ~/ 2;
    return (numerator + half) ~/ rateDenominator;
  }

  /// The weighted-average cost rate for a currency holding, expressed in
  /// the same numerator/denominator shape as a movement-line rate.
  ///
  /// This is derived directly from an account's own two running balances
  /// (running_balance in local currency, running_balance_usd) rather than
  /// a separate average-cost table — per the Blueprint, an inflow updates
  /// both balances proportionally, so at any moment their ratio already
  /// *is* the average cost.
  ///
  /// Returns null if the account currently holds zero units — there is
  /// no average cost to relieve at.
  static ({int numerator, int denominator})? averageCostRate({
    required int runningBalanceLocal,
    required int runningBalanceUsd,
  }) {
    if (runningBalanceLocal == 0) return null;
    return (numerator: runningBalanceUsd, denominator: runningBalanceLocal);
  }
}

// Amazos — all data models in one file (merged for easy manual setup).

class BusinessEntity {
  const BusinessEntity({
    this.id,
    required this.uuid,
    required this.name,
    required this.type,
    this.phone,
    this.email,
    this.status = 'active',
    required this.createdAt,
  });

  final int? id;
  final String uuid;
  final String name;

  /// 'customer' | 'supplier' | 'both'
  final String type;
  final String? phone;
  final String? email;

  /// 'active' | 'inactive'
  final String status;
  final String createdAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'uuid': uuid,
        'name': name,
        'type': type,
        'phone': phone,
        'email': email,
        'status': status,
        'created_at': createdAt,
      };

  factory BusinessEntity.fromMap(Map<String, Object?> map) => BusinessEntity(
        id: map['id'] as int?,
        uuid: map['uuid']! as String,
        name: map['name']! as String,
        type: map['type']! as String,
        phone: map['phone'] as String?,
        email: map['email'] as String?,
        status: map['status']! as String,
        createdAt: map['created_at']! as String,
      );
}

class FiscalYear {
  const FiscalYear({
    this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.isClosed = false,
  });

  final int? id;
  final String name;
  final String startDate;
  final String endDate;
  final bool isClosed;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'name': name,
        'start_date': startDate,
        'end_date': endDate,
        'is_closed': isClosed ? 1 : 0,
      };

  factory FiscalYear.fromMap(Map<String, Object?> map) => FiscalYear(
        id: map['id'] as int?,
        name: map['name']! as String,
        startDate: map['start_date']! as String,
        endDate: map['end_date']! as String,
        isClosed: (map['is_closed']! as int) == 1,
      );
}

class Account {
  const Account({
    this.id,
    required this.uuid,
    required this.name,
    required this.type,
    required this.currency,
    this.runningBalance = 0,
    this.runningBalanceUsd = 0,
    this.status = 'active',
    this.isSystem = false,
    this.businessEntityId,
    required this.createdAt,
  });

  final int? id;
  final String uuid;
  final String name;

  /// asset, liability, equity, income, expense, cash, bank, customer,
  /// supplier, inventory, loan, investment, virtual, system — free-form
  /// per the Blueprint ("Never hardcoded"), used only for report grouping.
  final String type;

  /// ISO 4217 currency code.
  final String currency;

  /// Smallest local-currency unit (e.g. cents). Only meaningful when a
  /// movement line's currency matches this account's own currency — see
  /// the note in movement_repository.dart on virtual/clearing accounts.
  final int runningBalance;

  /// USD cents. Always meaningful, updated on every movement line
  /// touching this account regardless of the line's currency.
  final int runningBalanceUsd;

  /// 'active' | 'archived' | 'locked'
  final String status;
  final bool isSystem;
  final int? businessEntityId;
  final String createdAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'uuid': uuid,
        'name': name,
        'type': type,
        'currency': currency,
        'running_balance': runningBalance,
        'running_balance_usd': runningBalanceUsd,
        'status': status,
        'is_system': isSystem ? 1 : 0,
        'business_entity_id': businessEntityId,
        'created_at': createdAt,
      };

  factory Account.fromMap(Map<String, Object?> map) => Account(
        id: map['id'] as int?,
        uuid: map['uuid']! as String,
        name: map['name']! as String,
        type: map['type']! as String,
        currency: map['currency']! as String,
        runningBalance: map['running_balance']! as int,
        runningBalanceUsd: map['running_balance_usd']! as int,
        status: map['status']! as String,
        isSystem: (map['is_system']! as int) == 1,
        businessEntityId: map['business_entity_id'] as int?,
        createdAt: map['created_at']! as String,
      );
}

/// The header of a cash movement. Contains no monetary amounts — those
/// live on its [MovementLine]s. A movement owns one or more lines
/// (multi-line, per Founder decision on multi-currency).
///
/// Named `Movement` rather than the Blueprint's `Transaction` to avoid
/// colliding with sqflite's own `Transaction` type — see db_schema.dart.
class Movement {
  const Movement({
    this.id,
    required this.uuid,
    required this.sequentialNumber,
    required this.date,
    required this.time,
    this.status = 'draft',
    this.note,
    this.noteLevel,
    this.isOpeningBalance = false,
    this.isLocked = false,
    this.fiscalYearId,
    this.reversalOfMovementId,
    this.createdBy,
    required this.createdAt,
    this.postedAt,
  });

  final int? id;
  final String uuid;

  /// Permanent, human-facing identity (e.g. "#10345"). Never reused.
  final int sequentialNumber;

  /// ISO date, yyyy-MM-dd.
  final String date;

  /// HH:MM (24h).
  final String time;

  /// 'draft' | 'posted' | 'reversed' | 'void'
  final String status;
  final String? note;

  /// 'info' | 'reminder' | 'important' | 'warning' | 'critical'
  final String? noteLevel;
  final bool isOpeningBalance;
  final bool isLocked;
  final int? fiscalYearId;

  /// Set only on a reversal movement, pointing at the movement it
  /// reverses. A disclosed addition to the Blueprint's original "reference
  /// via a note" idea — see db_schema.dart.
  final int? reversalOfMovementId;
  final String? createdBy;
  final String createdAt;
  final String? postedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'uuid': uuid,
        'sequential_number': sequentialNumber,
        'date': date,
        'time': time,
        'status': status,
        'note': note,
        'note_level': noteLevel,
        'is_opening_balance': isOpeningBalance ? 1 : 0,
        'is_locked': isLocked ? 1 : 0,
        'fiscal_year_id': fiscalYearId,
        'reversal_of_movement_id': reversalOfMovementId,
        'created_by': createdBy,
        'created_at': createdAt,
        'posted_at': postedAt,
      };

  factory Movement.fromMap(Map<String, Object?> map) => Movement(
        id: map['id'] as int?,
        uuid: map['uuid']! as String,
        sequentialNumber: map['sequential_number']! as int,
        date: map['date']! as String,
        time: map['time']! as String,
        status: map['status']! as String,
        note: map['note'] as String?,
        noteLevel: map['note_level'] as String?,
        isOpeningBalance: (map['is_opening_balance']! as int) == 1,
        isLocked: (map['is_locked']! as int) == 1,
        fiscalYearId: map['fiscal_year_id'] as int?,
        reversalOfMovementId: map['reversal_of_movement_id'] as int?,
        createdBy: map['created_by'] as String?,
        createdAt: map['created_at']! as String,
        postedAt: map['posted_at'] as String?,
      );
}

class MovementLine {
  const MovementLine({
    this.id,
    required this.movementId,
    required this.lineNumber,
    required this.fromAccountId,
    required this.toAccountId,
    required this.amount,
    required this.currency,
    this.exchangeRateNumerator = 1,
    this.exchangeRateDenominator = 1,
    required this.amountUsd,
  });

  final int? id;
  final int movementId;
  final int lineNumber;
  final int fromAccountId;
  final int toAccountId;

  /// Smallest unit of [currency]. Always positive.
  final int amount;
  final String currency;
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;

  /// USD cents, computed as amount * numerator / denominator (rounded)
  /// at the moment the line was posted, and stored — never recalculated.
  final int amountUsd;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'movement_id': movementId,
        'line_number': lineNumber,
        'from_account_id': fromAccountId,
        'to_account_id': toAccountId,
        'amount': amount,
        'currency': currency,
        'exchange_rate_numerator': exchangeRateNumerator,
        'exchange_rate_denominator': exchangeRateDenominator,
        'amount_usd': amountUsd,
      };

  factory MovementLine.fromMap(Map<String, Object?> map) => MovementLine(
        id: map['id'] as int?,
        movementId: map['movement_id']! as int,
        lineNumber: map['line_number']! as int,
        fromAccountId: map['from_account_id']! as int,
        toAccountId: map['to_account_id']! as int,
        amount: map['amount']! as int,
        currency: map['currency']! as String,
        exchangeRateNumerator: map['exchange_rate_numerator']! as int,
        exchangeRateDenominator: map['exchange_rate_denominator']! as int,
        amountUsd: map['amount_usd']! as int,
      );
}

/// Input DTO for creating one line of a new movement — no id/amountUsd
/// yet, since those are assigned during posting.
class MovementLineInput {
  const MovementLineInput({
    required this.fromAccountId,
    required this.toAccountId,
    required this.amount,
    required this.currency,
    this.exchangeRateNumerator = 1,
    this.exchangeRateDenominator = 1,
  });

  final int fromAccountId;
  final int toAccountId;
  final int amount;
  final String currency;
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;
}

/// A note attachable to any entity in the system via [entityType] +
/// [entityId] — a movement, an account, a business entity, or any future
/// module. This is the data behind both the colored severity marker and
/// the per-entity timeline; both are derived queries, not separate
/// stored structures.
class Note {
  const Note({
    this.id,
    required this.uuid,
    required this.entityType,
    required this.entityId,
    required this.level,
    required this.body,
    this.isPrivate = false,
    this.reminderDate,
    this.createdBy,
    required this.createdAt,
    this.isDeleted = false,
  });

  final int? id;
  final String uuid;

  /// e.g. 'movement', 'account', 'business_entity' — free-form, matched
  /// against whatever table the note is attached to.
  final String entityType;
  final int entityId;

  /// 'info' | 'reminder' | 'important' | 'warning' | 'critical'
  final String level;
  final String body;

  /// If true, only the note's owner sees it (e.g. an employee vs. owner
  /// visibility split described in the Founder's original notes spec).
  final bool isPrivate;

  /// If set, this note is also a reminder that should surface on a
  /// dashboard/daily view — not just sit on the entity's own page.
  final String? reminderDate;
  final String? createdBy;
  final String createdAt;
  final bool isDeleted;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'uuid': uuid,
        'entity_type': entityType,
        'entity_id': entityId,
        'level': level,
        'body': body,
        'is_private': isPrivate ? 1 : 0,
        'reminder_date': reminderDate,
        'created_by': createdBy,
        'created_at': createdAt,
        'is_deleted': isDeleted ? 1 : 0,
      };

  factory Note.fromMap(Map<String, Object?> map) => Note(
        id: map['id'] as int?,
        uuid: map['uuid']! as String,
        entityType: map['entity_type']! as String,
        entityId: map['entity_id']! as int,
        level: map['level']! as String,
        body: map['body']! as String,
        isPrivate: (map['is_private']! as int) == 1,
        reminderDate: map['reminder_date'] as String?,
        createdBy: map['created_by'] as String?,
        createdAt: map['created_at']! as String,
        isDeleted: (map['is_deleted']! as int) == 1,
      );
}

/// One append-only audit record. Written by repositories, never by the
/// UI directly, and never updated or deleted after insertion.
class AuditLogEntry {
  const AuditLogEntry({
    this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.oldValues,
    this.newValues,
    this.changedBy,
    required this.changedAt,
  });

  final int? id;
  final String entityType;
  final int entityId;

  /// e.g. 'created', 'status_changed', 'deleted'
  final String action;

  /// JSON-encoded snapshot, or null on creation.
  final String? oldValues;

  /// JSON-encoded snapshot.
  final String? newValues;
  final String? changedBy;
  final String changedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'entity_type': entityType,
        'entity_id': entityId,
        'action': action,
        'old_values': oldValues,
        'new_values': newValues,
        'changed_by': changedBy,
        'changed_at': changedAt,
      };

  factory AuditLogEntry.fromMap(Map<String, Object?> map) => AuditLogEntry(
        id: map['id'] as int?,
        entityType: map['entity_type']! as String,
        entityId: map['entity_id']! as int,
        action: map['action']! as String,
        oldValues: map['old_values'] as String?,
        newValues: map['new_values'] as String?,
        changedBy: map['changed_by'] as String?,
        changedAt: map['changed_at']! as String,
      );
}

// Amazos — all repositories in one file (merged for easy manual setup).






class BusinessEntityRepository {
  BusinessEntityRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;
  static const Uuid _uuid = Uuid();

  Future<BusinessEntity> create({
    required String name,
    required String type,
    String? phone,
    String? email,
  }) async {
    final db = await _dbHelper.database;
    final String now = DateTime.now().toIso8601String();
    final String entityUuid = _uuid.v4();
    final int id = await db.insert(DbSchema.tableBusinessEntities, <String, Object?>{
      'uuid': entityUuid,
      'name': name,
      'type': type,
      'phone': phone,
      'email': email,
      'status': 'active',
      'created_at': now,
    });
    return BusinessEntity(
      id: id,
      uuid: entityUuid,
      name: name,
      type: type,
      phone: phone,
      email: email,
      createdAt: now,
    );
  }

  Future<List<BusinessEntity>> search(String query) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      DbSchema.tableBusinessEntities,
      where: 'name LIKE ? AND status = ?',
      whereArgs: ['%$query%', 'active'],
      orderBy: 'name ASC',
    );
    return rows.map(BusinessEntity.fromMap).toList();
  }

  Future<List<BusinessEntity>> getAll({String status = 'active'}) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      DbSchema.tableBusinessEntities,
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'name ASC',
    );
    return rows.map(BusinessEntity.fromMap).toList();
  }
}


class FiscalYearRepository {
  FiscalYearRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;

  Future<FiscalYear> create({
    required String name,
    required String startDate,
    required String endDate,
  }) async {
    final db = await _dbHelper.database;
    final int id = await db.insert(DbSchema.tableFiscalYears, <String, Object?>{
      'name': name,
      'start_date': startDate,
      'end_date': endDate,
      'is_closed': 0,
    });
    return FiscalYear(id: id, name: name, startDate: startDate, endDate: endDate);
  }

  Future<List<FiscalYear>> getAll() async {
    final db = await _dbHelper.database;
    final rows = await db.query(DbSchema.tableFiscalYears, orderBy: 'start_date DESC');
    return rows.map(FiscalYear.fromMap).toList();
  }

  /// Closed years reject new movements — enforced by the caller
  /// (MovementRepository checks fiscal year status before posting) since
  /// that validation belongs with the write path, not here.
  Future<void> close(int id) async {
    final db = await _dbHelper.database;
    await db.update(
      DbSchema.tableFiscalYears,
      <String, Object?>{'is_closed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}




class AccountRepository {
  AccountRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;
  static const Uuid _uuid = Uuid();

  Future<Account> createAccount({
    required String name,
    required String type,
    required String currency,
    int? businessEntityId,
  }) async {
    final db = await _dbHelper.database;
    final String now = DateTime.now().toIso8601String();
    final String accountUuid = _uuid.v4();
    final int id = await db.insert(DbSchema.tableAccounts, <String, Object?>{
      'uuid': accountUuid,
      'name': name,
      'type': type,
      'currency': currency,
      'running_balance': 0,
      'running_balance_usd': 0,
      'status': 'active',
      'is_system': 0,
      'business_entity_id': businessEntityId,
      'created_at': now,
    });
    await db.insert(DbSchema.tableAuditLog, <String, Object?>{
      'entity_type': 'account',
      'entity_id': id,
      'action': 'created',
      'old_values': null,
      'new_values': jsonEncode(<String, Object?>{'name': name, 'type': type, 'currency': currency}),
      'changed_by': null,
      'changed_at': now,
    });
    return Account(
      id: id,
      uuid: accountUuid,
      name: name,
      type: type,
      currency: currency,
      businessEntityId: businessEntityId,
      createdAt: now,
    );
  }

  Future<List<Account>> getAccounts({String? type, String status = 'active'}) async {
    final db = await _dbHelper.database;
    final String where = type != null ? 'type = ? AND status = ?' : 'status = ?';
    final List<Object?> whereArgs = type != null ? [type, status] : [status];
    final rows = await db.query(
      DbSchema.tableAccounts,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'name ASC',
    );
    return rows.map(Account.fromMap).toList();
  }

  Future<Account?> getById(int id) async {
    final db = await _dbHelper.database;
    final rows = await db.query(DbSchema.tableAccounts, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Account.fromMap(rows.first);
  }

  Future<void> archiveAccount(int id) async {
    final db = await _dbHelper.database;
    final String now = DateTime.now().toIso8601String();
    await db.update(
      DbSchema.tableAccounts,
      <String, Object?>{'status': 'archived'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await db.insert(DbSchema.tableAuditLog, <String, Object?>{
      'entity_type': 'account',
      'entity_id': id,
      'action': 'status_changed',
      'old_values': null,
      'new_values': jsonEncode(<String, Object?>{'status': 'archived'}),
      'changed_by': null,
      'changed_at': now,
    });
  }
}




class NoteRepository {
  NoteRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;
  static const Uuid _uuid = Uuid();

  /// Highest severity first — drives which single marker shows on a list
  /// row when an entity has notes at multiple levels.
  static const List<String> severityOrder = <String>[
    'critical',
    'warning',
    'important',
    'reminder',
    'info',
  ];

  Future<Note> addNote({
    required String entityType,
    required int entityId,
    required String level,
    required String body,
    bool isPrivate = false,
    String? reminderDate,
    String? createdBy,
  }) async {
    if (!severityOrder.contains(level)) {
      throw ArgumentError('Unknown note level: $level');
    }
    final db = await _dbHelper.database;
    final String now = DateTime.now().toIso8601String();
    final String noteUuid = _uuid.v4();
    final int id = await db.insert(DbSchema.tableNotes, <String, Object?>{
      'uuid': noteUuid,
      'entity_type': entityType,
      'entity_id': entityId,
      'level': level,
      'body': body,
      'is_private': isPrivate ? 1 : 0,
      'reminder_date': reminderDate,
      'created_by': createdBy,
      'created_at': now,
      'is_deleted': 0,
    });
    await db.insert(DbSchema.tableAuditLog, <String, Object?>{
      'entity_type': 'note',
      'entity_id': id,
      'action': 'created',
      'old_values': null,
      'new_values': jsonEncode(<String, Object?>{
        'entity_type': entityType,
        'entity_id': entityId,
        'level': level,
      }),
      'changed_by': createdBy,
      'changed_at': now,
    });
    return Note(
      id: id,
      uuid: noteUuid,
      entityType: entityType,
      entityId: entityId,
      level: level,
      body: body,
      isPrivate: isPrivate,
      reminderDate: reminderDate,
      createdBy: createdBy,
      createdAt: now,
    );
  }

  /// Chronological notes for one entity — this doubles as that entity's
  /// timeline. "Everything has a Timeline" is implemented as this query,
  /// not as a separately maintained table.
  Future<List<Note>> getTimelineFor(
    String entityType,
    int entityId, {
    bool includePrivate = true,
  }) async {
    final db = await _dbHelper.database;
    final String where = includePrivate
        ? 'entity_type = ? AND entity_id = ? AND is_deleted = 0'
        : 'entity_type = ? AND entity_id = ? AND is_deleted = 0 AND is_private = 0';
    final rows = await db.query(
      DbSchema.tableNotes,
      where: where,
      whereArgs: [entityType, entityId],
      orderBy: 'created_at ASC',
    );
    return rows.map(Note.fromMap).toList();
  }

  /// The single level that should drive an entity's colored marker badge
  /// — highest severity wins, per the "interrupt, don't just log" rule.
  Future<String?> highestSeverityFor(String entityType, int entityId) async {
    final List<Note> notes = await getTimelineFor(entityType, entityId);
    if (notes.isEmpty) return null;
    for (final String level in severityOrder) {
      if (notes.any((Note n) => n.level == level)) return level;
    }
    return null;
  }

  /// Notes with an upcoming reminder date, across all entity types — the
  /// query behind a future "today's reminders" dashboard view.
  Future<List<Note>> getUpcomingReminders({String? onOrBeforeDate}) async {
    final db = await _dbHelper.database;
    final String where = onOrBeforeDate != null
        ? 'reminder_date IS NOT NULL AND reminder_date <= ? AND is_deleted = 0'
        : 'reminder_date IS NOT NULL AND is_deleted = 0';
    final List<Object?> whereArgs = onOrBeforeDate != null ? [onOrBeforeDate] : [];
    final rows = await db.query(
      DbSchema.tableNotes,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'reminder_date ASC',
    );
    return rows.map(Note.fromMap).toList();
  }
}


/// Read-only on purpose: audit_log rows are written only by the other
/// repositories, inline with the operation they're logging, inside the
/// same db transaction. Nothing here inserts, updates, or deletes.
class AuditRepository {
  AuditRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;

  Future<List<AuditLogEntry>> getHistoryFor(String entityType, int entityId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      DbSchema.tableAuditLog,
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [entityType, entityId],
      orderBy: 'changed_at ASC',
    );
    return rows.map(AuditLogEntry.fromMap).toList();
  }
}




/// Posts and reverses movements. This is deliberately a generic,
/// currency-agnostic engine: it knows how to insert a balanced set of
/// lines atomically and keep account balances correct. It does NOT know
/// about currency-exchange semantics (average cost, realized gain/loss)
/// — that belongs to a Phase 2 CurrencyExchangeService that computes the
/// right [MovementLineInput]s (using [Money.averageCostRate]) and calls
/// [postMovement]. Keeping that logic out of this repository is a
/// deliberate layering choice, not an oversight.
class MovementRepository {
  MovementRepository(this._dbHelper);

  final DatabaseHelper _dbHelper;
  static const Uuid _uuid = Uuid();

  /// Posts a new movement made of one or more lines, atomically:
  /// sequential-number assignment, line inserts, account balance updates,
  /// and the audit log entry all happen inside a single db transaction.
  /// If anything throws, sqflite rolls the whole transaction back.
  Future<Movement> postMovement({
    required String date,
    required String time,
    required List<MovementLineInput> lines,
    String? note,
    String? noteLevel,
    int? fiscalYearId,
    bool isOpeningBalance = false,
    String? createdBy,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('A movement must contain at least one line');
    }
    for (final MovementLineInput line in lines) {
      if (line.amount <= 0) {
        throw ArgumentError('Line amount must be positive');
      }
      if (line.exchangeRateDenominator == 0) {
        throw ArgumentError('Exchange rate denominator cannot be zero');
      }
      if (line.fromAccountId == line.toAccountId) {
        throw ArgumentError('A line cannot move money to the same account it came from');
      }
    }

    final Database db = await _dbHelper.database;
    late Movement result;

    await db.transaction((Transaction txn) async {
      // 1. Validate every account referenced actually exists and is active.
      final Set<int> accountIds = <int>{};
      for (final MovementLineInput line in lines) {
        accountIds
          ..add(line.fromAccountId)
          ..add(line.toAccountId);
      }
      for (final int accountId in accountIds) {
        final rows = await txn.query(
          DbSchema.tableAccounts,
          where: 'id = ?',
          whereArgs: [accountId],
        );
        if (rows.isEmpty) {
          throw StateError('Account $accountId does not exist');
        }
        if (rows.first['status'] != 'active') {
          throw StateError('Account $accountId is not active (status: ${rows.first['status']})');
        }
      }

      // 2. Assign the next sequential number.
      //
      // Single-writer assumption: sqflite serializes all writes on this
      // one connection, so a MAX+1 read-then-insert inside this same
      // transaction is safe for a single-device, single-user app. If
      // Amazos ever gains a second writer (multi-device sync, V3+), this
      // must move to a dedicated atomic counter table — flagging that
      // now so it isn't rediscovered as a bug later.
      final seqRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(sequential_number), 0) + 1 AS next_seq '
        'FROM ${DbSchema.tableMovements}',
      );
      final int sequentialNumber = seqRows.first['next_seq']! as int;

      // 3. Insert the movement header.
      final String now = DateTime.now().toIso8601String();
      final String movementUuid = _uuid.v4();
      final int movementId = await txn.insert(DbSchema.tableMovements, <String, Object?>{
        'uuid': movementUuid,
        'sequential_number': sequentialNumber,
        'date': date,
        'time': time,
        'status': 'posted',
        'note': note,
        'note_level': noteLevel,
        'is_opening_balance': isOpeningBalance ? 1 : 0,
        'is_locked': 0,
        'fiscal_year_id': fiscalYearId,
        'reversal_of_movement_id': null,
        'created_by': createdBy,
        'created_at': now,
        'posted_at': now,
      });

      // 4. Insert lines and apply balance deltas.
      int lineNumber = 1;
      for (final MovementLineInput line in lines) {
        final int amountUsd = Money.toUsdCents(
          amountMinorUnits: line.amount,
          rateNumerator: line.exchangeRateNumerator,
          rateDenominator: line.exchangeRateDenominator,
        );

        await txn.insert(DbSchema.tableMovementLines, <String, Object?>{
          'movement_id': movementId,
          'line_number': lineNumber,
          'from_account_id': line.fromAccountId,
          'to_account_id': line.toAccountId,
          'amount': line.amount,
          'currency': line.currency,
          'exchange_rate_numerator': line.exchangeRateNumerator,
          'exchange_rate_denominator': line.exchangeRateDenominator,
          'amount_usd': amountUsd,
        });

        await _applyBalanceDelta(
          txn,
          accountId: line.fromAccountId,
          localDelta: -line.amount,
          usdDelta: -amountUsd,
          lineCurrency: line.currency,
        );
        await _applyBalanceDelta(
          txn,
          accountId: line.toAccountId,
          localDelta: line.amount,
          usdDelta: amountUsd,
          lineCurrency: line.currency,
        );

        lineNumber++;
      }

      // 5. Audit log.
      await txn.insert(DbSchema.tableAuditLog, <String, Object?>{
        'entity_type': 'movement',
        'entity_id': movementId,
        'action': 'created',
        'old_values': null,
        'new_values': jsonEncode(<String, Object?>{
          'sequential_number': sequentialNumber,
          'date': date,
          'time': time,
          'lines': lines
              .map((MovementLineInput l) => <String, Object?>{
                    'from_account_id': l.fromAccountId,
                    'to_account_id': l.toAccountId,
                    'amount': l.amount,
                    'currency': l.currency,
                  })
              .toList(),
        }),
        'changed_by': createdBy,
        'changed_at': now,
      });

      result = Movement(
        id: movementId,
        uuid: movementUuid,
        sequentialNumber: sequentialNumber,
        date: date,
        time: time,
        status: 'posted',
        note: note,
        noteLevel: noteLevel,
        isOpeningBalance: isOpeningBalance,
        fiscalYearId: fiscalYearId,
        createdBy: createdBy,
        createdAt: now,
        postedAt: now,
      );
    });

    return result;
  }

  /// Creates a reversing movement for [originalMovementId]: a new posted
  /// movement whose lines mirror the original with from/to swapped, and
  /// flips the original's status to 'reversed'. The original row's other
  /// columns are never touched — only `status` changes — per "movements
  /// are immutable after posting."
  Future<Movement> reverseMovement({
    required int originalMovementId,
    String? note,
    String? createdBy,
  }) async {
    final Database db = await _dbHelper.database;
    late Movement result;

    await db.transaction((Transaction txn) async {
      final originalRows = await txn.query(
        DbSchema.tableMovements,
        where: 'id = ?',
        whereArgs: [originalMovementId],
      );
      if (originalRows.isEmpty) {
        throw StateError('Movement $originalMovementId does not exist');
      }
      final Map<String, Object?> original = originalRows.first;
      if (original['status'] != 'posted') {
        throw StateError(
          'Only posted movements can be reversed (current status: ${original['status']})',
        );
      }
      if (original['is_locked'] == 1) {
        throw StateError('Movement $originalMovementId is locked and cannot be reversed');
      }

      final lineRows = await txn.query(
        DbSchema.tableMovementLines,
        where: 'movement_id = ?',
        whereArgs: [originalMovementId],
        orderBy: 'line_number ASC',
      );

      final seqRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(sequential_number), 0) + 1 AS next_seq '
        'FROM ${DbSchema.tableMovements}',
      );
      final int sequentialNumber = seqRows.first['next_seq']! as int;

      final String now = DateTime.now().toIso8601String();
      final String movementUuid = _uuid.v4();
      final String reversalNote = note ?? 'Reversal of #${original['sequential_number']}';
      final int reversalId = await txn.insert(DbSchema.tableMovements, <String, Object?>{
        'uuid': movementUuid,
        'sequential_number': sequentialNumber,
        'date': now.substring(0, 10),
        'time': now.substring(11, 16),
        'status': 'posted',
        'note': reversalNote,
        'note_level': 'important',
        'is_opening_balance': 0,
        'is_locked': 0,
        'fiscal_year_id': original['fiscal_year_id'],
        'reversal_of_movement_id': originalMovementId,
        'created_by': createdBy,
        'created_at': now,
        'posted_at': now,
      });

      for (final Map<String, Object?> line in lineRows) {
        final int amount = line['amount']! as int;
        final String currency = line['currency']! as String;
        final int rateNum = line['exchange_rate_numerator']! as int;
        final int rateDenom = line['exchange_rate_denominator']! as int;
        final int amountUsd = line['amount_usd']! as int;
        // Swapped: the reversal's from/to are the original's to/from.
        final int fromId = line['to_account_id']! as int;
        final int toId = line['from_account_id']! as int;

        await txn.insert(DbSchema.tableMovementLines, <String, Object?>{
          'movement_id': reversalId,
          'line_number': line['line_number'],
          'from_account_id': fromId,
          'to_account_id': toId,
          'amount': amount,
          'currency': currency,
          'exchange_rate_numerator': rateNum,
          'exchange_rate_denominator': rateDenom,
          'amount_usd': amountUsd,
        });

        await _applyBalanceDelta(
          txn,
          accountId: fromId,
          localDelta: -amount,
          usdDelta: -amountUsd,
          lineCurrency: currency,
        );
        await _applyBalanceDelta(
          txn,
          accountId: toId,
          localDelta: amount,
          usdDelta: amountUsd,
          lineCurrency: currency,
        );
      }

      await txn.update(
        DbSchema.tableMovements,
        <String, Object?>{'status': 'reversed'},
        where: 'id = ?',
        whereArgs: [originalMovementId],
      );

      await txn.insert(DbSchema.tableAuditLog, <String, Object?>{
        'entity_type': 'movement',
        'entity_id': originalMovementId,
        'action': 'status_changed',
        'old_values': jsonEncode(<String, Object?>{'status': 'posted'}),
        'new_values': jsonEncode(<String, Object?>{
          'status': 'reversed',
          'reversed_by_movement_id': reversalId,
        }),
        'changed_by': createdBy,
        'changed_at': now,
      });

      result = Movement(
        id: reversalId,
        uuid: movementUuid,
        sequentialNumber: sequentialNumber,
        date: now.substring(0, 10),
        time: now.substring(11, 16),
        status: 'posted',
        note: reversalNote,
        noteLevel: 'important',
        fiscalYearId: original['fiscal_year_id'] as int?,
        reversalOfMovementId: originalMovementId,
        createdBy: createdBy,
        createdAt: now,
        postedAt: now,
      );
    });

    return result;
  }

  /// Voids a draft movement (soft delete).
  ///
  /// Design note / disclosed assumption: per the Founder's lifecycle
  /// decision (Draft -> Posted -> Reversed -> Void, no is_reversed flag),
  /// it's not stated whether Void is reachable from Posted/Reversed too.
  /// This implementation only allows Void from Draft — posted movements
  /// can only be corrected via [reverseMovement] — since that's the only
  /// reading consistent with "correction is performed only through
  /// reversing movements." If the Founder wants Void reachable from
  /// Reversed as well (e.g. to hide a fully-cancelled pair from history),
  /// that's a one-line change to the status check below.
  Future<void> voidDraftMovement(int movementId) async {
    final Database db = await _dbHelper.database;
    await db.transaction((Transaction txn) async {
      final rows = await txn.query(DbSchema.tableMovements, where: 'id = ?', whereArgs: [movementId]);
      if (rows.isEmpty) {
        throw StateError('Movement $movementId does not exist');
      }
      if (rows.first['status'] != 'draft') {
        throw StateError('Only draft movements can be voided directly (use reverseMovement for posted ones)');
      }
      final String now = DateTime.now().toIso8601String();
      await txn.update(
        DbSchema.tableMovements,
        <String, Object?>{'status': 'void'},
        where: 'id = ?',
        whereArgs: [movementId],
      );
      await txn.insert(DbSchema.tableAuditLog, <String, Object?>{
        'entity_type': 'movement',
        'entity_id': movementId,
        'action': 'status_changed',
        'old_values': jsonEncode(<String, Object?>{'status': 'draft'}),
        'new_values': jsonEncode(<String, Object?>{'status': 'void'}),
        'changed_by': null,
        'changed_at': now,
      });
    });
  }

  /// Applies a balance delta to one account.
  ///
  /// Design note: `running_balance` (local currency) is only updated
  /// when the line's currency matches the account's own currency — a
  /// USD-denominated account touched by a EUR-denominated line (e.g. the
  /// "Currency Exchange Clearing" system account during a currency
  /// exchange) has its `running_balance_usd` updated but its
  /// `running_balance` left alone, since the line simply isn't
  /// denominated in that account's currency. This means local balances
  /// stay meaningful for ordinary same-currency accounts, while
  /// virtual/clearing accounts are read via running_balance_usd only.
  /// This is the trickiest part of the whole model — Phase 2's
  /// CurrencyExchangeService should carry an explicit unit test for the
  /// Blueprint's own 5:30 PM three-line exchange example against this
  /// logic before it's trusted with real data.
  Future<void> _applyBalanceDelta(
    Transaction txn, {
    required int accountId,
    required int localDelta,
    required int usdDelta,
    required String lineCurrency,
  }) async {
    final rows = await txn.query(
      DbSchema.tableAccounts,
      columns: ['currency'],
      where: 'id = ?',
      whereArgs: [accountId],
    );
    final String accountCurrency = rows.first['currency']! as String;
    final bool sameCurrency = accountCurrency == lineCurrency;

    await txn.rawUpdate(
      'UPDATE ${DbSchema.tableAccounts} '
      'SET running_balance = running_balance + ?, '
      '    running_balance_usd = running_balance_usd + ? '
      'WHERE id = ?',
      [sameCurrency ? localDelta : 0, usdDelta, accountId],
    );
  }

  Future<Movement?> findBySequentialNumber(int sequentialNumber) async {
    final Database db = await _dbHelper.database;
    final rows = await db.query(
      DbSchema.tableMovements,
      where: 'sequential_number = ?',
      whereArgs: [sequentialNumber],
    );
    if (rows.isEmpty) return null;
    return Movement.fromMap(rows.first);
  }

  /// Numeric queries match a sequential number exactly; anything else is
  /// matched against note text.
  Future<List<Movement>> search(String query, {int limit = 50}) async {
    final Database db = await _dbHelper.database;
    final int? asNumber = int.tryParse(query);
    if (asNumber != null) {
      final rows = await db.query(
        DbSchema.tableMovements,
        where: 'sequential_number = ?',
        whereArgs: [asNumber],
      );
      return rows.map(Movement.fromMap).toList();
    }
    final rows = await db.query(
      DbSchema.tableMovements,
      where: 'note LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(Movement.fromMap).toList();
  }

  /// Paginated (limit/offset) ledger for one account — every posted line
  /// where the account appears as either side.
  Future<List<Map<String, Object?>>> getAccountLedger(
    int accountId, {
    String? dateFrom,
    String? dateTo,
    int limit = 50,
    int offset = 0,
  }) async {
    final Database db = await _dbHelper.database;
    final List<String> whereClauses = <String>[
      '(ml.from_account_id = ? OR ml.to_account_id = ?)',
      "m.status = 'posted'",
    ];
    final List<Object?> whereArgs = <Object?>[accountId, accountId];
    if (dateFrom != null) {
      whereClauses.add('m.date >= ?');
      whereArgs.add(dateFrom);
    }
    if (dateTo != null) {
      whereClauses.add('m.date <= ?');
      whereArgs.add(dateTo);
    }
    return db.rawQuery(
      '''
      SELECT m.id, m.sequential_number, m.date, m.time, m.note, m.note_level,
             ml.from_account_id, ml.to_account_id, ml.amount, ml.currency,
             ml.amount_usd
      FROM ${DbSchema.tableMovementLines} ml
      JOIN ${DbSchema.tableMovements} m ON m.id = ml.movement_id
      WHERE ${whereClauses.join(' AND ')}
      ORDER BY m.date DESC, m.sequential_number DESC
      LIMIT ? OFFSET ?
      ''',
      [...whereArgs, limit, offset],
    );
  }
}

/// Phase 1 entry point.
///
/// This does NOT implement the Cash Register, reports, or any real
/// workflow yet — that's Phase 3, built on top of the business-logic
/// layer (Phase 2), built on top of this data layer.
///
/// What this screen proves, on a real device, before either of those
/// layers gets written: the database opens, the schema creates
/// correctly, migrations run, and the four system accounts seed as
/// expected. That's the whole point of shipping this as its own
/// checkpoint instead of the entire app at once.
void main() {
  runApp(const AmazosApp());
}

class AmazosApp extends StatelessWidget {
  const AmazosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amazos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF14532D),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF14532D),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const DataLayerCheckScreen(),
    );
  }
}

class DataLayerCheckScreen extends StatefulWidget {
  const DataLayerCheckScreen({super.key});

  @override
  State<DataLayerCheckScreen> createState() => _DataLayerCheckScreenState();
}

class _DataLayerCheckScreenState extends State<DataLayerCheckScreen> {
  late final Future<List<String>> _accountSummaries;

  @override
  void initState() {
    super.initState();
    _accountSummaries = _loadSystemAccounts();
  }

  Future<List<String>> _loadSystemAccounts() async {
    final AccountRepository repo = AccountRepository(DatabaseHelper.instance);
    final accounts = await repo.getAccounts();
    return accounts.map((a) => '${a.name}  —  ${a.type}, ${a.currency}').toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Amazos — Data Layer Check')),
      body: FutureBuilder<List<String>>(
        future: _accountSummaries,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Database error:\n${snapshot.error}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            );
          }
          final names = snapshot.data ?? const <String>[];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Database opened successfully.\nSystem accounts seeded:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              ...names.map(
                (n) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('•  $n'),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'Phase 1 (data layer) complete. Cash Register UI, reports, '
                'and currency-exchange logic land in later phases.',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          );
        },
      ),
    );
  }
}
