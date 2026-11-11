/// 应用内更新的失败分型与用户文案。
///
/// 为什么要分型：更新链路的失败点很多（网络、校验、签名、权限、用户取消、
/// 安装器拒绝），过去统一提示「下载失败，可到发布页手动下载」，用户无从下手。
/// 这里把「原因」和「下一步动作」绑在一起，UI 只负责选一个展示形态。
enum UpdateFailureKind {
  /// 所有源都下载失败（网络不可达 / 全部非 2xx）。
  network,

  /// 下载完成但 SHA-256 与清单不符。
  checksumMismatch,

  /// 安装包签名与当前已安装版本不一致：系统必然拒绝覆盖安装。
  signatureMismatch,

  /// 安装包包名不是本应用。
  packageMismatch,

  /// 未授予「安装未知应用」。
  permissionDenied,

  /// 用户在系统安装器里取消。
  userCancelled,

  /// 无法调起系统安装器，或安装器明确失败。
  installFailed,
}

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.kind, this.message, {this.detail});

  final UpdateFailureKind kind;

  /// 面向用户的中文文案，必须包含下一步动作。
  final String message;

  /// 诊断细节（包名、签名摘要、系统状态码等）：只进日志/详情，不直接当主文案。
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 每种失败的标准文案。
String updateFailureMessage(UpdateFailureKind kind) => switch (kind) {
  UpdateFailureKind.network =>
    '更新包下载失败，请检查网络后重试；也可到发布页手动下载。',
  UpdateFailureKind.checksumMismatch =>
    '更新包校验失败（SHA-256 不匹配），已放弃本次下载。'
        '可能是更新清单与安装包不一致或下载链路被缓存污染，请稍后重试或到发布页手动下载。',
  UpdateFailureKind.signatureMismatch =>
    '更新包签名与当前已安装版本不一致，系统会拒绝覆盖安装。'
        '请先卸载旧版本再安装：可到发布页手动下载安装包，卸载后重新安装。',
  UpdateFailureKind.packageMismatch =>
    '下载到的文件不是本应用的安装包，已删除。请检查「更新源地址」是否正确后重试。',
  UpdateFailureKind.permissionDenied =>
    '尚未允许「安装未知应用」。请到 系统设置 → 应用 → 特殊应用权限 → 安装未知应用 '
        '中允许本应用，然后重试。',
  UpdateFailureKind.userCancelled => '已取消安装。',
  UpdateFailureKind.installFailed =>
    '无法完成安装，请到发布页手动下载安装包。',
};
