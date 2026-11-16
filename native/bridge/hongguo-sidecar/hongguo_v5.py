# -*- coding: utf-8 -*-
"""红果 v5 匿名取流 sidecar（本项目自有实现，协议 wire 事实来自公开逆向研究）。

用法: python hongguo_v5.py resolve <episode_id> <data_dir>
输出: {"ok":true,"result":{"code":0,"data":{"video_model":{…}}}}（stdout JSON 单行）
     {"ok":false,"error":"…"}（失败；由 Go 侧转译为回退语义）

流程：匿名注册（小米14/73932/TTEncrypt）→ 官方 APK 分段取 libmetasec_ml.so
（Range+sha256 锁定）→ Unicorn ARM64 模拟设备摘要 → mssdk get_token 交换
（200 直就绪 / 202 二段）→ v5 签名播放 multi_video_model/player/v1。
依赖：pip unicorn、pycryptodome。直连（不走系统代理）。
"""
import json
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import v5register  # noqa: E402
import v5session  # noqa: E402
from v5assets import CONFIG_NAME, load_assets  # noqa: E402
from v5unicorn import SdkDigestCore  # noqa: E402


def _resolve_once(video: str, data_dir: Path) -> dict:
    context = v5register.ensure_device(data_dir)
    assets = load_assets(data_dir / "playback-sdk" / "74332", allow_download=True)
    core_holder = {}

    def core(payload, mode, seconds):
        engine = core_holder.get("engine")
        if engine is None:
            engine = SdkDigestCore(assets["libmetasec_ml.so"])
        try:
            return engine.digest(payload, mode, seconds)[0][:16]
        except Exception:
            core_holder["engine"] = None
            raise
        else:
            core_holder["engine"] = engine

    # 修正闭包语义：成功也回写 engine（上面 except/else 顺序已保证）
    session = v5session.ensure_session(data_dir, context, assets, core)
    request = v5session.prepare_playback_v5(
        context, video, int(time.time() * 1000),
        token=session["token"], previous_ladon=session["ladon"],
        materials=v5session.decode_app_config(assets[CONFIG_NAME]),
        image=v5session.read_sdk_image(assets["libmetasec_ml.so"]),
        core=core,
    )
    raw = v5session._send(request)
    value = json.loads(raw)
    if value.get("code") != 0:
        raise ValueError(f"playback-code-{value.get('code')}")
    entry = (value.get("data") or {}).get(video)
    if not isinstance(entry, dict) or not entry.get("video_model"):
        raise ValueError("invalid-model")
    model = entry["video_model"]
    if isinstance(model, str):
        model = json.loads(model)
    return {"code": 0, "data": {"video_model": model}}


SESSION_REFRESH_MIN_AGE = 300  # 新会话失败不自动刷新（防风暴）；老会话失败重交换一次


def resolve(video: str, data_dir: Path) -> dict:
    if not video.isdigit() or not 8 <= len(video) <= 24:
        raise ValueError("invalid-episode-id")
    data_dir = Path(data_dir).resolve()
    session_file = data_dir / "hongguo-sdk-session.json"
    last_error = None
    for attempt in range(2):
        try:
            return _resolve_once(video, data_dir)
        except Exception as error:
            last_error = error
            if attempt > 0:
                break
            # 会话自愈：令牌过期/失效时重交换一次。新会话（<5min）失败不刷新。
            try:
                age = time.time() - session_file.stat().st_mtime
            except OSError:
                age = 1 << 30
            if age < SESSION_REFRESH_MIN_AGE:
                break
            try:
                session_file.unlink()
            except OSError:
                pass
    raise last_error


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--trace"]
    if len(args) == 3 and args[0] == "resolve":
        episode, data_dir = args[1], args[2]
    elif len(args) == 2:
        episode, data_dir = args
    else:
        print(json.dumps({"ok": False, "error": "usage: [resolve] <episode_id> <data_dir>"}))
        return 2
    started = time.monotonic()
    try:
        result = resolve(episode, Path(data_dir).resolve())
        print(json.dumps({"ok": True, "result": result, "elapsed": round(time.monotonic() - started, 2)},
                         ensure_ascii=False))
        return 0
    except Exception as error:
        detail = f"{type(error).__name__}: {error}"
        if "--trace" in sys.argv:
            traceback.print_exc(file=sys.stderr)
        print(json.dumps({"ok": False, "error": detail[:400]}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
