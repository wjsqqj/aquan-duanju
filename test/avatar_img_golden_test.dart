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
      matchesGoldenFile('../build/avatar_img_golden.png'),
    );
  });
}
