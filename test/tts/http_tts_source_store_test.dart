import 'dart:convert';

import 'package:aquan_duanju/core/tts/http/http_tts_source.dart';
import 'package:aquan_duanju/core/tts/http/http_tts_source_store.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多源列表：增删改选 + 旧单源迁移 + 脏数据容错。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<TtsSourceStore> storeWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return TtsSourceStore(await SharedPreferences.getInstance());
  }

  HttpTtsSource source(String id, {String name = ''}) => HttpTtsSource(
    id: id,
    name: name.isEmpty ? id : name,
    urlTemplate: 'http://h/$id?text={text}',
    voices: const [TtsVoice(id: 'zh-A')],
  );

  test('空配置：列表为空、active 为 null', () async {
    final store = await storeWith(<String, Object>{});
    expect(store.list(), isEmpty);
    expect(store.active, isNull);
  });

  test('旧单源键：list() 能兜底读到，ensureMigrated 后搬进列表并删旧键', () async {
    final legacy = source('old', name: '旧源');
    final store = await storeWith(<String, Object>{
      TtsSourceStore.legacyKey: jsonEncode(legacy.toJson()),
    });

    // 迁移前：兜底可见（断电也不丢）。
    expect(store.list().single.id, 'old');
    expect(store.active?.id, 'old');

    await store.ensureMigrated();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TtsSourceStore.legacyKey), isNull);
    expect(prefs.getString(TtsSourceStore.sourcesKey), contains('"old"'));
    expect(store.active?.id, 'old');
  });

  test('upsert 同 id 覆盖且保序；新增后自动选中（首次）', () async {
    final store = await storeWith(<String, Object>{});
    await store.upsert(source('a'));
    await store.upsert(source('b'));
    await store.upsert(source('a', name: '改过的 A'));

    final list = store.list();
    expect(list.map((s) => s.id).toList(), <String>['a', 'b'], reason: '不重复、保序');
    expect(list.first.name, '改过的 A', reason: '同 id 覆盖生效');
    expect(store.active?.id, 'a', reason: '首次添加自动选中');
  });

  test('select：切换选中；指向不存在的 id 时忽略（不写空气）', () async {
    final store = await storeWith(<String, Object>{});
    await store.upsert(source('a'));
    await store.upsert(source('b'));

    await store.select('b');
    expect(store.active?.id, 'b');

    await store.select('nope');
    expect(store.active?.id, 'b', reason: '非法 id 不许把选中项清空');
  });

  test('remove：删当前选中项 → 回落到第一条；删空 → active 为 null', () async {
    final store = await storeWith(<String, Object>{});
    await store.upsert(source('a'));
    await store.upsert(source('b'));
    await store.select('b');

    await store.remove('b');
    expect(store.list().map((s) => s.id).toList(), <String>['a']);
    expect(store.active?.id, 'a', reason: '回落到剩下的第一条');

    await store.remove('a');
    expect(store.list(), isEmpty);
    expect(store.active, isNull);
  });

  test('脏数据容错：坏条目被跳过、不抛；全坏时回落旧键', () async {
    final good = source('good');
    final store = await storeWith(<String, Object>{
      TtsSourceStore.sourcesKey: jsonEncode(<dynamic>[
        <String, dynamic>{'id': 'bad'}, // 缺 url
        'not-a-map',
        good.toJson(),
      ]),
    });
    expect(store.list().map((s) => s.id).toList(), <String>['good']);
    expect(store.active?.id, 'good', reason: '没有选中项时回落第一条');
  });

  test('toJson ↔ tryParse 往返：字段不丢（headers/body/voices/bitrate）', () {
    const original = HttpTtsSource(
      id: 'x',
      name: 'X',
      urlTemplate: 'https://h/tts?t={text}',
      method: 'POST',
      headers: <String, String>{'Authorization': 'Bearer k'},
      bodyTemplate: '{"text":"{text}"}',
      mode: HttpTtsResponseMode.jsonBase64,
      audioField: 'audio',
      voices: <TtsVoice>[TtsVoice(id: 'zh-A', displayName: '女声')],
      bitrateKbps: 64,
    );
    final back = HttpTtsSource.tryParse(jsonEncode(original.toJson()));
    expect(back, isNotNull);
    expect(back!.id, 'x');
    expect(back.method, 'POST');
    expect(back.headers['Authorization'], 'Bearer k');
    expect(back.bodyTemplate, '{"text":"{text}"}');
    expect(back.mode, HttpTtsResponseMode.jsonBase64);
    expect(back.audioField, 'audio');
    expect(back.voices.single.displayName, '女声');
    expect(back.bitrateKbps, 64);
  });
}
