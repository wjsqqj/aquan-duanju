/// 听书高亮的显示设置：粒度 / 样式 / 颜色。
///
/// 键与默认值的风格对齐 `frontend/reader-paging-contract.md` §9.4（`listen.*` 命名、
/// 缺键按默认值、枚举按 `name` 存字符串、脏值容错回默认）：
///
/// | 键 | 类型 | 默认 | 含义 |
/// |---|---|---|---|
/// | `listen.granularity` | String | `word` | 高亮粒度（词 / 句） |
/// | `listen.highlightStyle` | String | `highlight` | 当前词的画法（5 档） |
/// | `listen.highlightColor` | int | `0` | 高亮色，`0` = 跟随主题两套黄 |
///
/// 刻意**不**放进 `lib/store/stores.dart`：那个文件由投屏工作流同时在改，本任务只读
/// 引用它的既有类。这里用一个薄封装直接落在 SharedPreferences 上，读取是同步的
/// （首帧之后 prefs 实例已缓存），渲染层每帧现取即可，不需要额外的通知链路。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 高亮粒度（用户偏好两档；实际精度还要和朗读时间表的精度取交集）。
enum SpeechHighlightGranularity {
  word('词'),
  sentence('句');

  const SpeechHighlightGranularity(this.label);

  final String label;

  static SpeechHighlightGranularity parse(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return SpeechHighlightGranularity.word;
  }
}

/// 当前词/当前句的画法。[squiggly] 在 Flutter 里**没有** wavy 装饰
/// （`TextDecorationStyle` 只有 solid/double/dotted/dashed），用最接近的
/// `dotted` 近似，渲染层注释里也写明了这一点。
enum SpeechHighlightStyle {
  highlight('底色'),
  underline('下划线'),
  strikethrough('删除线'),
  squiggly('波浪线'),
  outline('描边');

  const SpeechHighlightStyle(this.label);

  final String label;

  static SpeechHighlightStyle parse(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return SpeechHighlightStyle.highlight;
  }

  /// 按 [index] 还原（越界回默认），供只存了下标的调用方使用。
  static SpeechHighlightStyle fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : highlight;
}

/// 未配置颜色时的哨兵值：跟随主题的日/夜两套黄。
const int kSpeechColorFollowTheme = 0;

/// 日间实心色（沿用改造前 `speechHighlightColor` 的取值，保证观感不变）。
const int kSpeechSolidDay = 0xFFFFF0A8;

/// 夜间实心色（半透明黄，叠在深色底上）。
const int kSpeechSolidNight = 0x40FFD54F;

/// 句底纹的 alpha（0x33 ≈ 0.2 不透明度，design.md §4）。
const int kSpeechShadeAlpha = 0x33;

/// 实心（当前词/当前句）用的 ARGB：配置色优先，[kSpeechColorFollowTheme] 用两套黄。
int speechSolidArgb(int configuredArgb, bool night) {
  if (configuredArgb == kSpeechColorFollowTheme) {
    return night ? kSpeechSolidNight : kSpeechSolidDay;
  }
  // 全透明色画出来等于没画：补成不透明，用户配的颜色至少看得见。
  final alpha = (configuredArgb >> 24) & 0xFF;
  return alpha == 0
      ? 0xFF000000 | (configuredArgb & 0x00FFFFFF)
      : configuredArgb;
}

/// 底纹（句子/段落背景）用的 ARGB：同一 RGB 配 [kSpeechShadeAlpha]。
int speechShadeArgb(int configuredArgb, bool night) =>
    (speechSolidArgb(configuredArgb, night) & 0x00FFFFFF) |
    (kSpeechShadeAlpha << 24);

/// 三个键的同步读包装。用法：`final s = ReaderSpeechSettings(prefs); s.style;`
class ReaderSpeechSettings {
  const ReaderSpeechSettings(this._prefs);

  static const String granularityKey = 'listen.granularity';
  static const String highlightStyleKey = 'listen.highlightStyle';
  static const String highlightColorKey = 'listen.highlightColor';

  final SharedPreferences _prefs;

  SpeechHighlightGranularity get granularity =>
      SpeechHighlightGranularity.parse(_prefs.getString(granularityKey));

  SpeechHighlightStyle get style =>
      SpeechHighlightStyle.parse(_prefs.getString(highlightStyleKey));

  /// 用户配置的高亮色；[kSpeechColorFollowTheme] 表示跟随主题两套黄。
  int get colorArgb =>
      _prefs.getInt(highlightColorKey) ?? kSpeechColorFollowTheme;

  Future<void> setGranularity(SpeechHighlightGranularity value) =>
      _prefs.setString(granularityKey, value.name);

  Future<void> setStyle(SpeechHighlightStyle value) =>
      _prefs.setString(highlightStyleKey, value.name);

  /// 传 [kSpeechColorFollowTheme] 即「跟随主题」：直接删键，备份里不留死值。
  Future<void> setColorArgb(int argb) async {
    if (argb == kSpeechColorFollowTheme) {
      await _prefs.remove(highlightColorKey);
    } else {
      await _prefs.setInt(highlightColorKey, argb);
    }
  }
}
