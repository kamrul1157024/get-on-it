import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import 'database.dart';

const _uuid = Uuid();

/// What changes when a goal is imported again with the same id. Spec §14.3.
class GoalDiff {
  const GoalDiff({this.isNew = true, this.added = const [], this.removed = const [], this.renamed = const []});

  final bool isNew;
  final List<String> added;
  final List<String> removed;
  final List<String> renamed;

  bool get hasChanges => added.isNotEmpty || removed.isNotEmpty || renamed.isNotEmpty;

  String describe() {
    if (isNew) return 'New goal';
    final parts = [
      if (added.isNotEmpty) '${added.length} added',
      if (removed.isNotEmpty) '${removed.length} removed',
      if (renamed.isNotEmpty) '${renamed.length} renamed',
    ];
    return parts.isEmpty ? 'No changes to items. Your progress stays.' : '${parts.join(', ')}. Your progress stays.';
  }
}

/// Compares the `items` or `steps` arrays of two goal versions by id.
GoalDiff diffGoals(GoalDoc? before, GoalDoc after) {
  if (before == null) return const GoalDiff();
  Map<String, String> index(GoalDoc g) {
    final list = (g.data['items'] ?? g.data['steps']) as List? ?? const [];
    return {
      for (final i in list)
        if (i is Map && i['id'] is String) i['id'] as String: (i['title'] as String?) ?? '',
    };
  }

  final a = index(before), b = index(after);
  return GoalDiff(
    isNew: false,
    added: [
      for (final k in b.keys)
        if (!a.containsKey(k)) b[k]!,
    ],
    removed: [
      for (final k in a.keys)
        if (!b.containsKey(k)) a[k]!,
    ],
    renamed: [
      for (final k in b.keys)
        if (a.containsKey(k) && a[k] != b[k]) b[k]!,
    ],
  );
}

class StoredGoal {
  const StoredGoal(this.doc, this.createdAt, this.status);

  final GoalDoc doc;
  final DateTime createdAt;
  final String status;
}

