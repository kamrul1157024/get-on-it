import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Installed templates. One row per template id and major version; the row
/// holds the newest minor/patch version of that major.
class Templates extends Table {
  TextColumn get id => text()();
  IntColumn get major => integer()();
  TextColumn get version => text()();
  TextColumn get json => text()();
  TextColumn get source => text()(); // builtin | imported
  DateTimeColumn get installedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id, major};
}

class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get templateId => text()();
  IntColumn get templateMajor => integer()();
  TextColumn get json => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The event log. Rows are never updated; a correction is a new event.
@TableIndex(name: 'events_by_goal', columns: {#goalId, #utcMs})
class Events extends Table {
  TextColumn get id => text()();
  TextColumn get goalId => text()();
  TextColumn get type => text()();
  TextColumn get payload => text()();
  IntColumn get utcMs => integer()();
  IntColumn get offsetMinutes => integer()();
  TextColumn get device => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class LinkedFiles extends Table {
  TextColumn get goalId => text()();
  TextColumn get documentId => text()();
  TextColumn get kind => text()(); // local_path | drive_id | url
  TextColumn get ref => text()();

  @override
  Set<Column> get primaryKey => {goalId, documentId};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Templates, Goals, Events, LinkedFiles, Settings])
class AppDatabase extends _$AppDatabase {
  // Shared across isolates, so a widget button handled in the background
  // isolate updates the app's screens too.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'getonit', native: const DriftNativeOptions(shareAcrossIsolates: true)));

  @override
  int get schemaVersion => 1;
}
