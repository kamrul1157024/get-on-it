import '../core/schema/documents.dart';
import 'engine.dart';
import 'habits.dart';
import 'page_range.dart';
import 'video_series.dart';

class EngineRegistry {
  const EngineRegistry();

  static const Map<String, ProgressEngine> _engines = {
    'video_series': VideoSeriesEngine(),
    'page_range': PageRangeEngine(),
    'count': CountEngine(),
    'check': CheckEngine(),
    'checklist': ChecklistEngine(),
  };

  /// The engine for a goal. A template with engine `by_mode` lets the goal
  /// choose with `data.mode` (the habit template uses this).
  ProgressEngine? forGoal(TemplateDoc template, GoalDoc goal) {
    final id = template.engine == 'by_mode' ? goal.data['mode'] as String? : template.engine;
    return _engines[id];
  }
}
