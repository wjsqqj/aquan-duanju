/// 章间呼吸：自动连播切章前等待一段可配置时长。
///
/// 为什么不「往章节音频里塞静音帧」：
/// 1. 合法的 MP3 静音帧不能凭空构造（需要 Huffman 编码的零频谱），复制别段静音帧
///    又与码率/重放增益绑定，不可靠；
/// 2. 塞进音频会改变字节数，而整条链路的时间轴是「字节 ÷ 码率」—— 除非同步平移
///    全部时间点，否则高亮就错位。
///
/// 播放器侧等待是唯一不碰时间轴的做法：停顿时长由设置决定，取消语义由 [isCurrent]
/// 判定（切章/关会话/离开页面后不再自动跳）。
library;

/// 默认章间隔：800ms。足够让听感有「换章」的呼吸，又不至于像卡住。
const int kDefaultChapterGapMs = 800;

/// 可选的间隔档位（设置页下拉用）。0 = 关闭（回到硬切）。
const List<int> kChapterGapOptions = <int>[0, 800, 1500, 3000];

/// 等待 [gapMs] 毫秒；返回 false 表示等待期间会话已失效，调用方不得再切章。
///
/// [isCurrent] 在**等待结束后**判定一次即可：等待期间发生的变化（暂停、切章、关闭）
/// 都会让 epoch 变掉，事后判定天然覆盖，不需要中途轮询。
Future<bool> awaitChapterGap(
  int gapMs, {
  bool Function()? isCurrent,
}) async {
  if (gapMs <= 0) return isCurrent?.call() ?? true;
  await Future<void>.delayed(Duration(milliseconds: gapMs));
  return isCurrent?.call() ?? true;
}
