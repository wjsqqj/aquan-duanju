import 'reader_click_action.dart';
import 'reader_theme.dart';

/// 阅读模式：连续滚动 / 整页翻页。
enum ReaderMode {
  scroll('滚动'),
  paged('翻页');

  const ReaderMode(this.label);

  final String label;

  static ReaderMode fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ReaderMode.scroll;
  }
}

/// 翻页动画：对齐 legado 的 6 个常用项。
enum ReaderPageAnim {
  none('无'),
  slide('滑动'),
  cover('覆盖'),
  fade('淡入'),
  upDown('上下'),
  curl('仿真');

  const ReaderPageAnim(this.label);

  final String label;

  static ReaderPageAnim fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ReaderPageAnim.slide;
  }
}

/// 简繁转换。
enum ChineseConvert {
  off('不转换'),
  t2s('繁 → 简'),
  s2t('简 → 繁');

  const ChineseConvert(this.label);

  final String label;

  static ChineseConvert fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ChineseConvert.off;
  }
}

/// 阅读器全量设置。整体作为一个 JSON 落在 `aquan_reader_settings.json`，
/// 与旧版散落在 SharedPreferences 的 `reader.*` 分键存储互不影响。
class ReaderSettings {
  const ReaderSettings({
    this.schema = currentSchema,
    this.themes = const <ReaderThemeConfig>[],
    this.activeTheme = 0,
    this.clickActions = kDefaultClickActions,
    this.zoneLayout = const ClickZoneLayout(),
    this.swipeEnabled = true,
    this.mode = ReaderMode.scroll,
    this.anim = ReaderPageAnim.slide,
    this.animSpeed = 2,
    this.autoTurn = false,
    this.autoIntervalSec = 60,
    this.volumeKeyPage = false,
    this.orientation = 0,
    this.hideStatusBar = false,
    this.keepAwake = false,
    this.convert = ChineseConvert.off,
    this.nightMode = false,
    this.brightness = -1,
    this.hapticOnTurn = true,
    this.soundOnTurn = false,
    this.doublePage = false,
  });

  static const int currentSchema = 2;

  /// 动画速度挡位（毫秒）。
  static const List<int> animDurationsMs = <int>[200, 280, 360, 480];

  final int schema;

  /// 多套排版主题；为空时使用 [defaultReaderThemes]。
  final List<ReaderThemeConfig> themes;
  final int activeTheme;

  /// 九宫格动作，恒 9 项。
  final List<ReaderClickAction> clickActions;

  final ClickZoneLayout zoneLayout;
  final bool swipeEnabled;

  final ReaderMode mode;
  final ReaderPageAnim anim;
  final int animSpeed;
  final bool autoTurn;
  final int autoIntervalSec;

  /// 音量键翻页（桌面端默认关闭，避免与系统音量冲突）。
  final bool volumeKeyPage;

  /// 0 跟随系统 / 1 竖屏 / 2 横屏。
  final int orientation;

  final bool hideStatusBar;
  final bool keepAwake;
  final ChineseConvert convert;

  /// 阅读页是否走夜间配色；主题里日间/夜间各有一套色。
  final bool nightMode;

  /// 0..1；-1 表示跟随系统亮度。
  final double brightness;

  /// 翻页时给一次轻触反馈。
  final bool hapticOnTurn;

  /// 翻页时播放系统点击音（默认关，避免安静环境打扰）。
  final bool soundOnTurn;

  /// 横屏/平板双页并排（宽度不足 600 时自动退回单页）。
  final bool doublePage;

  List<ReaderThemeConfig> get effectiveThemes =>
      themes.isEmpty ? defaultReaderThemes() : themes;

  ReaderThemeConfig get activeThemeConfig {
    final list = effectiveThemes;
    return list[activeTheme.clamp(0, list.length - 1)];
  }

  int get animDurationMs =>
      animDurationsMs[animSpeed.clamp(0, animDurationsMs.length - 1)];

  ReaderClickAction actionAt(int slot) {
    if (slot < 0 || slot >= clickActions.length) return ReaderClickAction.none;
    return clickActions[slot];
  }

  ReaderSettings copyWith({
    List<ReaderThemeConfig>? themes,
    int? activeTheme,
    List<ReaderClickAction>? clickActions,
    ClickZoneLayout? zoneLayout,
    bool? swipeEnabled,
    ReaderMode? mode,
    ReaderPageAnim? anim,
    int? animSpeed,
    bool? autoTurn,
    int? autoIntervalSec,
    bool? volumeKeyPage,
    int? orientation,
    bool? hideStatusBar,
    bool? keepAwake,
    ChineseConvert? convert,
    bool? nightMode,
    double? brightness,
    bool? hapticOnTurn,
    bool? soundOnTurn,
    bool? doublePage,
  }) =>
      ReaderSettings(
        themes: themes ?? this.themes,
        activeTheme: activeTheme ?? this.activeTheme,
        clickActions: clickActions ?? this.clickActions,
        zoneLayout: zoneLayout ?? this.zoneLayout,
        swipeEnabled: swipeEnabled ?? this.swipeEnabled,
        mode: mode ?? this.mode,
        anim: anim ?? this.anim,
        animSpeed: (animSpeed ?? this.animSpeed).clamp(0, animDurationsMs.length - 1),
        autoTurn: autoTurn ?? this.autoTurn,
        autoIntervalSec:
            (autoIntervalSec ?? this.autoIntervalSec).clamp(15, 300),
        volumeKeyPage: volumeKeyPage ?? this.volumeKeyPage,
        orientation: (orientation ?? this.orientation).clamp(0, 2),
        hideStatusBar: hideStatusBar ?? this.hideStatusBar,
        keepAwake: keepAwake ?? this.keepAwake,
        convert: convert ?? this.convert,
        nightMode: nightMode ?? this.nightMode,
        brightness: (brightness ?? this.brightness).clamp(-1.0, 1.0),
        hapticOnTurn: hapticOnTurn ?? this.hapticOnTurn,
        soundOnTurn: soundOnTurn ?? this.soundOnTurn,
        doublePage: doublePage ?? this.doublePage,
        );

