import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'cast_target.dart';

/// mDNS 设备发现（Chromecast `_googlecast._tcp`）。
///
/// 移植自 dart_cast（MIT）并适配本仓 CastDeviceInfo：PTR→SRV→A→TXT 逐级解析，
/// 多轮查询兜底慢应答设备；TXT `fn`（友好名）/`id`（设备 id）/`md`（型号）。
class MdnsDiscovery {
  MdnsDiscovery._();

  static const chromecastServiceType = '_googlecast._tcp.local';

  /// 发现指定服务类型的设备；流在解析完本轮 PTR 后自然结束。
  /// [rounds] 轮询次数、[roundGap] 轮间隔（测试可收紧）。
  static Stream<CastDeviceInfo> discover(
    String serviceType, {
    int rounds = 3,
    Duration roundGap = const Duration(seconds: 2),
    Duration resolveTimeout = const Duration(seconds: 3),
    MDnsClient? clientOverride,
  }) async* {
    final client = clientOverride ?? MDnsClient();
    var owned = clientOverride == null;
    try {
      if (owned) await client.start();
    } catch (_) {
      // mDNS 起不来（权限/网络）不影响其他发现路径。
      return;
    }
    try {
      final seen = <String>{};
      for (var round = 0; round < rounds; round++) {
        if (round > 0) await Future<void>.delayed(roundGap);
        await for (final ptr in client
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(serviceType),
            )
            .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
          if (seen.contains(ptr.domainName)) continue;
          seen.add(ptr.domainName);
          try {
            await for (final srv in client
                .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName),
                )
                .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
              try {
                await for (final ip in client
                    .lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target),
                    )
                    .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
                  final txt = <String, String>{};
                  try {
                    await for (final t in client
                        .lookup<TxtResourceRecord>(
                          ResourceRecordQuery.text(ptr.domainName),
                        )
                        .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
                      txt.addAll(parseTxt(t.text));
                    }
                  } catch (_) {
                    // TXT 超时：空记录继续。
                  }
                  yield CastDeviceInfo(
                    host: ip.address.address,
                    port: srv.port,
                    name: txt['fn'] ?? stripServiceSuffix(ptr.domainName),
                    modelName: txt['md'] ?? '',
                  );
                }
              } catch (_) {
                // A 记录超时：跳过该设备。
              }
            }
          } catch (_) {
            // SRV 超时：跳过该服务。
          }
        }
      }
    } finally {
      if (owned) client.stop();
    }
  }

  /// `客厅电视._googlecast._tcp.local` → `客厅电视`。
  static String stripServiceSuffix(String name) {
    final dot = name.indexOf('._');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// TXT 记录文本 → 键值表（multicast_dns 包把条目以换行连接）。
  static Map<String, String> parseTxt(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final eq = trimmed.indexOf('=');
      if (eq > 0) {
        out[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
      }
    }
    return out;
  }
}
