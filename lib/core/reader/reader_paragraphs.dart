/// 章节正文 → 显示段落的**唯一派生入口**。
///
/// 为什么单独成文件：朗读高亮的真值是「章内字符偏移」，而这套坐标只在
/// 「段落列表确定」之后才存在。阅读页与 [ReaderSpeechController] 如果各自清洗
/// 一遍（一个做了替换规则/简繁、一个没做），段数与偏移就会错开 —— 表现为
/// 「高亮偏段、词点指错字」，且不报错，事后极难定位
/// （`backend/listen-tts-contract.md` 已知偏差 CRITICAL-1）。
///
/// 因此链路顺序**固定**，与 `frontend/reader-paging-contract.md` §9.3 记录的应用点一致：
///
/// ```text
/// htmlToParagraphs → 去章标题 → applyReplaceRules → 简繁
/// ```
///
/// 任何一侧都不许再加减步骤：简繁转换以前是页面 getter 里做的，现在挪进这里，
/// 页面缓存的就是「完全派生」的列表。
library;

import '../book_text.dart';
import 'chinese_converter.dart';
import 'reader_settings.dart';
import 'replace_rules.dart';

/// 把章节 HTML 派生成「屏幕上显示、朗读也要念」的段落列表。
///
/// - [raw]：`chapterText` 拿到的 HTML 原文（未清洗）；
/// - [chapterTitle]：章节标题，正文首行与它相同时去掉（顶栏已经显示过）；
/// - [rules]：这本书实际生效的替换规则（调用方给 `store.forBook(bookId)`）；
/// - [convert]：简繁模式，[ChineseConvert.off] 时跳过转换。
///
/// 纯函数：不读全局状态、不修改入参、同样的输入必给同样的输出。
List<String> deriveDisplayParagraphs({
  required String raw,
  required String chapterTitle,
  required List<ReplaceRule> rules,
  required ChineseConvert convert,
}) {
  var paragraphs = htmlToParagraphs(raw);
  // 正文里常带一行章节标题：顶栏已经显示过，朗读也不该先念一遍。
  if (paragraphs.isNotEmpty && paragraphs.first == chapterTitle) {
    paragraphs = List<String>.of(paragraphs)..removeAt(0);
  }
  // 替换后为空的段落整段丢弃（否则分页会留下空行），这一步会顺带 trim。
  paragraphs = applyReplaceRules(paragraphs, rules);
  if (convert == ChineseConvert.off) return paragraphs;
  return [
    for (final paragraph in paragraphs)
      ChineseConverter.convert(paragraph, convert),
  ];
}

/// 段落下标 → 章内字符偏移（段落以 `'\n'` 相接，与分页器同一坐标系，
/// 见 `reader-paging-contract.md` §9.1：段首缩进只参与测量，不进入字符位）。
int paragraphCharOffset(List<String> paragraphs, int index) {
  if (paragraphs.isEmpty) return 0;
  final target = index.clamp(0, paragraphs.length - 1);
  var offset = 0;
  for (var i = 0; i < target; i++) {
    offset += paragraphs[i].length + 1;
  }
  return offset;
}

/// 某一段在章内的字符区间 `[start, end)`（不含分隔换行）。
(int, int)? paragraphCharRange(List<String> paragraphs, int index) {
  if (paragraphs.isEmpty) return null;
  final target = index.clamp(0, paragraphs.length - 1);
  final start = paragraphCharOffset(paragraphs, target);
  return (start, start + paragraphs[target].length);
}
