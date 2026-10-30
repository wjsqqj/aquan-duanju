/// 「我的 → 设置 → 听书」里 **合成侧**那四个键的读写入口（design.md §7）。
///
/// 为什么直接落 SharedPreferences 而不是加进 `SettingsStore`：
/// - `lib/store/stores.dart` 正被投屏工作流同时编辑，本任务只**读**它已有的类；
/// - 备份导出走 `stores.dart` 里 `SettingsStore.exportBackup()` 那份**写死的字面量
///   名单**，不在名单里的键天然不出门。`listen.tts.proxy`（代理地址，可能带凭据）与
///   `voice.apiKey` 因此是同一套处理：写 prefs、不进备份 —— 不需要额外的排除列表，
///   也就不会漏。
///
/// 键的**字面值只有一处定义**：这里全部转引 [ReaderSpeechController] 已有常量。
/// 显示侧的三键（粒度 / 样式 / 颜色）不在这个类里 —— 它们已由
/// `ReaderSpeechSettings` 负责读写，渲染层读的就是那个类，设置页照同一入口写，
/// 免得长出第二套真值。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'reader_speech_controller.dart';

/// `listen.tts.engine` 的默认值：当前只有 Edge 一个实现。
const String kDefaultTtsEngineId = 'edge';

/// 高亮色候选：`0`（`kSpeechColorFollowTheme`）= 跟随主题的日/夜两套黄。
const Map<int, String> kSpeechColorPresets = <int, String>{
  0: '跟随主题',
  0xFFF7C948: '琥珀',
  0xFF9CCC65: '浅绿',
  0xFF64B5F6: '浅蓝',
  0xFFF28B82: '浅粉',
};

/// 合成设置的薄封装：读取同步（prefs 实例已缓存），写入异步。
class ReaderListenSettings {
  const ReaderListenSettings(this._prefs);

  static const String ttsEnabledKey = ReaderSpeechController.ttsEnabledKey;
  static const String ttsVoiceKey = ReaderSpeechController.ttsVoiceKey;
  static const String ttsProxyKey = ReaderSpeechController.ttsProxyKey;
  static const String ttsEngineKey = ReaderSpeechController.ttsEngineKey;

  final SharedPreferences _prefs;

  /// 缺键按「开」：只有显式关掉才回到「仅平台音轨」（design.md §8 的回滚开关）。
  bool get ttsEnabled => _prefs.getBool(ttsEnabledKey) ?? true;
  Future<void> setTtsEnabled(bool value) => _prefs.setBool(ttsEnabledKey, value);

  String get ttsEngineId => _prefs.getString(ttsEngineKey) ?? kDefaultTtsEngineId;
  Future<void> setTtsEngineId(String value) =>
      _prefs.setString(ttsEngineKey, value);

  /// 已存的音色 id；空串 = 用引擎默认音色。
  String get ttsVoiceId => _prefs.getString(ttsVoiceKey) ?? '';

  /// 空值删键：备份与诊断里不留死值（与 `ReaderSpeechSettings.setColorArgb` 同风格）。
  Future<void> setTtsVoiceId(String value) => value.isEmpty
      ? _prefs.remove(ttsVoiceKey)
      : _prefs.setString(ttsVoiceKey, value);

  /// 合成代理地址。**敏感项**：只在 prefs 里，`exportBackup()` 的白名单没有它。
  String get ttsProxy => _prefs.getString(ttsProxyKey) ?? '';
  Future<void> setTtsProxy(String value) => value.isEmpty
      ? _prefs.remove(ttsProxyKey)
      : _prefs.setString(ttsProxyKey, value);
}
