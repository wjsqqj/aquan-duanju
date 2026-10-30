import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:aquan_duanju/widgets/continuous_chapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连续阅读体（滚动模式）的定位行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('排版变化后仍停在原来那一段（不跳回章首）', (tester) async {
    final positions = <int, int>{};
    Widget build(ReaderTypography type) => MaterialApp(
          home: Scaffold(
            body: ContinuousChapters(
              typography: type,
              chapters: const ['a', 'b'],
              initialChapter: 0,
              loadChapter: (i, id) async =>
                  List<String>.generate(40, (j) => '$id-p$j'),
              onPosition: (chapter, paragraph, ratio) =>
                  positions[chapter] = paragraph,
            ),
          ),
        );

    await tester.pumpWidget(
        build(const ReaderTypography(fontSize: 18, lineHeight: 1.8)));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ContinuousChapters), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));
    final before = positions[0] ?? 0;
    expect(before, greaterThan(0));

    await tester.pumpWidget(
        build(const ReaderTypography(fontSize: 26, lineHeight: 2.2)));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 800));

    final after = positions[0] ?? 0;
    expect(after, greaterThan(0), reason: '排版变化后不能跳回章首');
    expect((after - before).abs(), lessThanOrEqualTo(6));
  });
}
