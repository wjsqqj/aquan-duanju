/// 「我的 → 设置 → 听书」里 **prefs 侧键**的读写入口（design.md §6/§7）。
///
/// 为什么直接落 SharedPreferences 而不是加进 `SettingsStore`：
/// - `lib/store/stores.dart` 正被投屏工作流同时编辑，本任务只**读**它已有的类；
/// - 备份导出走 `stores.dart` 里 `SettingsStore.exportBackup()` 那份**写死的字面量
///   名单**，不在名单里的键天然不出门。`listen.tts.proxy`（代理地址，可能带凭据）与
///   `voice.apiKey` 因此是同一套处理：写 prefs、不进备份 —— 不需要额外的排除列表，
///   也就不会漏。
///
/// 键的**字面值只有一处定义**：合成四键转引 [ReaderSpeechController] 已有常量；
/// 定时/预取三键在本类内 `static const` 单点定义（控制器本次派发**不得修改**，
/// 而本类已是听书设置真值入口 —— 再新起一处常量集合就是第二套真值）。
/// 显示侧的三键（粒度 / 样式 / 颜色）不在这个类里 —— 它们已由
/// `ReaderSpeechSettings` 负责读写，渲染层读的就是那个类，设置页照同一入口写，
/// 免得长出第二套真值。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'reader_speech_controller.dart';
import 'speech/sleep_timer.dart';

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

/// 合成与定时设置的薄封装：读取同步（prefs 实例已缓存），写入异步。
class ReaderListenSettings {
  const ReaderListenSettings(this._prefs);

  static const String ttsEnabledKey = ReaderSpeechController.ttsEnabledKey;
  static const String ttsVoiceKey = ReaderSpeechController.ttsVoiceKey;
  static const String ttsProxyKey = ReaderSpeechController.ttsProxyKey;
  static const String ttsEngineKey = ReaderSpeechController.ttsEngineKey;

  /// 定时关闭模式（design §6）。字面值只在本类定义一次。
  static const String sleepModeKey = 'listen.sleepMode';

  /// 定时关闭时长（分钟）。
  static const String sleepMinutesKey = 'listen.sleepMinutes';

  /// 下一章预取开关（默认开，是本任务唯一默认开启的新行为）。
  static const String prefetchKey = 'listen.prefetch';

  /// 段首尾静音裁剪开关（默认**开**）：关掉回到「原样拼接」，用于试听对比。
  static const String trimSilenceKey = 'listen.trim.silence';

  /// 按书语速键：`listen.speed.<bookId>`。**缺键回落全局 `listen.speed`**，
  /// 老用户的既有偏好因此继续生效（迁移零成本）；全局键仍是「新书的默认值」。
  static String speedKeyOf(String bookId) => 'listen.speed.$bookId';

  /// 多角色朗读开关（默认**关**：它会把一章拆成多次请求，由用户自己决定）。
  static const String rolesEnabledKey = 'listen.roles.enabled';

  /// 对话音色偏好（音色 id 列表，JSON 存）。空 = 自动从引擎可用音色里挑。
  static const String rolesVoicesKey = 'listen.roles.voices';

  /// 第三方 HTTP TTS 源配置（整段 JSON）。敏感（可能含 header 密钥），
  /// 与 `listen.tts.proxy` 同一处理：只存本机、不进备份。
  static const String ttsSourceKey = 'listen.tts.source';

  /// `listen.sleepMinutes` 缺省值：与浮层 chips 的 30 档对齐。
  static const int kDefaultSleepMinutes = 30;

  final SharedPreferences _prefs;

  /// 缺键按「开」：只有显式关掉才回到「仅平台音轨」（design.md §8 的回滚开关）。
  bool get ttsEnabled => _prefs.getBool(ttsEnabledKey) ?? true;
  Future<void> setTtsEnabled(bool value) =>
      _prefs.setBool(ttsEnabledKey, value);

  String get ttsEngineId =>
      _prefs.getString(ttsEngineKey) ?? kDefaultTtsEngineId;
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

  /// 定时模式。**非法/脏值一律回落 off**：老版本或手改过的 prefs 不许让设置页
  /// 白屏，也不许让宿主误武装一个不存在的档（对齐 voice-contract 的回落先例）。
  SleepMode get sleepMode {
    final String? raw = _prefs.getString(sleepModeKey);
    for (final SleepMode m in SleepMode.values) {
      if (m.name == raw) return m;
    }
    return SleepMode.off;
  }

  /// `off` 删键：不留死值，也让「没设过」与「显式 off」在诊断里可区分。
  Future<void> setSleepMode(SleepMode mode) => mode == SleepMode.off
      ? _prefs.remove(sleepModeKey)
      : _prefs.setString(sleepModeKey, mode.name);

  /// 定时时长：读不到回落 30（design §6）。
  int get sleepMinutes =>
      _prefs.getInt(sleepMinutesKey) ?? kDefaultSleepMinutes;
  Future<void> setSleepMinutes(int value) =>
      _prefs.setInt(sleepMinutesKey, value);

  /// 预取开关。**缺键按「开」**：关掉 `listen.prefetch` 即回到本任务前的行为
  /// （design §7 的唯一默认值变化 / 回滚开关）。
  bool get prefetchEnabled => _prefs.getBool(prefetchKey) ?? true;
  Future<void> setPrefetchEnabled(bool value) =>
      _prefs.setBool(prefetchKey, value);

  /// 静音裁剪开关。**缺键按开**：老用户升级后就享受更紧致的音频，不必手动开。
  bool get trimSilenceEnabled => _prefs.getBool(trimSilenceKey) ?? true;
  Future<void> setTrimSilenceEnabled(bool value) =>
      _prefs.setBool(trimSilenceKey, value);

  /// 多角色朗读开关（默认关）。
  bool get rolesEnabled => _prefs.getBool(rolesEnabledKey) ?? false;

  Future<void> setRolesEnabled(bool value) =>
      _prefs.setBool(rolesEnabledKey, value);

  /// 对话音色偏好：JSON 字符串数组，解析失败一律当空（-> 自动挑）。
  List<String> get roleVoices {
    final raw = _prefs.getString(rolesVoicesKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .whereType<String>()
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // 用户手改/版本迁移坏了：退回自动挑，不让设置页崩。
      return const <String>[];
    }
  }

  Future<void> setRoleVoices(List<String> ids) =>
      _prefs.setString(rolesVoicesKey, jsonEncode(ids));

  /// 第三方 HTTP TTS 源配置原文（空 = 未配置）。
  String get ttsSourceJson => _prefs.getString(ttsSourceKey) ?? '';

  Future<void> setTtsSourceJson(String value) => value.trim().isEmpty
      ? _prefs.remove(ttsSourceKey)
      : _prefs.setString(ttsSourceKey, value.trim());
}
