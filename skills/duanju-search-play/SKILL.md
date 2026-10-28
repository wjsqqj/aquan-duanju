---
name: duanju-search-play
description: 在本地「阿圈短剧」客户端里搜索剧名并按 1、2、3 序号列出结果，再按用户回复的序号或剧名唤起客户端播放（有观看历史就从上次那一集那一秒续播）。当用户说「搜索短剧XX」「我要看短剧XX」「第2个」「就3」这类只给剧名或序号的请求，或要求用 Agent 驱动阿圈短剧播放时使用。
---

# 阿圈短剧：搜索与按序号开播

程序提供两个入口，Agent 不需要操作界面：

- `aquan-cli search <关键词>`：只查一次列表，打到 stdout 就退出，**不打开窗口**
- `aquan-cli series <ID>`：唤起窗口，直接进这一部的详情页并开播（有历史就续播）
- `aquan-cli watch <关键词>`：唤起窗口，程序自己搜、自己挑最匹配的一条开播

`aquan-cli` 与 `aquan_duanju`（Windows 是 `aquan-cli.exe` / `aquan_duanju.exe`）
在同一个目录，随发布包一起分发。

## 工作流

1. 解析程序路径（见下）
2. 搜索：`aquan-cli search 持械入宋`
3. 把输出原样列给用户（序号 + 剧名，别改顺序、别吞掉 ID），等用户选
4. 用户回序号 → 取那一行的 ID：`aquan-cli series 7671966197985856536`
5. 用户一上来就给了剧名、没要列表 → 跳过第 2 步直接 `aquan-cli watch 剧名`

路径按优先级找：

```powershell
$CLI = @($env:AQUAN_CLI,
  "$env:LOCALAPPDATA\aquan-duanju\aquan-cli.exe",
  "$PWD\aquan-cli.exe",
  "$PWD\aquan-windows-x64-0.4.0\aquan-cli.exe") |
  Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
```

macOS / Linux 把 `aquan-cli.exe` 换成 `aquan-cli`，放在解压目录或
`.app/Contents/MacOS/` 里。Windows 安装版默认安装在
`%LOCALAPPDATA%\aquan-duanju`（安装器默认目录）。

## 输出形状

```
持械入宋 · 10 条结果，显示前 10 条
 1  持械入宋：第一季  ID 7671966197985856536  100集
 2  持械入宋：第十季  ID 7697209269287914521  100集
```

序号只在这次列表里有效，所以下一条指令必须带 ID 而不是序号。列表默认 10 条，
`--limit 3` 收窄；要机读就加 `--json`。

## 坑

- **节目已经开着不用管**：`series` / `watch` 会由单实例转交给在跑的那个实例
  （窗口置顶并开播），不要先杀进程。
- **乱码**：PowerShell 先执行 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`
  再取输出；cmd 用 `chcp 65001`。
- **退出码非 0**：`搜索失败：…` 属上游瞬时错误，重试一次；仍失败就如实告诉用户
  来源在抽风，不要换成别的剧。
- **零匹配仍返回列表**：关键词对不上时站点会给推荐位（标题跟关键词无关），
  这种列表要在回话里点明「没搜到精确匹配的《XX》」。
- **播放失败时**程序自己停在详情页或搜索页，不会乱点，Agent 不需要兜底重试。
- 本软件仅供学习与研究使用，不收费。
