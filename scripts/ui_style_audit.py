#!/usr/bin/env python3
"""UI 硬编码样式审计（`.trellis/tasks/11-13-ui-overhaul/design.md` §8 / AC4）。

扫描 `lib/**/*.dart`，统计 7 类「绕过设计 Token」的写法：

| 键 | 命中文本 | 说明 |
|---|---|---|
| `colors` | `Colors.` | Material 调色板直取（`AppColors.` 不算，见下） |
| `text_style` | `TextStyle(` | 就地构造文本样式 |
| `font_size` | `fontSize:` | 字号字面量 |
| `radius` | `BorderRadius.circular(` | 圆角字面量 |
| `edge_all` | `EdgeInsets.all(` | 全向间距 |
| `edge_sym` | `EdgeInsets.symmetric(` | 双向间距 |
| `sized_box` | `SizedBox(height:` + `SizedBox(width:` | 合并为一项 |

允许出现这些写法的位置（默认排除，不计入）：

- `lib/widgets/ui/` —— 基础组件层，是 Token 的唯一消费者封装
- `lib/theme/app_color.dart` —— 色板原始值（唯一允许 `Color(0x...)` 的地方）
- `lib/theme/player_overlay_theme.dart` —— 播放器 OSD 专用 Token

匹配是**纯文本**的：注释与字符串里的命中同样计数。规则越简单结果越可复现，
代价是写注释时要避开这些片段。`colors` 用 `(?<![A-Za-z0-9_])` 边界排除
`AppColors.`（Token 类名），否则 Token 用得多反而让这项计数虚高。

用法：
    python scripts/ui_style_audit.py
        人读报告；`scripts/ui_style_baseline.json` 不存在时自动写入基线。
    python scripts/ui_style_audit.py --json
        机器可读输出（提示信息走 stderr，stdout 只有 JSON）。
    python scripts/ui_style_audit.py --compare scripts/ui_style_baseline.json
        逐项对比基线；任一项增加则以退出码 1 结束。
    python scripts/ui_style_audit.py --write-baseline scripts/ui_style_baseline.json
        把当前统计写成新的基线。

退出码：0 正常 / 无增加；1 对比发现增加；2 基线文件不可读。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB_DIR = "lib"
DEFAULT_BASELINE = "scripts/ui_style_baseline.json"

# 规则顺序即输出顺序；键名会出现在 JSON 里，改动即为不兼容变更。
RULES: tuple[tuple[str, str, str], ...] = (
    # (键, 展示名, 正则)
    ("colors", "Colors.*", r"(?<![A-Za-z0-9_])Colors\."),
    ("text_style", "TextStyle(", r"TextStyle\("),
    ("font_size", "fontSize:", r"fontSize:"),
    ("radius", "BorderRadius.circular(", r"BorderRadius\.circular\("),
    ("edge_all", "EdgeInsets.all(", r"EdgeInsets\.all\("),
    ("edge_sym", "EdgeInsets.symmetric(", r"EdgeInsets\.symmetric\("),
    ("sized_box", "SizedBox(height|width:", r"SizedBox\((?:height|width):"),
)

EXCLUDED_DIRS = ("lib/widgets/ui/",)
EXCLUDED_FILES = (
    "lib/theme/app_color.dart",
    "lib/theme/player_overlay_theme.dart",
)

_COMPILED = tuple((key, label, re.compile(pattern)) for key, label, pattern in RULES)


def _setup_console() -> None:
    """统一用 UTF-8 输出（Windows 控制台默认 cp936 会让 `--json > x.json` 变成 GBK）。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (ValueError, OSError):  # 已被重定向到不支持改编码的对象
            pass


def _rel(path: Path) -> str:
    """仓库根相对路径，统一用 `/`（跨平台输出稳定）。"""
    return path.relative_to(REPO).as_posix()


def _excluded(rel_path: str) -> bool:
    if rel_path in EXCLUDED_FILES:
        return True
    return any(rel_path.startswith(d) for d in EXCLUDED_DIRS)


def scan() -> dict:
    """返回 {"rules": {...}, "totals": {...}, "files": {rel: {key: n}}}。"""
    totals = {key: 0 for key, _, _ in _COMPILED}
    files: dict[str, dict[str, int]] = {}

    for path in sorted((REPO / LIB_DIR).rglob("*.dart")):
        rel = _rel(path)
        if _excluded(rel):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        counts: dict[str, int] = {}
        for key, _, pattern in _COMPILED:
            n = len(pattern.findall(text))
            if n:
                counts[key] = n
                totals[key] += n
        if counts:
            files[rel] = counts

    return {
        "root": LIB_DIR,
        "rules": {
            key: {"label": label, "pattern": pattern}
            for key, label, pattern in RULES
        },
        "totals": totals,
        "files": files,
    }


def _grand_total(totals: dict) -> int:
    return sum(totals.values())


