/// 搜索联想何时盖在结果之上（结果页二次搜索的回归锁）。
///
/// 旧实现只在「尚未提交过」时渲染联想：进结果页后再次输入，联想表虽然照常
/// 请求并落到 `_suggestions`，但结果分支先返回，永远看不到提示（用户实测）。
library;

/// 输入框里的词是否算「正在重新编辑」（与已提交词不同且非空）。
bool isEditingQuery(String input, String submitted) {
  final String trimmed = input.trim();
  return trimmed.isNotEmpty && trimmed != submitted;
}

/// 结果页是否该让联想顶到结果之上。
bool shouldShowSuggestions({
  required String input,
  required String submitted,
  required int suggestionCount,
}) =>
    isEditingQuery(input, submitted) && suggestionCount > 0;
