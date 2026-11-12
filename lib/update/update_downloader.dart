import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// 一个可下载的安装包地址（官方或镜像）。
class UpdateDownloadSource {
  const UpdateDownloadSource({
    required this.url,
    required this.label,
    this.mirrorId,
  });

  final String url;
  final String label;

  /// 镜像 id；直连为 null。
  final String? mirrorId;

  @override
  String toString() => 'UpdateDownloadSource($label, $url)';
}

/// 下载进度快照（[total] 为 0 表示服务端没给总大小）。
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    required this.bytesPerSecond,
  });

  final int received;
  final int total;
  final double bytesPerSecond;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;

  @override
  String toString() =>
      'DownloadProgress($received/$total, ${bytesPerSecond.toStringAsFixed(0)}B/s)';
}

class DownloadResult {
  const DownloadResult({required this.source, required this.bytes});

  /// 实际下完的源。
  final UpdateDownloadSource source;
  final int bytes;
}

/// 用户主动取消（保留 `.part*`，下次续传）。
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => '下载已取消';
}

/// 某个源速度持续低于阈值，已中止并准备换源。
class DownloadTooSlow implements Exception {
  const DownloadTooSlow({required this.source, required this.speedBps});

  final UpdateDownloadSource source;
  final double speedBps;

  @override
  String toString() =>
      '${source.label} 速度过低（${(speedBps / 1024).toStringAsFixed(0)} KB/s）';
}

/// 全部候选源都失败。
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message（$cause）';
}

