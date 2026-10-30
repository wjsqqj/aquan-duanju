import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'spider_async_rewrite.dart';

/// CatVod JS 爬虫运行时：QuickJS 内嵌 + 宿主 API 桥接。
///
/// 核心约束：QuickJS 执行阻塞 Dart 事件循环，纯 Dart 无法同步等 IO——
/// 因此对爬虫源码做 async 改写（`SpiderAsyncRewrite.rewriteModule`），宿主
/// API 全部返回 Promise，配合 evaluateAsync 让 `await req(...)` 自然衔接。
///
/// 每个爬虫源 eval 进**独立命名空间**（按内容哈希键控，多源同名函数互不干扰），
/// 调用时按 `key:fn` 从命名空间取 async 函数执行。
class SpiderJsRuntime {
  SpiderJsRuntime._();

  static final SpiderJsRuntime instance = SpiderJsRuntime._();

  JavascriptRuntime? _runtime;
  bool _ready = false;
  final Set<String> _loadedKeys = <String>{};

  /// localStorage 壳（spider 源间共享，会话级）。
  final Map<String, String> _localStore = {};
  String? _lastResult;

  /// 调用串行锁：QuickJS 单线程执行，且 `spSetResult` 写的是**全局槽位**，
  /// 并发调用会互相覆盖结果（多 spider 源并行搜索时出现串结果）。
  Future<void> _callLock = Future<void>.value();

  static const _callTimeout = Duration(seconds: 30);

  /// 串行执行：前一个调用结束（或失败）后才开始下一个。
  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _callLock;
    // 锁本身吞掉异常：后续调用不该因为前一次失败而卡住。
    _callLock = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  // ---------- 生命周期 ----------

  Future<void> _ensure() async {
    if (_ready) return;
    final runtime = _runtime = getJavascriptRuntime();
    // ignore: invalid_use_of_protected_member
    runtime.init(); // console/setTimeout 桥接。
    // ignore: invalid_use_of_protected_member
    runtime.initChannelFunctions(); // 注入 sendMessage（必须先于 onMessage）。

    // spReq：异步 HTTP（回调 async → JS 侧 Promise）。
    runtime.onMessage('spReq', (args) async {
      final opts = args is Map ? args : <String, dynamic>{};
      final url = opts['url']?.toString() ?? '';
      if (url.isEmpty) return jsonEncode({'body': '', 'statusCode': 0});
      try {
        final method = (opts['method']?.toString() ?? 'GET').toUpperCase();
        final headers = <String, String>{
          if (opts['headers'] is Map)
            for (final e in (opts['headers'] as Map).entries)
              e.key.toString(): e.value.toString(),
        };
        final body = opts['body']?.toString();
        final client = http.Client();
        try {
          late final http.Response res;
          if (method == 'POST') {
            res = await client
                .post(Uri.parse(url), headers: headers, body: body ?? '')
                .timeout(const Duration(seconds: 15));
          } else {
            res = await client
                .get(Uri.parse(url), headers: headers)
                .timeout(const Duration(seconds: 15));
          }
          return jsonEncode({
            'body': utf8.decode(res.bodyBytes, allowMalformed: true),
            'statusCode': res.statusCode,
          });
        } finally {
          client.close();
        }
      } catch (e) {
        return jsonEncode({'body': '', 'statusCode': 0, 'error': '$e'});
      }
    });

    // spPdfa：列表提取（每项一个字符串，JSON 数组回流）。
    runtime.onMessage('spPdfa', (args) {
      return jsonEncode(
          {'v': pdfa(_arg(args, 'html'), _arg(args, 'rule'))});
    });

    // spPdfh / spPd：CatVod $$ 规则常用子集（Dart html 包 DOM 解析）。
    runtime.onMessage('spPdfh', (args) {
      return jsonEncode(
          {'v': pdfh(_arg(args, 'html'), _arg(args, 'rule'))});
    });
    runtime.onMessage('spPd', (args) {
      return jsonEncode({
        'v': pd(_arg(args, 'html'), _arg(args, 'rule'), _arg(args, 'baseUrl'))
      });
    });

    // spSetResult：捕获爬虫结果。
    runtime.onMessage('spSetResult', (args) {
      _lastResult = args is String ? args : jsonEncode(args);
      return _lastResult;
    });

    // spLocal：localStorage 壳。
    runtime.onMessage('spLocal', (args) {
      final map = args is Map ? args : <String, dynamic>{};
      final op = map['op']?.toString() ?? '';
      final key = map['key']?.toString() ?? '';
      if (op == 'get') return _localStore[key] ?? '';
      if (op == 'set') {
        _localStore[key] = map['value']?.toString() ?? '';
      }
      return '';
    });

    // 注入宿主 API JS 侧垫片。
    runtime.evaluate(_hostShim);
    _ready = true;
  }

