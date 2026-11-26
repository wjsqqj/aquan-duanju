/// 跨 FFI 的错误模型：Go 侧每个错误都编成
/// {code, message, retryable, retryAfterMs}，这里恢复成异常；整条解析链都失败时
/// Go 侧另带 diagnostic（被丢弃的中间环节原因，只进日志）。
library;

/// SDK 错误码，与 openhongguo dispatch 的错误码一致。
class AquaCode {
  static const cancelled = 'CANCELLED';
  static const invalidOptions = 'INVALID_OPTIONS';
  static const profileNotFound = 'PROFILE_NOT_FOUND';
  static const signerUnavailable = 'SIGNER_UNAVAILABLE';
  static const authenticationRequired = 'AUTHENTICATION_REQUIRED';
  static const notProtected = 'NOT_PROTECTED';
  static const drmProtected = 'DRM_PROTECTED';
  static const anonymousLimited = 'ANONYMOUS_LIMITED';

  /// 取流接口（POST + video_tab 兜底）都没有返回播放模型。
  /// 与 [anonymousLimited] 区分：它只说明「这次没拿到地址」，
  /// 上游原因未公开，不一定能靠重置设备解决。
  static const playbackUnavailable = 'PLAYBACK_UNAVAILABLE';
  static const rateLimited = 'RATE_LIMITED';
  static const transport = 'TRANSPORT';
  static const signatureRejected = 'SIGNATURE_REJECTED';
  static const contentUnavailable = 'CONTENT_UNAVAILABLE';
  static const paramInvalid = 'PARAM_INVALID';
  static const challengeRequired = 'CHALLENGE_REQUIRED';
  static const deviceRejected = 'DEVICE_REJECTED';
  static const endOfList = 'END_OF_LIST';
  static const albumUnavailable = 'ALBUM_UNAVAILABLE';

  // 投屏中继（castrelay.go，本任务新增）。
  static const castRelayUnavailable = 'CAST_RELAY_UNAVAILABLE';
  static const castRelayInvalid = 'CAST_RELAY_INVALID';
  static const castRelayNoSession = 'CAST_RELAY_NO_SESSION';
  static const castRelayInternal = 'CAST_RELAY_INTERNAL';
  /// 官网 play-info 游客墙：未登录仅前 5 集可看，后段返回 403。
  static const webLoginRequired = 'WEB_LOGIN_REQUIRED';
  static const unknown = 'UNKNOWN';
}

/// 一次核心调用的失败。UI 层根据 [code] 给出中文文案与操作建议。
class AquaException implements Exception {
  AquaException({
    required this.code,
    required this.message,
    required this.retryable,
    this.retryAfterMs = 0,
    this.diagnostic = '',
  });

  factory AquaException.fromJson(Map<String, dynamic> json) => AquaException(
        code: json['code'] as String? ?? AquaCode.unknown,
        message: json['message'] as String? ?? '未知错误',
        retryable: json['retryable'] as bool? ?? false,
        retryAfterMs: json['retryAfterMs'] as int? ?? 0,
        diagnostic: json['diagnostic'] as String? ?? '',
      );

  final String code;
  final String message;
  final bool retryable;
  final int retryAfterMs;

  /// 只进日志的诊断附注：Go 侧在整条解析链都失败时，把被静默丢弃的中间环节
  /// 原因（v5、旧 appchain）放在这里（11-26：此前日志里只剩 webplay 的 403，
  /// 无从判断 v5 为什么失败）。
  ///
  /// 不参与 [message] / [toString] / [friendlyText]：UI 文案、按 code 的分支、
  /// 按文案匹配的播放失败分类都不受它影响；要进日志用 [errorLogText]。
  final String diagnostic;

  /// 给用户看的中文文案；原始 message 留给诊断。
  String get friendlyText {
    switch (code) {
      case AquaCode.rateLimited:
        return '请求太频繁了，稍等几秒再试';
      case AquaCode.anonymousLimited:
        return '当前设备已达到匿名访问上限，可在「我的 → 设置」里重置设备';
      case AquaCode.playbackUnavailable:
        // 取流接口对匿名请求返回空 body 时归到这里：上游原因未公开，
        // 不再断言「设备配额用尽」，也不把重置设备说成唯一解法。
        // 2026-11-16 实测（`cmd/diag -probe`）：换设备、换版本档位
        // （73932/70300/65000/60100）、各种参数猜测全部同样空响应 ——
        // 属于源站封堵，本机做什么都不会恢复，文案要说明这一点。
        return '取流接口暂时没有返回播放地址（源站限制，非本机问题）：'
            '已自动重试，建议稍后再试或换一部剧';
      case AquaCode.challengeRequired:
        return '服务端要求验证，暂时无法访问；可尝试重置设备';
      case AquaCode.deviceRejected:
        return '设备被拒绝访问，可在「我的 → 设置」里重置设备';
      case AquaCode.signatureRejected:
        return '请求签名被拒绝，请更新到新版本';
      case AquaCode.transport:
        return '网络异常，请检查网络后重试';
      case AquaCode.contentUnavailable:
        return '该内容暂时无法观看';
      case AquaCode.albumUnavailable:
        return '该合集暂时无法获取';
      case AquaCode.drmProtected:
        return '加密内容解密失败，请更新到新版本';
      case AquaCode.endOfList:
        return '没有更多了';
      case AquaCode.profileNotFound:
        return '设备档案丢失，正在重建';
      case AquaCode.cancelled:
        return '请求已取消';
      case AquaCode.authenticationRequired:
        return '该内容需要登录才能观看';
      case AquaCode.castRelayUnavailable:
        return '加密内容投屏需要本机中继（ffmpeg），当前设备不可用';
      case AquaCode.castRelayInvalid:
        return '中继参数无效';
      case AquaCode.webLoginRequired:
        return '该集需登录观看：红果官网未登录仅开放前 5 集，请用红果 App 登录或观看前 5 集';
      case AquaCode.castRelayNoSession:
        return '中继会话已结束';
      case AquaCode.castRelayInternal:
        return '中继启动失败，请重试';
      case AquaCode.paramInvalid:
      case AquaCode.invalidOptions:
        return '请求参数无效，请更新到新版本';
      case AquaCode.signerUnavailable:
        return '签名组件不可用，请更新到新版本';
      default:
        // 带上原始 code：只给「出了点小问题」时，用户反馈里没有任何可定位信息。
        return '出了点小问题（$code），请稍后再试';
    }
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        'retryable': retryable,
        'retryAfterMs': retryAfterMs,
      };

  @override
  String toString() => 'AquaException($code): $message';
}

/// 进日志用的错误文本：[AquaException] 带上诊断附注（有则追加），其余错误原样。
///
/// 记录解析链失败时用它代替 `$e`，否则 Go 侧挂上的 diagnostic 到不了日志。
String errorLogText(Object error) {
  if (error is! AquaException || error.diagnostic.isEmpty) return '$error';
  return '$error · 诊断: ${error.diagnostic}';
}
