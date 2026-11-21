import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/playback_quality_upgrade.dart';

void main() {
  group('shouldProbeQualityUpgrade', () {
    test('降级回退通道值得探测（含空白容差）', () {
      expect(shouldProbeQualityUpgrade('webplay'), isTrue);
      expect(shouldProbeQualityUpgrade('appchain'), isTrue);
      expect(shouldProbeQualityUpgrade(' appchain '), isTrue,
          reason: '前后空白应 trim 后再判定');
    });

    test('主通道/空串/本地语义不探测', () {
      expect(shouldProbeQualityUpgrade('v5-pure'), isFalse);
      expect(shouldProbeQualityUpgrade('v5-native'), isFalse);
      expect(shouldProbeQualityUpgrade('v5-sidecar'), isFalse);
      expect(shouldProbeQualityUpgrade(null), isFalse,
          reason: '空通道多为老档案/本地，档位语义不可靠');
      expect(shouldProbeQualityUpgrade(''), isFalse);
      expect(shouldProbeQualityUpgrade('app-sdk'), isFalse);
    });
  });

  group('qualityUpgradeAdoptable', () {
    test('v5 通道且档位严格变多 → 采纳', () {
      expect(
        qualityUpgradeAdoptable(
          currentLabels: const ['720p'],
          incomingLabels: const ['360p', '480p', '540p', '720p', '1080p'],
          incomingChannel: 'v5-pure',
        ),
        isTrue,
      );
    });

    test('去重后与当前同数 → 不采纳', () {
      expect(
        qualityUpgradeAdoptable(
          currentLabels: const ['720p'],
          incomingLabels: const ['720p', '720p', '720p'],
          incomingChannel: 'v5-pure',
        ),
        isFalse,
      );
    });

    test('档位更少 → 不采纳', () {
      expect(
        qualityUpgradeAdoptable(
          currentLabels: const ['360p', '480p', '720p'],
          incomingLabels: const ['480p'],
          incomingChannel: 'v5-native',
        ),
        isFalse,
      );
    });

    test('非 v5 通道一律不采纳', () {
      const incoming = ['360p', '480p', '540p', '720p', '1080p'];
      for (final channel in ['webplay', 'appchain', 'app-sdk', null]) {
        expect(
          qualityUpgradeAdoptable(
            currentLabels: const ['720p'],
            incomingLabels: incoming,
            incomingChannel: channel,
          ),
          isFalse,
          reason: 'channel=$channel 不应采纳',
        );
      }
    });

    test('当前档位含重复也按去重集合比较', () {
      expect(
        qualityUpgradeAdoptable(
          currentLabels: const ['720p', '720p', '720p'],
          incomingLabels: const ['720p', '1080p'],
          incomingChannel: 'v5-pure',
        ),
        isTrue,
        reason: '去重后当前 1 档 < 新 2 档',
      );
      expect(
        qualityUpgradeAdoptable(
          currentLabels: const ['720p', '720p'],
          incomingLabels: const ['720p', '720p'],
          incomingChannel: 'v5-pure',
        ),
        isFalse,
        reason: '去重后同数不采纳',
      );
    });
  });
}