  /// 替换当前主题。索引越界时退化为「追加」。
  ReaderSettings withActiveTheme(ReaderThemeConfig theme) {
    final list = List<ReaderThemeConfig>.of(effectiveThemes);
    final index = activeTheme.clamp(0, list.length - 1);
    list[index] = theme;
    return copyWith(themes: list, activeTheme: index);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema': currentSchema,
        'themes': [for (final theme in effectiveThemes) theme.toJson()],
        'active_theme': activeTheme,
        'click_actions': [
          for (final action in _normalizedActions(clickActions)) action.legadoId
        ],
        'zone_layout': zoneLayout.toJson(),
        'swipe_enabled': swipeEnabled,
        'mode': mode.name,
        'anim': anim.name,
        'anim_speed': animSpeed,
        'auto_turn': autoTurn,
        'auto_interval_sec': autoIntervalSec,
        'volume_key_page': volumeKeyPage,
        'orientation': orientation,
        'hide_status_bar': hideStatusBar,
        'keep_awake': keepAwake,
        'convert': convert.name,
        'night_mode': nightMode,
        'brightness': brightness,
        'haptic_on_turn': hapticOnTurn,
        'sound_on_turn': soundOnTurn,
        'double_page': doublePage,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ReaderSettings();
    const base = ReaderSettings();

    final rawThemes = json['themes'];
    final themes = <ReaderThemeConfig>[];
    if (rawThemes is List) {
      for (final item in rawThemes) {
        if (item is Map<String, dynamic>) {
          themes.add(ReaderThemeConfig.fromJson(item));
        } else if (item is Map) {
          themes.add(ReaderThemeConfig.fromJson(
              item.map((k, v) => MapEntry('$k', v))));
        }
      }
    }

    final rawActions = json['click_actions'];
    final actions = <ReaderClickAction>[];
    if (rawActions is List) {
      for (final item in rawActions) {
        actions.add(ReaderClickAction.fromId(item));
      }
    }

    final rawZone = json['zone_layout'];
    double num0(Object? v, double fallback) =>
        v is num && v.isFinite ? v.toDouble() : fallback;

    return ReaderSettings(
      themes: themes,
      activeTheme: (json['active_theme'] is num
              ? (json['active_theme'] as num).toInt()
              : base.activeTheme)
          .clamp(0, themes.isEmpty ? 0 : themes.length - 1),
      clickActions: _normalizedActions(actions),
      zoneLayout: ClickZoneLayout.fromJson(
          rawZone is Map ? rawZone.map((k, v) => MapEntry('$k', v)) : null),
      swipeEnabled:
          json['swipe_enabled'] is bool ? json['swipe_enabled'] as bool : true,
      mode: ReaderMode.fromName(json['mode']),
      anim: ReaderPageAnim.fromName(json['anim']),
      animSpeed: (json['anim_speed'] is num
              ? (json['anim_speed'] as num).toInt()
              : base.animSpeed)
          .clamp(0, animDurationsMs.length - 1),
      autoTurn: json['auto_turn'] is bool ? json['auto_turn'] as bool : false,
      autoIntervalSec: (json['auto_interval_sec'] is num
              ? (json['auto_interval_sec'] as num).toInt()
              : base.autoIntervalSec)
          .clamp(15, 300),
      volumeKeyPage: json['volume_key_page'] is bool
          ? json['volume_key_page'] as bool
          : false,
      orientation:
          (json['orientation'] is num ? (json['orientation'] as num).toInt() : 0)
              .clamp(0, 2),
      hideStatusBar: json['hide_status_bar'] is bool
          ? json['hide_status_bar'] as bool
          : false,
      keepAwake: json['keep_awake'] is bool ? json['keep_awake'] as bool : false,
      convert: ChineseConvert.fromName(json['convert']),
      nightMode:
          json['night_mode'] is bool ? json['night_mode'] as bool : false,
      brightness: num0(json['brightness'], -1).clamp(-1.0, 1.0),
      hapticOnTurn: json['haptic_on_turn'] is bool
          ? json['haptic_on_turn'] as bool
          : true,
      soundOnTurn: json['sound_on_turn'] is bool
          ? json['sound_on_turn'] as bool
          : false,
      doublePage:
          json['double_page'] is bool ? json['double_page'] as bool : false,
    );
  }

  /// 长度补齐到 9 项：短了补默认动作，长了截断，杜绝越界点击。
  static List<ReaderClickAction> _normalizedActions(
      List<ReaderClickAction> raw) {
    if (raw.length == kDefaultClickActions.length) {
      return List<ReaderClickAction>.unmodifiable(raw);
    }
    final out = <ReaderClickAction>[];
    for (var i = 0; i < kDefaultClickActions.length; i++) {
      out.add(i < raw.length ? raw[i] : kDefaultClickActions[i]);
    }
    return List<ReaderClickAction>.unmodifiable(out);
  }
}
