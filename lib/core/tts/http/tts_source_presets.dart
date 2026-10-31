/// 官方云 TTS 的**预设模板**：把常见服务商接成一份可粘贴的 JSON。
///
/// 为什么是「模板」而不是「内置引擎」：这些服务的鉴权、字段、音色列表各自演进，
/// 硬编码成引擎意味着每加一家都要改代码、加依赖、过审。而声明式模板 + 调试台
/// 让用户填个 key 就能用，服务商改了字段也只是改一段 JSON。
///
/// **诚实声明**：模板按各服务商公开文档编写，字段可能随后续版本变化；
/// 填完 key 请先用设置页的「测试 HTTP 源」核对状态码与音频时长。
library;

/// 一份预设：展示名 + 一段可直接落进源列表的 JSON。
class TtsSourcePreset {
  const TtsSourcePreset({
    required this.key,
    required this.name,
    required this.hint,
    required this.json,
  });

  /// 稳定标识（仅用于 UI 选择，不进缓存键）。
  final String key;
  final String name;

  /// 需要用户改哪些字段。
  final String hint;

  /// 与 `HttpTtsSource.tryParse` 同形的 JSON（中文占位就是待填项）。
  final String json;
}

/// 内置预设。顺序即设置页展示顺序：本地自建在前（零成本），云服务在后（需 key）。
const List<TtsSourcePreset> kTtsSourcePresets = <TtsSourcePreset>[
  TtsSourcePreset(
    key: 'local-tts-server',
    name: '本地 TTS 服务（GPT-SoVITS / tts-server）',
    hint: '把 url 换成你本机服务的地址；voice 可留空',
    json: r'''{
  "id": "local",
  "name": "本地 TTS",
  "url": "http://127.0.0.1:9880/tts?text={text}&voice={voice}",
  "method": "GET",
  "mode": "audio",
  "voices": []
}''',
  ),
  TtsSourcePreset(
    key: 'azure',
    name: 'Azure 语音（官方）',
    hint: '填 subscription key；url 里的区域改成你的（如 eastasia / eastus）',
    json: r'''{
  "id": "azure",
  "name": "Azure 语音",
  "url": "https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1",
  "method": "POST",
  "headers": {
    "Ocp-Apim-Subscription-Key": "在此填入 Azure 语音密钥",
    "Content-Type": "application/ssml+xml",
    "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3"
  },
  "body": "<speak version='1.0' xml:lang='zh-CN'><voice name='{voice}'>{text}</voice></speak>",
  "bodyEscape": "xml",
  "mode": "audio",
  "voices": [
    "zh-CN-XiaoxiaoNeural",
    "zh-CN-YunxiNeural",
    "zh-CN-XiaoyiNeural",
    "zh-CN-YunjianNeural"
  ],
  "bitrateKbps": 48
}''',
  ),
  TtsSourcePreset(
    key: 'volcengine',
    name: '火山引擎（豆包语音）',
    hint: '填 appid 与 access token（两处都要）；cluster 按你开通的版本改',
    json: r'''{
  "id": "volc",
  "name": "火山引擎 TTS",
  "url": "https://openspeech.bytedance.com/api/v1/tts",
  "method": "POST",
  "headers": {
    "Authorization": "Bearer;在此填入 access token",
    "Content-Type": "application/json"
  },
  "body": "{\"app\":{\"appid\":\"在此填入 appid\",\"token\":\"在此填入 access token\",\"cluster\":\"volcano_tts\"},\"user\":{\"uid\":\"aquan\"},\"audio\":{\"voice_type\":\"{voice}\",\"encoding\":\"mp3\",\"speed_ratio\":1.0},\"request\":{\"reqid\":\"aquan-listen\",\"text\":\"{text}\",\"operation\":\"query\"}}",
  "bodyEscape": "json",
  "mode": "jsonBase64",
  "audioField": "data",
  "voices": [
    "zh_female_shuangkuaisisi_moon_bigtts",
    "zh_male_yunzhou_jupiter_bigtts"
  ],
  "bitrateKbps": 48
}''',
  ),
  TtsSourcePreset(
    key: 'openai-compatible',
    name: 'OpenAI 兼容语音网关',
    hint: '把 url 换成你的网关地址，填 API key；voice 用网关支持的名字',
    json: r'''{
  "id": "openai-tts",
  "name": "OpenAI 兼容 TTS",
  "url": "https://your-gateway.example.com/v1/audio/speech",
  "method": "POST",
  "headers": {
    "Authorization": "Bearer 在此填入 API key",
    "Content-Type": "application/json"
  },
  "body": "{\"model\":\"tts-1\",\"voice\":\"{voice}\",\"input\":\"{text}\",\"response_format\":\"mp3\"}",
  "mode": "audio",
  "voices": ["alloy", "nova", "shimmer"],
  "bitrateKbps": 48
}''',
  ),
];

/// 按 key 找预设；未知 key 返回 null。
TtsSourcePreset? ttsSourcePresetByKey(String key) {
  for (final preset in kTtsSourcePresets) {
    if (preset.key == key) return preset;
  }
  return null;
}
