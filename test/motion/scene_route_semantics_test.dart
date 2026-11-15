import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/scene_route.dart';

/// E8 真机复验 P1 的语义树对照测试。
///
/// 真机症状：FxSceneRoute 推入播放器后 UIA 树冻结在旧路由（详情页元素过期
/// 几何、播放器控件不可达）。本测试在框架层（SemanticsOwner——a11y 桥的
/// 框架侧对端）对照 MaterialPageRoute 与 FxSceneRoute，跑同一组断言：
///
/// - **测试红**（FxSceneRoute 与 MaterialPageRoute 行为不一致）→ 应用侧可修
///   （补齐缺失语义要素）；
/// - **两路由一致** → 框架侧语义逻辑等价，冻结发生在引擎/桥层（Windows UIA
///   未应用 SemanticsUpdate），记结论不改路由代码。
///
/// 复验结论（2026-11-16）：两路由语义行为完全一致（可达性/遮挡/更新流动），
/// UIA 冻结为引擎/桥层行为；但对照测试抓到**真 bug**——转场 Stack 最顶层的
/// 四线 painter（CustomPainter.hitTest 缺省 null 被 hitTestSelf 当 true）常驻
/// 吃掉整个播放器的鼠标/hover 命中，已在 _CrossLinesPainter 里改写
/// `hitTest => false`，本测试的 toggle 步骤即该修复的回归守卫。
///
/// 框架机制背景（routes.dart/modal_barrier.dart）：两类路由同承 ModalRoute，
/// createOverlayEntries 产出同构的 barrier（ModalBarrier → BlockSemantics
/// 遮挡下层路由语义）+ scope 两个 overlay entry；barrierColor=null /
/// barrierDismissible=false 时二者走同一分支。ClipRect 裁切不影响语义可达性
/// 与矩形（RenderClipRect 不覆写 visitChildrenForSemantics，语义矩形取布局
/// paintBounds 而非可视裁切）。
void main() {
  // 探针 label：container: true 保证 label 精确（无 Text 文本混入）。
  const String detailLabel = 'detail-controls';
  const String playerLabel = 'player-controls';
  const String playerStateA = 'player-state-a';
  const String playerStateB = 'player-state-b';

  /// 收集语义树（框架侧 a11y 桥对端）当前可达的全部 label。
  Set<String> reachableLabels(WidgetTester tester) {
    // pipelineOwner.semanticsOwner 是测试期树内省的唯一路径——框架自带的
    // semantics_tester.dart 同样走这条 deprecated 路（生产代码才有替代口）。
    // ignore: deprecated_member_use
    final SemanticsOwner? owner = tester.binding.pipelineOwner.semanticsOwner;
    expect(owner, isNotNull, reason: '必须先 tester.ensureSemantics()');
    final Set<String> labels = <String>{};
    bool visit(SemanticsNode node) {
      if (node.label.isNotEmpty) {
        labels.addAll(node.label.split('\n'));
      }
      node.visitChildren(visit);
      return true;
    }

    owner!.rootSemanticsNode?.visitChildren(visit);
    return labels;
  }

  /// 纯语义探针按钮：label 精确无混入，48×48 命中区（矩形非空）。
  Widget probeButton(String label) => Semantics(
    label: label,
    container: true,
    button: true,
    child: SizedBox.square(dimension: 48, child: GestureDetector(onTap: () {})),
  );

  /// 详情页（路由 0）：语义探针 + 推入触发按钮。
  Widget detailPage(Route<void> Function(WidgetBuilder builder) routeFactory) =>
      Scaffold(
        body: Center(
          child: Builder(
            builder: (BuildContext context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                probeButton(detailLabel),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    routeFactory((BuildContext context) => const PlayerPage()),
                  ),
                  child: const Text('go'),
                ),
              ],
            ),
          ),
        ),
      );

  /// 落定后的基准断言（两条路由各自跑一遍，reason 指认路由）：
  /// ① 播放器探针语义可达 ② 旧路由探针被语义遮挡 ③ 播放器页内点击可达且
  /// 语义更新仍在流动（toggle = pointer 命中 + setState + SemanticsUpdate）。
  Future<void> expectSettledSemantics(WidgetTester tester, String kind) async {
    final Set<String> after = reachableLabels(tester);
    expect(after, contains(playerLabel), reason: '$kind：播放器探针在语义树可达');
    expect(after, isNot(contains(detailLabel)), reason: '$kind：旧路由探针被遮挡不可达');
    expect(after, contains(playerStateA), reason: '$kind：toggle 前置 sanity');

    // 播放器页内点击必须可达（painter hitTest 回归守卫）：命中 → setState
    // → 文案翻转 → 新 label 出现在语义树。
    await tester.tap(find.text(playerStateA));
    await tester.pumpAndSettle();
    final Set<String> toggled = reachableLabels(tester);
    expect(toggled, isNot(contains(playerStateA)), reason: '$kind：旧状态已从语义树移除');
    expect(toggled, contains(playerStateB), reason: '$kind：播放器页内点击可达且语义更新仍在流动');
  }

  testWidgets('MaterialPageRoute 推入后：新路由控件可达、旧路由被遮挡、更新流动', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: detailPage(
          (WidgetBuilder builder) => MaterialPageRoute<void>(builder: builder),
        ),
      ),
    );

    // 推入前 sanity：详情探针可达、播放器探针不可达（断言机制本身在起作用）。
    final Set<String> before = reachableLabels(tester);
    expect(before, contains(detailLabel));
    expect(before, isNot(contains(playerLabel)));

    await tester.tap(find.text('go'));
    await tester.pump(); // 路由安装（目标页这一拍之后才入树）
    await tester.pumpAndSettle();
    await expectSettledSemantics(tester, 'MaterialPageRoute');
    handle.dispose();
  });

  testWidgets('FxSceneRoute 推入后：与 MaterialPageRoute 语义行为一致', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: detailPage(
          (WidgetBuilder builder) => FxSceneRoute<void>(builder: builder),
        ),
      ),
    );
    expect(
      reachableLabels(tester),
      contains(detailLabel),
      reason: '推入前 sanity',
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // 路由安装
    await tester.pump(); // 转场第一帧
    await tester.pump(const Duration(milliseconds: 480)); // close→open 边界

    // 转场中段：close 段播放器虽被 ClipRect 钉成零尺寸，但语义矩形取布局
    // paintBounds，探针仍应可达（裁切不裁语义）；旧路由已被 barrier 遮挡。
    final Set<String> mid = reachableLabels(tester);
    expect(mid, contains(playerLabel), reason: 'FxSceneRoute 转场中段：播放器探针语义可达');
    expect(
      mid,
      isNot(contains(detailLabel)),
      reason: 'FxSceneRoute 转场中段：旧路由探针被遮挡',
    );

    await tester.pumpAndSettle();
    await expectSettledSemantics(tester, 'FxSceneRoute');
    handle.dispose();
  });
}

/// 播放器页（路由 1）：语义探针 + 可切换文本（toggle = 点击可达 + 语义更新）。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _toggled = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            label: 'player-controls',
            container: true,
            button: true,
            child: SizedBox.square(
              dimension: 48,
              child: GestureDetector(onTap: () {}),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _toggled = !_toggled),
            child: Text(_toggled ? 'player-state-b' : 'player-state-a'),
          ),
        ],
      ),
    ),
  );
}
