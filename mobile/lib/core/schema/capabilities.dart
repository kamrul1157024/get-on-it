/// What this build of the app supports. The skill reads this to generate
/// documents the app can render. Spec §6.7.
abstract final class Capabilities {
  static const schemaVersions = ['1.0'];

  static const components = {
    // layout
    'column', 'row', 'card', 'grid', 'list', 'section', 'divider', 'spacer',
    // display
    'text', 'icon', 'image', 'badge', 'stat', 'progress_bar', 'progress_ring',
    'week_dots', 'heatmap', 'media',
    // input
    'button', 'checklist_item', 'counter', 'number_input',
    // composition
    'embed',
  };

  static const actions = {
    'open_goal',
    'open_video',
    'open_external',
    'open_pdf_page',
    'link_file',
    'mark_done',
    'toggle_done',
    'log_progress',
    'notify',
  };

  static const engines = {'video_series', 'page_range', 'count', 'check', 'checklist', 'by_mode'};

  static const surfaces = {'screen', 'tile', 'tile_wide'};

  static Map<String, Object?> manifest(String appVersion) => {
    'app': 'get-on-it',
    'appVersion': appVersion,
    'schemaVersions': schemaVersions,
    'components': components.toList()..sort(),
    'actions': actions.toList()..sort(),
    'engines': engines.toList()..sort(),
    'surfaces': surfaces.toList()..sort(),
  };
}
