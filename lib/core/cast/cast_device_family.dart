import 'cast_target.dart';

/// DLNA 接收端「设备族」（11-10）。
///
/// 为什么需要：真机日志里同一台电视会同时暴露多个接收端（airpin/HappyCast/
/// 极光TV/央视频助手/WMP），它们的 UPnP `modelName` 各不相同，兼容行为也
/// 差很多（WMP 族只认 TS 直流、Cling 系要标准 SOAP、海思对 protocolInfo
/// 第 4 段敏感）。Sink（GetProtocolInfo）经常为空或撒谎，没有证据时只能
/// 按族给默认值——**族只做默认值，任何 Sink/取流证据都优先**。
enum CastDeviceFamily {
  /// Windows Media Player 族（我的果果投屏、投屏电视Q3）：只认 TS 直流。
  wmp,

  /// airpin / WaxRain（wjsqqj）：会把 loopback 改写成来源 IP，HLS 可用。
  waxrain,

  /// 乐播 HappyCast（TV(192.168.31.159））：动态端口，HLS 可用。
  happycast,

  /// 腾讯极光TV（QQLiveTV Render）：Sink 常为空，HLS 可用。
  qqlive,

  /// 海思 HiDMR（Living Room 1_3186）：对 protocolInfo 第 4 段敏感。
  hisilicon,

  /// 夏普电视内置 Cling 渲染器（央视频投屏助手 LCD-xxDEM6A-B）。
  sharpCling,

  /// 无法识别：保持现状（HLS）。
  unknown,
}

/// 按 `modelName` 识别设备族（大小写不敏感，按序命中首个）。
///
/// modelName 来自设备描述 XML 的 `<modelName>`；为空时退回 friendlyName +
/// manufacturer 兜底（部分盒子只填 manufacturer）。
CastDeviceFamily castDeviceFamilyOf(CastTarget target) {
  final model = target.modelName.toLowerCase();
  final name = target.name.toLowerCase();
  final maker = target.manufacturer.toLowerCase();

  if (model.contains('windows media player')) return CastDeviceFamily.wmp;
  if (model.contains('waxrain')) return CastDeviceFamily.waxrain;
  if (model.contains('happycast')) return CastDeviceFamily.happycast;
  if (model.contains('qqlive')) return CastDeviceFamily.qqlive;
  if (model.contains('hisilicon') || name.contains('hidmr')) {
    return CastDeviceFamily.hisilicon;
  }
  if (model.contains('lcd-') || maker.contains('sharp')) {
    return CastDeviceFamily.sharpCling;
  }
  // modelName 缺失时的兜底：只看厂商与名字。
  if (maker.contains('microsoft') && name.contains('投屏')) {
    return CastDeviceFamily.wmp;
  }
  if (maker.contains('waxrain')) return CastDeviceFamily.waxrain;
  if (maker.contains('lebo')) return CastDeviceFamily.happycast;
  return CastDeviceFamily.unknown;
}

/// 诊断/日志用的族标签（含原始 modelName，便于回传定位）。
String castDeviceFamilyLabel(CastDeviceFamily family) => switch (family) {
      CastDeviceFamily.wmp => 'wmp（Windows Media Player 族）',
      CastDeviceFamily.waxrain => 'waxrain（airpin）',
      CastDeviceFamily.happycast => 'happycast（乐播）',
      CastDeviceFamily.qqlive => 'qqlive（极光TV）',
      CastDeviceFamily.hisilicon => 'hisilicon（HiDMR）',
      CastDeviceFamily.sharpCling => 'sharp（Cling 渲染器）',
      CastDeviceFamily.unknown => 'unknown',
    };

/// 族默认中继档位（仅在 Sink 证据缺失时使用）。
///
/// WMP 族的播放器是「文件式」实现：给它 HLS 清单会打开却不出画，只认
/// TS 直流；其余族（含 airpin/极光/央视频/海思）实测都能取 HLS 分片。
String relayFormatForFamily(CastDeviceFamily family) =>
    family == CastDeviceFamily.wmp ? 'ts' : 'hls';
