/// 投屏功能的入口开关（11-10）。
///
/// 为什么用常量而不是删代码：屏幕镜像（MediaProjection → MediaCodec →
/// 自研 MPEG-TS → DLNA）真机实测一直投不出，先把入口藏起来；底层
/// `MirrorController` 与 Android `mirror/`（MirrorService/MirrorTsMuxer/
/// MirrorCaptureChannel）、桌面 `castDesktop*` 通道全部保留，定位清楚后把
/// 这里改成 `true` 即可整体恢复——两处入口（投屏面板的「镜像屏幕」开关、
/// 播放器「本机中继不可用」弹窗的「切换镜像」）都由它门控。
///
/// 未删除的实现不得被新代码依赖；恢复前请先按诊断证据确认镜像链路可用。
const bool kCastMirrorEntryEnabled = false;