/// 安装包下载器：**只管把字节拿全**，不关心版本、校验与安装。
///
/// 三种提速手段（都不引入第三方依赖）：
/// 1. 分片并发：文件 ≥ [minSegmentBytes] × 2 且服务端支持 `Range` 时开
///    [maxConnections] 路，每条连接只下一段；
/// 2. 跨源续传：任一源失败/太慢时保留 `.part*`，下一个源按已下长度继续，
///    不再从 0 开始（同一安装包的镜像内容一致，最终由 SHA-256 兜底）；
/// 3. 低速看门狗：速度连续 [slowWindow] 低于 [minSpeedBps] 或 [idleTimeout]
///    没有任何数据就中止当前源换下一个——**低速但不断流是镜像最常见的坑**。
///
/// 下载结果先落到 `<target>.part` / `<target>.part<i>`，成功后合并、改名为
/// [target]；失败一律保留分片供下次续传。
class UpdateDownloader {
  UpdateDownloader({
    HttpClient Function()? clientFactory,
    this.connectTimeout = const Duration(seconds: 15),
    this.responseTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 20),
    this.slowWindow = const Duration(seconds: 12),
    this.minSpeedBps = 64 * 1024,
    this.progressInterval = const Duration(milliseconds: 200),
    this.maxConnections = 4,
    this.minSegmentBytes = 2 * 1024 * 1024,
    this.probeTimeout = const Duration(seconds: 8),
    this.fastFailureWindow = const Duration(seconds: 8),
    this.retryDelay = const Duration(milliseconds: 1200),
  }) : _clientFactory = clientFactory ?? (() => HttpClient());

  final HttpClient Function() _clientFactory;

  final Duration connectTimeout;
  final Duration responseTimeout;

  /// 多久没有任何新数据就判定卡死。
  final Duration idleTimeout;

  /// 低速判定窗口：窗口内平均速度低于阈值才换源，避免首包慢就误杀。
  final Duration slowWindow;
  final int minSpeedBps;

  /// 进度回调最小间隔（UI 不需要每个 chunk 都重建）。
  final Duration progressInterval;

  final int maxConnections;

  /// 小于它 ×2 的文件不分片（分片开销不值得）。
  final int minSegmentBytes;

  final Duration probeTimeout;

  /// 只有"快速失败"才在同源上退避重试一次：超时类失败重试只会把弱网耗时翻倍。
  final Duration fastFailureWindow;
  final Duration retryDelay;

  /// 同一 URL 的总大小/是否支持 Range 只探一次。
  final Map<String, _RemoteInfo> _infoCache = <String, _RemoteInfo>{};

  /// 依次尝试 [sources]，第一个下完且通过 [validate] 的胜出。
  ///
  /// 失败会保留分片继续下一个源；[isCancelled] 返回 true 时抛
  /// [DownloadCancelled]（分片同样保留）。
  ///
  /// [validate] 用于下载完成后的完整性校验（SHA-256）：返回 false 时删除
  /// target 与全部分片，并换下一个源——坏包重试同一路径没有意义。
  Future<DownloadResult> download({
    required List<UpdateDownloadSource> sources,
    required File target,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    FutureOr<bool> Function(File file)? validate,
    void Function(UpdateDownloadSource source, Object error)? onSourceFailure,
  }) async {
    if (sources.isEmpty) {
      throw const UpdateDownloadException('没有可用的下载源');
    }
    await target.parent.create(recursive: true);

    Object? lastError;
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      // 最后一个源不再因"慢"被中止：网络本身就慢的设备至少能下完。
      final allowSlowAbort = index < sources.length - 1;
      if (isCancelled?.call() ?? false) throw const DownloadCancelled();
      var attempt = 0;
      while (true) {
        final stopwatch = Stopwatch()..start();
        try {
          final bytes = await _trySource(
            source,
            target,
            onProgress: onProgress,
            isCancelled: isCancelled,
            allowSlowAbort: allowSlowAbort,
          );
          if (validate != null && !await validate(target)) {
            lastError = const UpdateDownloadException('安装包校验失败');
            await _safeDelete(target);
            await _safeDelete(File('${target.path}.part'));
            await _deleteSegments(target);
            onSourceFailure?.call(source, lastError);
            break; // 坏包不重试，直接换源。
          }
          return DownloadResult(source: source, bytes: bytes);
        } on DownloadCancelled {
          rethrow;
        } catch (error) {
          lastError = error;
          if (error is DownloadTooSlow ||
              attempt >= 1 ||
              stopwatch.elapsed >= fastFailureWindow) {
            onSourceFailure?.call(source, error);
            break;
          }
          attempt++;
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    throw UpdateDownloadException('所有下载源都失败', cause: lastError);
  }

  Future<int> _trySource(
    UpdateDownloadSource source,
    File target, {
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    bool allowSlowAbort = true,
  }) async {
    final info = await _remoteInfo(source.url);
    final legacyPart = File('${target.path}.part');
    final legacyLength = await _lengthOf(legacyPart);

    if (info.total != null && info.acceptRanges) {
      final total = info.total!;
      if (total >= minSegmentBytes * 2) {
        // 旧的整文件 `.part` 是上一版单连接下载留下的：继续用它，
        // 否则用户已经下到的进度会白扔。
        if (legacyLength == 0 && maxConnections > 1) {
          try {
            return await _downloadSegmented(
              source,
              target,
              total,
              onProgress: onProgress,
              isCancelled: isCancelled,
              allowSlowAbort: allowSlowAbort,
            );
          } on _RangeNotSupported {
            await _deleteSegments(target);
          }
        }
      }
    }

    // 单连接模式不能和分片文件混用（字节区间对不上）。
    await _deleteSegments(target);
    return _downloadSingle(
      source,
      target,
      info,
      onProgress: onProgress,
      isCancelled: isCancelled,
      allowSlowAbort: allowSlowAbort,
    );
  }

  // ---------------- 分片 ----------------

  Future<int> _downloadSegmented(
    UpdateDownloadSource source,
    File target,
    int total, {
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    bool allowSlowAbort = true,
  }) async {
    final count = math.min(
      maxConnections,
      math.max(1, total ~/ minSegmentBytes),
    );
    final segmentSize = (total / count).ceil();
    final client = _newClient();
    final session = _DownloadSession(
      total: total,
      client: client,
      source: source,
      onProgress: onProgress,
      isCancelled: isCancelled,
      progressInterval: progressInterval,
      slowWindow: slowWindow,
      minSpeedBps: minSpeedBps,
      idleTimeout: idleTimeout,
      allowSlowAbort: allowSlowAbort,
    );

    Object? firstError;
    try {
      final tasks = <Future<void>>[];
      for (var index = 0; index < count; index++) {
        final from = index * segmentSize;
        if (from >= total) break;
        final to = math.min((index + 1) * segmentSize, total) - 1;
        tasks.add(
          _downloadSegment(
            session,
            source.url,
            File('${target.path}.part$index'),
            from,
            to,
          ).catchError((Object error) {
            firstError ??= error;
            session.abort(error);
          }),
        );
      }
      await Future.wait(tasks);
      if (firstError != null) throw firstError!;
    } finally {
      session.flush();
      session.dispose();
      client.close(force: true);
    }

    final parts = <File>[
      for (var index = 0; index < count; index++)
        File('${target.path}.part$index'),
    ];
    await _mergeSegments(target, parts);
    return total;
  }

  Future<void> _downloadSegment(
    _DownloadSession session,
    String url,
    File file,
    int from,
    int to,
  ) async {
    final expected = to - from + 1;
    var length = await _lengthOf(file);
    if (length > expected) {
      await _safeDelete(file);
      length = 0;
    }
    if (length == expected) return;

    final start = from + length;
    final request = await session.client.getUrl(Uri.parse(url));
    _applyCommonHeaders(request);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$to');
    final response =
        await request.close().timeout(responseTimeout, onTimeout: () {
      throw const _RangeNotSupported();
    });

    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await response.drain<void>();
      if (length == expected) return;
      await _safeDelete(file);
      throw const _RangeNotSupported();
    }
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw const _RangeNotSupported();
    }
    if (!_rangeStartsAt(
      response.headers.value(HttpHeaders.contentRangeHeader),
      start,
    )) {
      await response.drain<void>();
      throw const _RangeNotSupported();
    }

    final sink = file.openWrite(
      mode: length > 0 ? FileMode.append : FileMode.write,
    );
    var written = length;
    try {
      await for (final chunk in response) {
        final error = session.error;
        if (error != null) throw error;
        sink.add(chunk);
        written += chunk.length;
        session.add(chunk.length);
      }
      await sink.flush();
    } catch (error) {
      // 看门狗/取消会直接断开连接，socket 异常要还原成真正的失败原因。
      final reason = session.error;
      if (reason != null) throw reason;
      rethrow;
    } finally {
      await sink.close();
    }
    if (written != expected) {
      throw UpdateDownloadException(
        '分片 $from-$to 未下完（$written/$expected）',
      );
    }
  }

  Future<void> _mergeSegments(File target, List<File> parts) async {
    await _safeDelete(target);
    final sink = target.openWrite();
    try {
      for (final part in parts) {
        if (!await part.exists()) {
          throw UpdateDownloadException('分片缺失：${part.path}');
        }
        await sink.addStream(part.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    for (final part in parts) {
      await _safeDelete(part);
    }
  }

  // ---------------- 单连接 ----------------

  Future<int> _downloadSingle(
    UpdateDownloadSource source,
    File target,
    _RemoteInfo info, {
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    bool allowSlowAbort = true,
    bool retried = false,
  }) async {
    final part = File('${target.path}.part');
    var start = await _lengthOf(part);
    if (info.total != null && start > info.total!) {
      await _safeDelete(part);
      start = 0;
    }
    if (info.total != null && start == info.total! && start > 0) {
      // 上次已经下满只是没改名：直接复用，不再发请求。
      await _safeDelete(target);
      await part.rename(target.path);
      return start;
    }

    final client = _newClient();
    _DownloadSession? session;
    try {
      final request = await client.getUrl(Uri.parse(source.url));
      _applyCommonHeaders(request);
      if (start > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      }
      final response =
          await request.close().timeout(responseTimeout, onTimeout: () {
        throw const UpdateDownloadException('下载响应超时');
      });

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          start > 0 &&
          !retried) {
        await response.drain<void>();
        await _safeDelete(part);
        return await _downloadSingle(
          source,
          target,
          info,
          onProgress: onProgress,
          isCancelled: isCancelled,
          allowSlowAbort: allowSlowAbort,
          retried: true,
        );
      }
      final append =
          start > 0 && response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw UpdateDownloadException('HTTP ${response.statusCode}');
      }
      if (!append) start = 0;

      final total = info.total ??
          (response.contentLength > 0
              ? response.contentLength + (append ? start : 0)
              : 0);
      final active = _DownloadSession(
        total: total,
        client: client,
        source: source,
        onProgress: onProgress,
        isCancelled: isCancelled,
        progressInterval: progressInterval,
        slowWindow: slowWindow,
        minSpeedBps: minSpeedBps,
        idleTimeout: idleTimeout,
        allowSlowAbort: allowSlowAbort,
        initialReceived: start,
      );
      session = active;

      final sink =
          part.openWrite(mode: append ? FileMode.append : FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response) {
          final error = active.error;
          if (error != null) throw error;
          sink.add(chunk);
          received += chunk.length;
          active.add(chunk.length);
        }
        await sink.flush();
      } catch (error) {
        // 看门狗/取消会直接断开连接，socket 异常要还原成真正的失败原因。
        final reason = active.error;
        if (reason != null) throw reason;
        rethrow;
      } finally {
        await sink.close();
      }

      if (total > 0 && start + received < total) {
        throw UpdateDownloadException(
          '下载中断（${start + received}/$total）',
        );
      }
      final bytes = start + received;
      await _safeDelete(target);
      await part.rename(target.path);
      return bytes;
    } finally {
      session?.flush();
      session?.dispose();
      client.close(force: true);
    }
  }

  // ---------------- 探测 / 工具 ----------------

  Future<_RemoteInfo> _remoteInfo(String url) async {
    final cached = _infoCache[url];
    if (cached != null) return cached;
    final client = _newClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      _applyCommonHeaders(request);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response = await request.close().timeout(probeTimeout);
      final status = response.statusCode;
      int? total;
      if (status == HttpStatus.partialContent) {
        total = _contentRangeTotal(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
      } else if (status == HttpStatus.ok && response.contentLength > 0) {
        total = response.contentLength;
      }
      // 不能 drain：服务端忽略 Range 时这里会读到**整个安装包**。
      // 头信息已经拿到，直接交给 finally 强制断开（不监听 body）。
      final info = _RemoteInfo(
        total: total,
        acceptRanges: status == HttpStatus.partialContent,
      );
      // 只有拿到确定信息才缓存：临时失败下次还要重新探。
      if (info.total != null) _infoCache[url] = info;
      return info;
    } catch (_) {
      return const _RemoteInfo();
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _newClient() => _clientFactory()
    ..connectionTimeout = connectTimeout
    ..maxConnectionsPerHost = math.max(maxConnections, 1) + 1;

  static void _applyCommonHeaders(HttpClientRequest request) {
    request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  }

  static bool _rangeStartsAt(String? contentRange, int expectedStart) {
    if (contentRange == null) return false;
    final match =
        RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(contentRange.trim());
    if (match == null) return false;
    return int.tryParse(match.group(1)!) == expectedStart;
  }

  static int? _contentRangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    final match =
        RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(contentRange.trim());
    if (match == null) return null;
    return int.tryParse(match.group(3)!);
  }

  static Future<int> _lengthOf(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static Future<void> _deleteSegments(File target) async {
    for (var index = 0; index < 16; index++) {
      final file = File('${target.path}.part$index');
      if (await file.exists()) await _safeDelete(file);
    }
  }
}

/// 服务端回 200（忽略 Range）或分片请求不可用：本次降级为单连接。
class _RangeNotSupported implements Exception {
  const _RangeNotSupported();
}

class _RemoteInfo {
  const _RemoteInfo({this.total, this.acceptRanges = false});

  final int? total;
  final bool acceptRanges;
}

/// 一次下载（一个源）的共享状态：进度聚合、速度采样、看门狗。
class _DownloadSession {
  _DownloadSession({
    required this.total,
    required this.client,
    required this.source,
    required this.progressInterval,
    required this.slowWindow,
    required this.minSpeedBps,
    required this.idleTimeout,
    this.onProgress,
    this.isCancelled,
    this.allowSlowAbort = true,
    int initialReceived = 0,
  }) : _received = initialReceived {
    _clock.start();
    _lastDataAt = 0;
    _timer = Timer.periodic(progressInterval, (_) => _tick());
  }

  final int total;
  final HttpClient client;
  final UpdateDownloadSource source;
  final Duration progressInterval;
  final Duration slowWindow;
  final int minSpeedBps;
  final Duration idleTimeout;

  final void Function(DownloadProgress progress)? onProgress;
  final bool Function()? isCancelled;

  /// 最后一个候选源不再因"慢"被中止（慢网设备至少能下完）。
  final bool allowSlowAbort;
  final Stopwatch _clock = Stopwatch();
  final List<(int, int)> _samples = <(int, int)>[];

  Timer? _timer;
  int _received;
  int _lastDataAt = 0;
  Object? _error;
  bool _onProgressFlushed = false;

  int get received => _received;

  /// 看门狗中止原因；各下载任务把它当作当前请求的异常抛出。
  Object? get error => _error;

  void add(int bytes) {
    if (bytes <= 0) return;
    _received += bytes;
    _lastDataAt = _clock.elapsedMilliseconds;
  }

  void abort(Object error) {
    if (_error != null) return;
    _error = error;
    // 关闭连接让阻塞在 socket 上的读取立刻退出。
    client.close(force: true);
  }

  /// 结束前补发一次最终进度（下载可能在第一个 200ms 采样前就完成了）。
  void flush() {
    if (_onProgressFlushed) return;
    _onProgressFlushed = true;
    _emit();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    if (_error != null) return;
    final now = _clock.elapsedMilliseconds;
    if (isCancelled?.call() ?? false) {
      abort(const DownloadCancelled());
      return;
    }

    _samples.add((now, _received));
    while (_samples.length > 2 && now - _samples.first.$1 > 2000) {
      _samples.removeAt(0);
    }

    if (total > 0 && _received >= total) return;

    final idle = now - _lastDataAt;
    if (_lastDataAt > 0 && idle > idleTimeout.inMilliseconds) {
      abort(DownloadTooSlow(source: source, speedBps: 0));
      return;
    }
    if (_lastDataAt == 0 && now > idleTimeout.inMilliseconds) {
      abort(DownloadTooSlow(source: source, speedBps: 0));
      return;
    }
    if (allowSlowAbort && now >= slowWindow.inMilliseconds) {
      final speed = speedOver(slowWindow);
      if (speed < minSpeedBps) {
        abort(DownloadTooSlow(source: source, speedBps: speed));
        return;
      }
    }
    _emit();
  }

  /// 最近 [window] 的平均速度（B/s）。样本不足时用整段平均。
  double speedOver(Duration window) {
    final now = _clock.elapsedMilliseconds;
    final from = now - window.inMilliseconds;
    var baseMs = 0;
    var baseBytes = 0;
    for (final sample in _samples) {
      if (sample.$1 <= from) {
        baseMs = sample.$1;
        baseBytes = sample.$2;
      } else {
        break;
      }
    }
    final elapsed = now - baseMs;
    if (elapsed <= 0) return 0;
    return (_received - baseBytes) * 1000 / elapsed;
  }

  void _emit() {
    onProgress?.call(
      DownloadProgress(
        received: _received,
        total: total,
        bytesPerSecond: speedOver(const Duration(seconds: 1)),
      ),
    );
  }
}