  /// 泵 QuickJS 微任务队列直到 [value] 完成（宿主 await 依赖 pending job 推进）。
  Future<String> _pumpUntil(Future value) async {
    var completed = false;
    String result = '';
    Object? error;
    value.then((v) {
      result = v?.toString() ?? '';
    }, onError: (Object e) {
      error = e;
    }).whenComplete(() {
      completed = true;
    });
    final deadline = DateTime.now().add(_callTimeout);
    while (!completed && DateTime.now().isBefore(deadline)) {
      _runtime!.executePendingJob();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (error != null) {
      throw Exception('spider 执行异常: $error');
    }
    if (!completed) {
      // 超时必须显式失败：静默返回空串会被上层当成「没有结果」。
      throw SpiderTimeoutException(
          'spider 调用超时（${_callTimeout.inSeconds}s）');
    }
    return result;
  }

  static String _arg(dynamic args, String key) =>
      args is Map ? args[key]?.toString() ?? '' : '';

  /// 宿主 API 垫片：req/pdfh/pd/setResult/local 全部经 sendMessage 通道。
  static final _hostShim = '''
function spNormalize(v) { return typeof v === 'string' ? JSON.parse(v) : v; }
async function req(options) {
  if (typeof options === 'string') options = {url: options};
  return spNormalize(await sendMessage('spReq', JSON.stringify(options)));
}
async function getHtml(options) { return (await req(options)).body; }
async function pdfh(html, rule) {
  return spNormalize(await sendMessage('spPdfh', JSON.stringify({html, rule})));
}
async function pdfa(html, rule) {
  return spNormalize(await sendMessage('spPdfa', JSON.stringify({html, rule})));
}
async function pd(html, rule, baseUrl) {
  return spNormalize(await sendMessage('spPd', JSON.stringify({html, rule, baseUrl})));
}
function setResult(obj) {
  return sendMessage('spSetResult', typeof obj === 'string' ? obj : JSON.stringify(obj));
}
function setHomeResult(obj) { return setResult(obj); }
function setCategory(obj) { return setResult(obj); }
function setDetail(obj) { return setResult(obj); }
function joinUrl(base, rel) {
  if (!rel) return '';
  if (/^https?:/.test(rel)) return rel;
  if (base.slice(-1) === '/') base = base.slice(0, -1);
  if (rel.charAt(0) === '/') rel = rel.slice(1);
  return base + '/' + rel;
}
var local = {
  get: function(k) { return sendMessage('spLocal', JSON.stringify({op:'get',key:k})); },
  set: function(k, v) { return sendMessage('spLocal', JSON.stringify({op:'set',key:k,value:v})); },
};
''';

  /// CatVod 入口函数名（加载时快照到命名空间）。
  static const _entryFns = [
    'init', 'home', 'homeContent', 'category', 'categoryContent',
    'detail', 'detailContent', 'search', 'searchContent',
    'play', 'playerContent', 'liveContent', 'proxy',
  ];

  // ---------- 爬虫调用 ----------

  /// 调用爬虫函数：[jsSource] 源码（按内容哈希只加载一次）、[fn] 入口名
  /// （homeContent/categoryContent/detailContent/searchContent/playerContent）、
  /// [args] 位置参数。返回 CatVod 结果对象（setResult 捕获优先于返回值）。
  Future<Map<String, dynamic>> call(
      String jsSource, String fn, List<Object?> args) {
    // 整个调用（含运行时初始化）串行执行：`_lastResult` 是全局槽位，
    // 并发调用会互相覆盖（多 spider 源并行搜索时串结果）。
    return _serial(() async {
      await _ensure();
      final key =
          'sp${md5.convert(utf8.encode(jsSource)).toString().substring(0, 12)}';
      if (!_loadedKeys.contains(key)) {
        final module = SpiderAsyncRewrite.rewriteModule(jsSource);
        final snapshot = _entryFns
            .map((n) => "try { if (typeof $n === 'function') ns['$n'] = $n; } catch(e) {}")
            .join('\n');
        final loadResult = _runtime!.evaluate('''
(function(){
$module
globalThis.__sp = globalThis.__sp || {};
var ns = {};
$snapshot
globalThis.__sp["$key"] = ns;
})();
''');
        if (loadResult.isError) {
          // 加载失败**不能**把 key 记进 _loadedKeys：否则下次直接跳过加载，
          // 报成「函数不存在」，这个源被永久判死且不再重试。
          throw SpiderLoadException(
              'spider 加载失败: ${loadResult.stringResult}');
        }
        _loadedKeys.add(key);
      }
      _lastResult = null;
      final argsJson = jsonEncode(args);
      final res = _runtime!.evaluate('''
(async () => {
  var ns = (globalThis.__sp && globalThis.__sp["$key"]) || {};
  var f = ns["$fn"];
  if (typeof f !== 'function') {
    return JSON.stringify({__ok: false, __error: "函数 $fn 不存在"});
  }
  var r = await f(...$argsJson);
  return JSON.stringify({__ok: true, __data: r === undefined ? null : r});
})().catch(e => JSON.stringify({__ok: false, __error: String(e)}));
''');

      String raw;
      final rawResult = res.rawResult;
      if (rawResult is Future) {
        // Promise → Dart Future：必须手动泵 QuickJS 微任务队列才算推进。
        raw = await _pumpUntil(rawResult);
      } else {
        raw = res.stringResult;
      }
      return _parseResult(_lastResult ?? raw);
    });
  }

  Map<String, dynamic> _parseResult(String raw) {
    if (raw.isEmpty || raw == 'undefined' || raw == 'null') return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      if (decoded['__ok'] == false) {
        throw Exception('spider 执行失败: ${decoded['__error']}');
      }
      final data = decoded['__data'];
      if (data is Map) {
        return data.map((k, v) => MapEntry(k.toString(), v));
      }
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } on FormatException {
      return {};
    }
  }

