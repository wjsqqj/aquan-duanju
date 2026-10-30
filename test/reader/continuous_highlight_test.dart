import 'package:aquan_duanju/widgets/continuous_chapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 滚动模式的朗读高亮：从「整段底色」升级为「句底纹 + 词实心」，
/// 且音轨路径（没有字符区间）必须继续走整段底色。
void main() {
  // 段落 0 = 8 个字，段落之间以 '\n' 相接 → 段落 1 的章内起点 = 9。
  const p0 = '第一段没有高亮。';
  const p1 = '第二段正在朗读。';
  const p1Start = p0.length + 1;

  Future<void> pumpChapters(
    WidgetTester tester, {
    required int? paragraph,
    (int, int)? base,
    (int, int)? active,
    int colorArgb = 0x66FFC107,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousChapters(
            chapters: const <String>['c1'],
            initialChapter: 0,
            loadChapter: (i, id) async => const <String>[p0, p1],
            onPosition: (_, _, _) {},
            highlightChapter: 0,
            highlightParagraph: paragraph,
            highlightBase: base,
            highlightActive: active,
            highlightColorArgb: colorArgb,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 收集所有带背景色的 span（Text.rich 里的切分结果）。
  List<TextSpan> decoratedSpans(WidgetTester tester) {
    final out = <TextSpan>[];
    for (final element in find.byType(Text).evaluate()) {
      final text = element.widget as Text;
      final span = text.textSpan;
      if (span == null) continue;
      span.visitChildren((child) {
        if (child is TextSpan && child.style?.backgroundColor != null) {
          out.add(child);
        }
        return true;
      });
    }
    return out;
  }

  testWidgets('有字符区间：切 span 出句底纹 + 词实心，非高亮段保持纯 Text', (tester) async {
    await pumpChapters(
      tester,
      paragraph: 1,
      base: (p1Start, p1Start + p1.length),
      active: (p1Start, p1Start + 2), // 前两个字
    );

    // 非高亮段仍是普通 Text（快路径，不构造 spans）。
    final plain = find.text(p0);
    expect(tester.widget<Text>(plain).textSpan, isNull);

    final spans = decoratedSpans(tester);
    expect(spans.length, greaterThanOrEqualTo(2),
        reason: '句底纹与词实心都要出现（至少两个带背景的 span）');

    // 词实心必须精确落在前两个字上。
    final activeSpan = spans.where((s) => s.text == p1.substring(0, 2)).toList();
    expect(activeSpan, isNotEmpty, reason: '当前词应被单独切成一个 span');
    expect(activeSpan.first.style!.backgroundColor, isNotNull);
  });

  testWidgets('没有字符区间（音轨路径）：回落到整段底色，不切 span', (tester) async {
    await pumpChapters(tester, paragraph: 1);

    expect(decoratedSpans(tester), isEmpty, reason: '没有区间就不许切 span');
    // 整段底色仍然生效（ColoredBox）。
    expect(find.byType(ColoredBox), findsWidgets);
    // 段落文本仍然渲染出来。
    expect(find.text(p1), findsOneWidget);
  });

  testWidgets('高亮在别的章时不画（避免串章）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinuousChapters(
            chapters: const <String>['c1'],
            initialChapter: 0,
            loadChapter: (i, id) async => const <String>[p0, p1],
            onPosition: (_, _, _) {},
            // 高亮指向不存在的第 3 章。
            highlightChapter: 2,
            highlightParagraph: 1,
            highlightBase: (p1Start, p1Start + p1.length),
            highlightActive: (p1Start, p1Start + 2),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(decoratedSpans(tester), isEmpty);
  });
}
