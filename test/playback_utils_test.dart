import 'package:aquan_duanju/core/playback_utils.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

PlaybackResult pbWithExpiry(int epochSeconds) {
  // Playback 的 expiresAt 无公开构造参数，走 JSON 反序列化。
  return PlaybackResult.fromJson({
    'playback': {'expires_at': epochSeconds},
  });
}

void main() {
  test('预解析有效期判定：留 60 秒余量', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    // 30 分钟后过期：可用
    expect(prefetchUsable(pbWithExpiry(1700000000 + 1800), now), isTrue);
    // 30 秒后过期：余量不足，不可用
    expect(prefetchUsable(pbWithExpiry(1700000000 + 30), now), isFalse);
    // 已过期：不可用
    expect(prefetchUsable(pbWithExpiry(1700000000 - 10), now), isFalse);
    // 未知（0）：视为可用
    expect(prefetchUsable(pbWithExpiry(0), now), isTrue);
  });
}