  // ---------- CatVod pdfh/pd（Dart html 包实现） ----------

  /// CatVod $$ 规则常用子集：`body&&.item&&a&&Text`——`&&` 分段，末段为
  /// 属性关键字（Text/text/href/src/...）时从元素提取，否则按选择器再选。
  static String pdfh(String htmlText, String rule) {
    if (htmlText.isEmpty || rule.isEmpty) return '';
    final doc = html_parser.parse(htmlText);
    final parts = rule
        .split('&&')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    dynamic el = doc;
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i];
      final low = seg.toLowerCase();
      final isLast = i == parts.length - 1;
      final isAttr =
          attrKeys.contains(low) || low.startsWith('data-');
      if (isLast && isAttr) {
        if (low == 'text' || low == 'textall') return _textOf(el).trim();
        if (low == 'html') return _innerHtmlOf(el);
        return _attrOf(el, low) ?? _attrOf(el, seg) ?? '';
      }
      el = _query(el, seg);
      if (el == null) return '';
    }
    return _textOf(el).trim();
  }

  /// CatVod pdfa：列表提取。规则末段为属性关键字时逐元素提取，否则取文本。
  static List<String> pdfa(String htmlText, String rule) {
    if (htmlText.isEmpty || rule.isEmpty) return const [];
    final doc = html_parser.parse(htmlText);
    final parts = rule
        .split('&&')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return const [];
    final last = parts.last.toLowerCase();
    final isAttr = attrKeys.contains(last) || last.startsWith('data-');
    final selectors = isAttr ? parts.sublist(0, parts.length - 1) : parts;
    if (selectors.isEmpty) return const [];
    dynamic scope = doc;
    for (var i = 0; i < selectors.length - 1; i++) {
      scope = _query(scope, selectors[i]);
      if (scope == null) return const [];
    }
    List<dynamic> elements;
    try {
      elements = scope.querySelectorAll(selectors.last).toList();
    } catch (_) {
      return const [];
    }
    final out = <String>[];
    for (final el in elements) {
      if (!isAttr) {
        out.add(_textOf(el).trim());
      } else if (last == 'text' || last == 'textall') {
        out.add(_textOf(el).trim());
      } else if (last == 'html') {
        out.add(_innerHtmlOf(el));
      } else {
        final v = _attrOf(el, last);
        if (v != null && v.isNotEmpty) out.add(v);
      }
    }
    return out;
  }

  /// pd：pdfh 结果按 baseUrl 转绝对地址。
  static String pd(String htmlText, String rule, String baseUrl) {
    final v = pdfh(htmlText, rule);
    if (v.isEmpty || baseUrl.isEmpty) return v;
    final base = Uri.tryParse(baseUrl);
    if (base == null) return v;
    try {
      return base.resolve(v).toString();
    } catch (_) {
      return v;
    }
  }

  static const attrKeys = {
    'text', 'textall', 'html', 'href', 'src', 'title', 'alt', 'value',
    'content', 'id', 'class',
  };

  static dynamic _query(dynamic el, String selector) {
    try {
      return el.querySelector(selector);
    } catch (_) {
      return null;
    }
  }

  static String _textOf(dynamic el) {
    try {
      return el?.text?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  static String _innerHtmlOf(dynamic el) {
    try {
      return el?.innerHtml?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  static String? _attrOf(dynamic el, String name) {
    try {
      return el?.attributes?[name]?.toString();
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
    _ready = false;
    _loadedKeys.clear();
  }
}

/// 爬虫脚本加载失败（JS 语法/求值错误）。
///
/// 与「函数调用失败」区分：加载失败是可以重试的（网络抖动、脚本更新），
/// 调用失败通常是源本身的问题。适配器据此给不同错误码。
class SpiderLoadException implements Exception {
  SpiderLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 爬虫调用超时（宿主 Promise 在时限内没有完成）。
class SpiderTimeoutException implements Exception {
  SpiderTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}