class Repository {
  Repository(this.db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final DateTime Function() _clock;

  // Templates ---------------------------------------------------------------

  Map<String, TemplateDoc> _templateMap(List<Template> rows) => {
    for (final r in rows) '${r.id}@${r.major}': TemplateDoc((jsonDecode(r.json) as Map).cast()),
  };

  Stream<Map<String, TemplateDoc>> watchTemplates() => db.select(db.templates).watch().map(_templateMap);

  Future<Map<String, TemplateDoc>> templates() async => _templateMap(await db.select(db.templates).get());

  /// Installs a template unless a newer version of the same major exists.
  Future<bool> installTemplate(TemplateDoc t, {String source = 'imported'}) async {
    final existing = await (db.select(
      db.templates,
    )..where((r) => r.id.equals(t.id) & r.major.equals(t.major))).getSingleOrNull();
    if (existing != null) {
      final old = TemplateDoc((jsonDecode(existing.json) as Map).cast());
      if (old.compareVersion(t) > 0) return false;
      if (old.compareVersion(t) == 0 && existing.json == t.encode()) return false;
    }
    await db
        .into(db.templates)
        .insertOnConflictUpdate(
          TemplatesCompanion.insert(
            id: t.id,
            major: t.major,
            version: t.version,
            json: t.encode(),
            source: source,
            installedAt: _clock(),
          ),
        );
    return true;
  }

  /// Puts back an exact template version, also an older one: for Undo.
  Future<void> restoreTemplate(TemplateDoc t) => db
      .into(db.templates)
      .insertOnConflictUpdate(
        TemplatesCompanion.insert(
          id: t.id,
          major: t.major,
          version: t.version,
          json: t.encode(),
          source: 'imported',
          installedAt: _clock(),
        ),
      );

  Future<void> deleteTemplate(String id, int major) =>
      (db.delete(db.templates)..where((r) => r.id.equals(id) & r.major.equals(major))).go();

  // Goals -------------------------------------------------------------------

  Stream<List<StoredGoal>> watchGoals() =>
      (db.select(db.goals)
            ..where((g) => g.status.equals('active'))
            ..orderBy([(g) => OrderingTerm(expression: g.position), (g) => OrderingTerm(expression: g.createdAt)]))
          .watch()
          .map((rows) => [for (final r in rows) _stored(r)]);

  /// Active goals now, as a plain query (no stream).
  Future<List<StoredGoal>> activeGoals() async => [
    for (final r
        in await (db.select(db.goals)
              ..where((g) => g.status.equals('active'))
              ..orderBy([(g) => OrderingTerm(expression: g.position), (g) => OrderingTerm(expression: g.createdAt)]))
            .get())
      _stored(r),
  ];

  StoredGoal _stored(Goal r) => StoredGoal(GoalDoc((jsonDecode(r.json) as Map).cast()), r.createdAt, r.status);

  Future<StoredGoal?> goal(String id) async {
    final r = await (db.select(db.goals)..where((g) => g.id.equals(id))).getSingleOrNull();
    return r == null ? null : _stored(r);
  }

  /// Saves a goal. A goal with an existing id replaces the old version; its
  /// events stay, so progress stays.
  Future<void> saveGoal(GoalDoc goal) async {
    final now = _clock();
    final existing = await (db.select(db.goals)..where((g) => g.id.equals(goal.id))).getSingleOrNull();
    if (existing == null) {
      final count = await db.goals.count().getSingle();
      await db
          .into(db.goals)
          .insert(
            GoalsCompanion.insert(
              id: goal.id,
              templateId: goal.templateId,
              templateMajor: goal.templateMajor,
              json: goal.encode(),
              position: Value(count),
              createdAt: now,
              updatedAt: now,
            ),
          );
    } else {
      await (db.update(db.goals)..where((g) => g.id.equals(goal.id))).write(
        GoalsCompanion(
          templateId: Value(goal.templateId),
          templateMajor: Value(goal.templateMajor),
          json: Value(goal.encode()),
          status: const Value('active'),
          updatedAt: Value(now),
        ),
      );
    }
  }

  /// Settings that belong to one goal: `<prefix><goalId>`.
  static const goalSettingPrefixes = ['reminders.on.', 'reminders.asked.'];

  Future<void> deleteGoal(String id) => db.transaction(() async {
    await (db.delete(db.goals)..where((g) => g.id.equals(id))).go();
    await (db.delete(db.events)..where((e) => e.goalId.equals(id))).go();
    await (db.delete(db.linkedFiles)..where((f) => f.goalId.equals(id))).go();
    // Re-importing a goal with this id must not turn its reminders back on.
    for (final prefix in goalSettingPrefixes) {
      await (db.delete(db.settings)..where((s) => s.key.equals('$prefix$id'))).go();
    }
  });

  // Events ------------------------------------------------------------------

  Stream<List<GoalEvent>> watchEvents(String goalId) =>
      (db.select(db.events)..where((e) => e.goalId.equals(goalId))).watch().map(
        (rows) => [
          for (final r in rows)
            GoalEvent(
              id: r.id,
              goalId: r.goalId,
              type: r.type,
              payload: (jsonDecode(r.payload) as Map).cast(),
              utcMs: r.utcMs,
              offsetMinutes: r.offsetMinutes,
              device: r.device,
            ),
        ]..sort(GoalEvent.compare),
      );

  Future<GoalEvent> addEvent(String goalId, String type, Map<String, Object?> payload, {DateTime? at}) async {
    final t = at ?? _clock();
    final e = GoalEvent(
      id: _uuid.v4(),
      goalId: goalId,
      type: type,
      payload: payload,
      utcMs: t.toUtc().millisecondsSinceEpoch,
      offsetMinutes: t.timeZoneOffset.inMinutes,
    );
    await db
        .into(db.events)
        .insert(
          EventsCompanion.insert(
            id: e.id,
            goalId: goalId,
            type: type,
            payload: e.payloadJson,
            utcMs: e.utcMs,
            offsetMinutes: e.offsetMinutes,
            device: e.device,
          ),
        );
    return e;
  }

  Future<List<GoalEvent>> allEvents() async => [
    for (final r in await db.select(db.events).get())
      GoalEvent(
        id: r.id,
        goalId: r.goalId,
        type: r.type,
        payload: (jsonDecode(r.payload) as Map).cast(),
        utcMs: r.utcMs,
        offsetMinutes: r.offsetMinutes,
        device: r.device,
      ),
  ]..sort(GoalEvent.compare);

  /// Adds events from a backup. Events already present (same id) are kept.
  Future<int> insertEvents(Iterable<GoalEvent> events) => db.transaction(() async {
    final existing = {for (final r in await db.select(db.events).get()) r.id};
    var added = 0;
    for (final e in events) {
      if (!existing.add(e.id)) continue;
      await db
          .into(db.events)
          .insert(
            EventsCompanion.insert(
              id: e.id,
              goalId: e.goalId,
              type: e.type,
              payload: e.payloadJson,
              utcMs: e.utcMs,
              offsetMinutes: e.offsetMinutes,
              device: e.device,
            ),
          );
      added++;
    }
    return added;
  });

  Future<List<GoalDoc>> allGoals() async => [
    for (final r in await db.select(db.goals).get()) GoalDoc((jsonDecode(r.json) as Map).cast()),
  ];

  Future<List<TemplateDoc>> importedTemplates() async => [
    for (final r in await (db.select(db.templates)..where((t) => t.source.equals('imported'))).get())
      TemplateDoc((jsonDecode(r.json) as Map).cast()),
  ];

  Future<Map<String, String>> settings() async => {for (final r in await db.select(db.settings).get()) r.key: r.value};

  /// Fires after a goal, event or template changes, so a backup can follow.
  /// Settings are left out: a backup writes its own time there.
  Stream<void> get changes =>
      db.tableUpdates(TableUpdateQuery.onAllTables([db.goals, db.events, db.templates])).map((_) {});

  // Files -------------------------------------------------------------------

  Stream<Map<String, String>> watchLinkedFiles(String goalId) => (db.select(
    db.linkedFiles,
  )..where((f) => f.goalId.equals(goalId))).watch().map((rows) => {for (final r in rows) r.documentId: r.ref});

  Future<Map<String, String>> linkedFiles(String goalId) async => {
    for (final r in await (db.select(db.linkedFiles)..where((f) => f.goalId.equals(goalId))).get()) r.documentId: r.ref,
  };

  Future<void> linkFile(String goalId, String documentId, String kind, String ref) => db
      .into(db.linkedFiles)
      .insertOnConflictUpdate(
        LinkedFilesCompanion.insert(goalId: goalId, documentId: documentId, kind: kind, ref: ref),
      );

  // Settings ----------------------------------------------------------------

  Stream<Map<String, String>> watchSettings() =>
      db.select(db.settings).watch().map((rows) => {for (final r in rows) r.key: r.value});

  Future<void> setSetting(String key, String value) =>
      db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
}
