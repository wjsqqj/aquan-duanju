// 帧率探针（批次①b 收口 T2.2）：连接 profile 模式运行的 Flutter 应用的
// VM Service，订阅 `Flutter.Frame` 扩展事件（SchedulerBinding 在非 release
// 模式下自动上报 build/raster 耗时，见 scheduler/binding.dart 的
// `_profileFramePostEvent`），统计采样窗口内的 fps 与帧耗时分布。
//
// 用法：
//   flutter run --profile -d windows   # 先起应用，从输出里拿 VM Service URI
//   dart run scripts/frame_probe.dart "http://127.0.0.1:PORT/TOKEN=/" \
//       --seconds 12 --out build/frame_report.json
//   # 采样期间用真实滚轮/触控滚动目标页面（发现页/榜单），探针只记录不驱动。
//
// 输出：stdout 人读摘要 + JSON 文件。帧耗时取 max(build, raster)（两线程
// 并行，帧完成时间取较慢者）；预算按 60Hz(16.7ms) 与 120Hz(8.3ms) 各算一档。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart' as vmio;

Future<void> main(List<String> args) async {
  final uri = args.isNotEmpty ? args.first : '';
  if (uri.isEmpty) {
    stderr.writeln('用法: dart run scripts/frame_probe.dart <vmServiceUri> '
        '[--seconds 12] [--out frame_report.json]');
    exit(2);
  }
  var seconds = 12.0;
  String? outPath;
  for (var i = 1; i < args.length - 1; i++) {
    if (args[i] == '--seconds') seconds = double.parse(args[i + 1]);
    if (args[i] == '--out') outPath = args[i + 1];
  }

  final vm = await vmio.vmServiceConnectUri(uri);
  final frames = <Map<String, dynamic>>[];
  final sub = vm.onExtensionEvent.listen((Event event) {
    if (event.extensionKind != 'Flutter.Frame') return;
    final data = event.extensionData?.data;
    if (data is Map<String, dynamic>) frames.add(data);
  });
  await vm.streamListen('Extension');

  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < seconds * 1000) {
    stdout.write('\r采样 ${sw.elapsedMilliseconds ~/ 1000}s / '
        '${seconds.toInt()}s，帧数 ${frames.length}   ');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await sub.cancel();
  await vm.dispose();
  stdout.writeln();

  if (frames.isEmpty) {
    stderr.writeln('没收到任何 Flutter.Frame 事件：应用是否在 profile 模式运行？'
        '（release 模式不上报；空闲页面也不产帧，采样期间必须持续滚动）');
    exit(3);
  }

  // 帧号乱序/重复防御：按帧号去重、按出现顺序记录。
  final costs = <double>[];
  final builds = <double>[];
  final rasters = <double>[];
  final seen = <int>{};
  for (final f in frames) {
    final num_ = (f['number'] as num?)?.toInt() ?? 0;
    if (!seen.add(num_)) continue;
    builds.add((f['build'] as num).toDouble() / 1000);
    rasters.add((f['raster'] as num).toDouble() / 1000);
    costs.add(builds.last > rasters.last ? builds.last : rasters.last);
  }
  double pct(List<double> xs, double p) {
    if (xs.isEmpty) return 0;
    final s = xs.toList()..sort();
    return s[((s.length - 1) * p).floor()];
  }

  final report = <String, dynamic>{
    'windowSeconds': seconds,
    'frames': costs.length,
    'fps': costs.length / seconds,
    'buildMs': {'p50': pct(builds, .5), 'p95': pct(builds, .95)},
    'rasterMs': {'p50': pct(rasters, .5), 'p95': pct(rasters, .95)},
    'frameCostMs': {
      'p50': pct(costs, .5),
      'p95': pct(costs, .95),
      'p99': pct(costs, .99),
      'max': costs.reduce((a, b) => a > b ? a : b),
    },
    'jankOver16.7': costs.where((c) => c > 16.7).length,
    'jankOver8.3': costs.where((c) => c > 8.3).length,
  };
  final json = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(json);
  if (outPath != null) {
    File(outPath)..createSync(recursive: true)..writeAsStringSync('$json\n');
  }
  final fps = report['fps'] as double;
  final p95 = pct(costs, .95);
  stdout.writeln('\n结论: fps≈${fps.toStringAsFixed(1)}, '
      '帧耗时 p95=${p95.toStringAsFixed(1)}ms, '
      '>16.7ms 的帧 ${report['jankOver16.7']} / ${costs.length}');
  exit(fps >= 55 ? 0 : 1);
}
