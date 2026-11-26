import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/aqua_error.dart';

void main() {
  group('AquaException', () {
    test('解析信封错误', () {
      final e = AquaException.fromJson(const {
        'code': 'RATE_LIMITED',
        'message': 'too fast',
        'retryable': true,
        'retryAfterMs': 1200,
      });
      expect(e.code, AquaCode.rateLimited);
      expect(e.retryable, isTrue);
      expect(e.retryAfterMs, 1200);
      expect(e.friendlyText, contains('频繁'));
    });

    test('每个已知错误码都有中文文案', () {
      const codes = [
        AquaCode.cancelled,
        AquaCode.invalidOptions,
        AquaCode.profileNotFound,
        AquaCode.signerUnavailable,
        AquaCode.authenticationRequired,
        AquaCode.notProtected,
        AquaCode.drmProtected,
        AquaCode.anonymousLimited,
        AquaCode.playbackUnavailable,
        AquaCode.rateLimited,
        AquaCode.transport,
        AquaCode.signatureRejected,
        AquaCode.contentUnavailable,
        AquaCode.paramInvalid,
        AquaCode.challengeRequired,
        AquaCode.deviceRejected,
        AquaCode.endOfList,
        AquaCode.albumUnavailable,
        AquaCode.webLoginRequired,
        AquaCode.unknown,
      ];
      for (final c in codes) {
        final e = AquaException(code: c, message: 'x', retryable: false);
        expect(e.friendlyText, isNotEmpty, reason: '$c 缺少文案');
      }
    });

    test('取流不可用不再宣称设备配额用尽', () {
      final e = AquaException(
        code: AquaCode.playbackUnavailable,
        message: 'openhongguo: playback model unavailable',
        retryable: false,
      );
      expect(e.friendlyText, contains('取流接口'));
      expect(e.friendlyText, isNot(contains('匿名访问上限')));
    });

    test('游客墙码准确说明仅前 5 集且需登录', () {
      final e = AquaException(
        code: AquaCode.webLoginRequired,
        message: 'webplay: login required',
        retryable: false,
      );
      expect(e.friendlyText, contains('前 5 集'));
      expect(e.friendlyText, contains('登录'));
    });

    test('未知 code 回落默认文案并带上 code（便于定位）', () {
      final e = AquaException.fromJson(const {'code': 'WHATEVER'});
      expect(e.friendlyText, '出了点小问题（WHATEVER），请稍后再试');
      expect(e.friendlyText, contains('WHATEVER'));
    });

    test('diagnostic 解析自信封，缺省为空串', () {
      const diag = 'v5: hongguo-v5: unavailable: breaker-open';
      final e = AquaException.fromJson(const {
        'code': 'WEB_LOGIN_REQUIRED',
        'message': 'webplay: login required',
        'diagnostic': diag,
      });
      expect(e.diagnostic, diag);
      expect(AquaException.fromJson(const {'code': 'X'}).diagnostic, '');
    });

    test('diagnostic 只进日志：不影响 message / toString / 文案', () {
      final plain = AquaException(
        code: AquaCode.webLoginRequired,
        message: 'webplay: login required',
        retryable: false,
      );
      final withDiag = AquaException(
        code: AquaCode.webLoginRequired,
        message: 'webplay: login required',
        retryable: false,
        diagnostic: 'v5: down',
      );
      expect(withDiag.message, plain.message);
      expect(withDiag.toString(), plain.toString());
      expect(withDiag.friendlyText, plain.friendlyText);
    });

    test('errorLogText：有诊断则追加，否则与原文本一致', () {
      final e = AquaException(
        code: AquaCode.webLoginRequired,
        message: 'webplay: login required',
        retryable: false,
        diagnostic: 'v5: down',
      );
      expect(
        errorLogText(e),
        'AquaException(WEB_LOGIN_REQUIRED): webplay: login required · 诊断: v5: down',
      );
      final plain = AquaException(
        code: AquaCode.webLoginRequired,
        message: 'webplay: login required',
        retryable: false,
      );
      expect(errorLogText(plain), '$plain');
      expect(errorLogText(StateError('x')), 'Bad state: x');
    });
  });
}
