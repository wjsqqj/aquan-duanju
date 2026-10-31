# 听书 · Windows 离线语音桥（WinRT Windows.Media.SpeechSynthesis）
#
# 为什么用 PowerShell 而不是在 runner 里写 C++/WinRT：
#   - 不用改 CMake / 不引 NuGet 投影，Windows 构建零风险；
#   - 只需要「文本 → wav + 词边界」这一件事，进程隔离反而更好清理。
#
# 用法（Dart 侧固定这样调）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File win_tts_bridge.ps1 `
#     -Mode synth -TextB64 <base64(utf8 text)> -OutWav <path> -OutJson <path> [-Voice <displayName>] [-Rate 1.0]
#   powershell.exe ... -Mode probe -OutJson <path>
#
# 输出 JSON（UTF-8，无 BOM）：
#   probe: {"ok":true,"voices":[{"name":"...","language":"..."}]}
#   synth: {"ok":true,"markers":[{"kind":"WordBoundary","textOffset":0,"timeMs":0},...]}
#   失败: {"ok":false,"error":"..."}（退出码 1）
param(
    [Parameter(Mandatory = $true)][ValidateSet('probe', 'synth')][string]$Mode,
    [string]$TextB64 = '',
    [string]$OutWav = '',
    [Parameter(Mandatory = $true)][string]$OutJson,
    [string]$Voice = '',
    [double]$Rate = 1.0
)

$ErrorActionPreference = 'Stop'

function Write-Json($obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    # 无 BOM：Dart 侧 jsonDecode 不吃 BOM。
    [System.IO.File]::WriteAllText($OutJson, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Fail($message) {
    try { Write-Json @{ ok = $false; error = "$message" } } catch { }
    Write-Error "$message" -ErrorAction Continue
    exit 1
}

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]

    # WinRT 的 IAsyncOperation 没有同步等待，统一用 AsTask 包一层。
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]

    function Await($op, $resultType) {
        $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
        $task.Wait(120000) | Out-Null
        if (-not $task.IsCompleted) { throw 'WinRT 合成超时（>120s）' }
        return $task.Result
    }

    $voices = @()
    try {
        foreach ($v in [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) {
            $voices += @{ name = "$($v.DisplayName)"; language = "$($v.Language)" }
        }
    } catch {
        # 没装语音引擎时 AllVoices 会抛 Internal Speech Error：这不算脚本错误，
        # 交给 Dart 侧按「本机不可用」处理。
        $voices = @()
    }

    if ($Mode -eq 'probe') {
        Write-Json @{ ok = $true; voices = $voices }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($TextB64)) { Fail '缺少 TextB64' }
    if ([string]::IsNullOrWhiteSpace($OutWav)) { Fail '缺少 OutWav' }
    if ($voices.Count -eq 0) { Fail '本机未安装语音引擎（AllVoices 为空）' }

    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($TextB64))
    if ([string]::IsNullOrWhiteSpace($text)) { Fail '文本为空' }

    $synth = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::new()
    if (-not [string]::IsNullOrWhiteSpace($Voice)) {
        $picked = $voices | Where-Object { $_.name -eq $Voice } | Select-Object -First 1
        if ($null -ne $picked) {
            $synth.Voice = ([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices |
                Where-Object { $_.DisplayName -eq $Voice } | Select-Object -First 1)
        }
    }
    # 多角色/倍速都由我们自己控制：这里只负责「文本 → 固定语速 wav」。
    try { $synth.Options.SpeakingRate = $Rate } catch { }
    $synth.Options.IncludeWordBoundaryMetadata = $true
    $synth.Options.IncludeSentenceBoundaryMetadata = $true

    $stream = Await ($synth.SynthesizeTextToStreamAsync($text)) ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])

    # 1) 写 wav
    $netStream = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
    $out = [System.IO.File]::Create($OutWav)
    try { $netStream.CopyTo($out) } finally { $out.Dispose(); $netStream.Dispose() }

    # 2) 词/句边界：TimeOffset 是**音频时间轴**，TextOffset 是原文 UTF-16 字符偏移。
    $markers = @()
    foreach ($m in $stream.Markers) {
        $markers += @{
            kind       = "$($m.Kind)"
            textOffset = [int]$m.TextOffset
            timeMs     = [double]$m.TimeOffset.TotalMilliseconds
        }
    }

    Write-Json @{ ok = $true; markers = $markers }
    exit 0
} catch {
    Fail "$($_.Exception.Message)"
}
