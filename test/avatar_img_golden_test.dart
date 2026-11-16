import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bare avatar image', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Center(
            child: Image.asset('assets/avatar/avatar.png', height: 300),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(Image),
      // 基准图必须入库（build/ 被 .gitignore，CI 上不存在会导致
      // "Could not be compared against non-existent file"）。
      matchesGoldenFile('goldens/avatar_img_golden.png'),
    );
  });
}
