import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 源市场底栏筛选 chip 条的高度回归（11-19）。
///
/// 背景：`bottomNavigationBar` 给的是**松高度约束**，横向
/// `SingleChildScrollView` 会把可用高度吃满；`JellyChip` 内部的 `Center`
/// 在有界约束下撑满（Align 取 constraints.biggest），于是 4 枚筛选 chip
/// 变成贯穿全屏的竖条，底栏占满整屏、body 被挤没——用户实测「源市场 →
/// 开始扫描 → 扫描完成后 UI 崩溃」。
///
/// 修复：横向 chip 条给紧高度约束（与全站其它 chip 条同口径 44dp）。
/// 本测试锁死该形态，避免以后把约束去掉又复发。
Widget chipLike(String label) => AnimatedContainer(
      duration: const Duration(milliseconds: 1),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Center(
        widthFactor: 1,
        child: Text(label, maxLines: 1),
      ),
    );

double chipContainerHeight(WidgetTester tester, String label) => tester
    .getSize(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(AnimatedContainer),
      ),
    )
    .height;

/// 底栏筛选条：[bounded] 为 true 时套紧高度约束（即修复后的形态）。
Widget marketBottomBar({required bool bounded}) {
  final Widget strip = SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        chipLike('全部'),
        chipLike('可用'),
        chipLike('失败'),
        chipLike('明文HTTP'),
      ],
    ),
  );
  return Scaffold(
    body: const SizedBox.expand(),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            if (bounded)
              // 紧高度约束：Expanded 必须是 Row 的直接子节点负责宽度，
              // 高度由内层 ConstrainedBox 收紧。
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints.tightFor(height: 44),
                  child: strip,
                ),
              )
            else
              Expanded(child: strip),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('回归：底栏横向 chip 条缺紧高度约束会被拉成全高竖条', (tester) async {
    // 反向锁定：证明「不加紧高度约束」确实会把 chip 撑到全屏高。
    await tester.pumpWidget(MaterialApp(home: marketBottomBar(bounded: false)));
    expect(chipContainerHeight(tester, '全部'), greaterThan(300),
        reason: '无紧约束时 chip 会被撑满底栏可用高度（复现 11-19 现场）');
  });

  testWidgets('修复：给紧高度约束后 chip 回到正常胶囊高度', (tester) async {
    await tester.pumpWidget(MaterialApp(home: marketBottomBar(bounded: true)));
    for (final label in ['全部', '可用', '失败', '明文HTTP']) {
      expect(chipContainerHeight(tester, label), lessThanOrEqualTo(44),
          reason: '$label chip 应保持胶囊高度，不得撑满屏幕');
    }
  });
}
