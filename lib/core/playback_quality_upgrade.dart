/// v5 主通道失败回退后的会话内清晰度升级判定（纯逻辑，[player_screen]
/// 集成方执行探测与采纳）。
///
/// 背景（11-22 真机事故）：冷启动首个 v5 解析失败时，Go 解析链静默回落
/// webplay / appchain（清晰度封顶 720p、候选少），而回落成功不触发任何
/// 重试路径——用户被迫重启应用才能拿回 1080p。这里把「值得探测」「值得
/// 采纳」的判定抽成纯函数：探测把 v5 恢复放到播放中后台重解析，不挡首帧，
/// 也不自动切档（换清晰度 = 重新 open，与「晚期错误不自动换线」同一原则）。
library;

/// v5 主通道失败后的降级回退通道（清晰度封顶 720p，候选少）。
///
/// 只认明确的回退通道：v5* 是主通道无需探测；空串多为老档案/本地播放，
/// app-sdk 语义不同——档位集合不可靠，一并排除。
const Set<String> kDegradedPlaybackChannels = {'webplay', 'appchain'};

/// 自动升级探测退避（开播后第 1 轮；仍未升级再第 2 轮）。
///
/// 8s 覆盖「令牌/会话就绪慢」这一最大概率场景；30s 兜底网络抖动。
/// v5 熔断窗口（10min）内探测也会拿到 webplay 结果，属已知限制：
/// 退化为「稍后手动点清晰度面板的重新解析」。
const List<Duration> kQualityUpgradeProbeDelays = [
  Duration(seconds: 8),
  Duration(seconds: 30),
];

/// 当前通道是否值得后台探测 v5 升级：仅明确的回退通道；v5* 是主通道无需
/// 探测，空串/app-sdk/本地档位语义不可靠不探测。
bool shouldProbeQualityUpgrade(String? channel) =>
    kDegradedPlaybackChannels.contains(channel?.trim());

/// 探测结果是否值得采纳：必须是 v5 通道，且档位集合（去重）严格多于当前。
/// 不比较具体档位名——不同通道的标签体系不同，数量增益即解锁了更多选择。
bool qualityUpgradeAdoptable({
  required List<String> currentLabels,
  required List<String> incomingLabels,
  required String? incomingChannel,
}) {
  if (incomingChannel == null || !incomingChannel.trim().startsWith('v5')) {
    return false;
  }
  return incomingLabels.toSet().length > currentLabels.toSet().length;
}