def print_report(result: dict) -> None:
    totals = result["totals"]
    files = result["files"]
    labels = {key: label for key, label, _ in RULES}

    print(f"UI 样式硬编码审计 · {result['root']}/**/*.dart")
    print(f"排除：{', '.join(EXCLUDED_FILES + EXCLUDED_DIRS)}")
    print()
    print(f"{'规则':<28}{'命中文本':<34}{'全库总数':>8}")
    print("-" * 72)
    for key, _, _ in _COMPILED:
        print(f"{key:<28}{labels[key]:<34}{totals[key]:>8}")
    print("-" * 72)
    print(f"{'合计':<28}{'':<34}{_grand_total(totals):>8}")
    print()

    if not files:
        print("（没有任何命中）")
        return

    ordered = sorted(
        files.items(), key=lambda kv: (-_grand_total(kv[1]), kv[0])
    )
    keys = [key for key, _, _ in _COMPILED]
    header = "".join(f"{k[:8]:>9}" for k in keys)
    print(f"{'文件':<58}{header}{'合计':>9}")
    print("-" * (58 + 9 * len(keys) + 9))
    for rel, counts in ordered:
        row = "".join(f"{counts.get(k, 0):>9}" for k in keys)
        print(f"{rel:<58}{row}{_grand_total(counts):>9}")
    print()
    print(f"有命中的文件：{len(files)} 个")


def write_baseline(result: dict, path: Path) -> None:
    payload = {
        "root": result["root"],
        "rules": result["rules"],
        "totals": result["totals"],
        "files": result["files"],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def load_baseline(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    totals = data.get("totals")
    if not isinstance(totals, dict):
        raise ValueError(f"基线文件缺少 totals 字段：{path}")
    return totals


def compare(result: dict, baseline_totals: dict) -> tuple[list[dict], int]:
    """返回 (每项差值, 增加项数)。差值为正表示相对基线增加。"""
    rows = []
    increased = 0
    for key, label, _ in _COMPILED:
        base = int(baseline_totals.get(key, 0))
        now = int(result["totals"].get(key, 0))
        delta = now - base
        if delta > 0:
            increased += 1
        rows.append(
            {"rule": key, "label": label, "baseline": base, "current": now, "delta": delta}
        )
    return rows, increased


def print_compare(rows: list[dict], increased: int) -> None:
    print(f"{'规则':<28}{'基线':>8}{'当前':>8}{'差值':>8}")
    print("-" * 52)
    base_total = cur_total = 0
    for row in rows:
        base_total += row["baseline"]
        cur_total += row["current"]
        print(
            f"{row['rule']:<28}{row['baseline']:>8}{row['current']:>8}"
            f"{row['delta']:>+8}"
        )
    print("-" * 52)
    print(f"{'合计':<28}{base_total:>8}{cur_total:>8}{cur_total - base_total:>+8}")
    print()
    if increased:
        print(f"[增量] 有 {increased} 项相对基线增加（正数 = 新增硬编码）。")
    else:
        print("[OK] 没有任何一项相对基线增加。")


def main(argv: list[str] | None = None) -> int:
    _setup_console()
    parser = argparse.ArgumentParser(
        description="统计 lib/**/*.dart 中绕过设计 Token 的样式字面量。",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="输出机器可读 JSON（stdout 只有 JSON）。",
    )
    parser.add_argument(
        "--compare",
        metavar="BASELINE",
        help="与基线 JSON 对比，输出每项差值；有增加时退出码为 1。",
    )
    parser.add_argument(
        "--write-baseline",
        metavar="PATH",
        help="把当前统计写成基线文件（默认路径 scripts/ui_style_baseline.json）。",
    )
    parser.add_argument(
        "--baseline-path",
        default=DEFAULT_BASELINE,
        metavar="PATH",
        help=f"默认基线路径（缺省 {DEFAULT_BASELINE}）。",
    )
    args = parser.parse_args(argv)

    result = scan()
    exit_code = 0

    if args.compare:
        try:
            baseline_totals = load_baseline(Path(args.compare))
        except (OSError, ValueError) as exc:
            print(f"读取基线失败：{exc}", file=sys.stderr)
            return 2
        rows, increased = compare(result, baseline_totals)
        if increased:
            exit_code = 1
    else:
        rows, increased = [], 0

    if args.write_baseline:
        write_baseline(result, Path(args.write_baseline))
        print(f"已写入基线：{args.write_baseline}", file=sys.stderr)

    if args.json:
        payload = dict(result)
        if args.compare:
            payload = dict(result, compare={"rows": rows, "increased": increased})
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return exit_code

    print_report(result)
    if args.compare:
        print_compare(rows, increased)

    if not args.write_baseline and not args.compare:
        default_path = Path(args.baseline_path)
        if not default_path.exists():
            write_baseline(result, default_path)
            print()
            print(f"首次运行：已把当前统计写入基线 {args.baseline_path}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
