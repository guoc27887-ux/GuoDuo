#!/usr/bin/env python3
"""每小时巡检（接在 upstream_watch.sh 后面跑），只在有事时输出 NOTIFY: 一行。

  1. 参考源 Amor5207/lvguo-tv（绿果TV）：签名/取源相关文件有新提交 → 通知（Go/Java 实现，没法自动合，要人看）
  2. 自身健康：用当前提交的取源核心实测（含第 10 集）→ 状态变化才通知（好→挂 报警，挂→好 报恢复）

为什么要 2：2026-11-23 红果服务端改了签名校验，我们代码一行没动就全部空包；只盯上游提交发现不了这种故障。
状态存在 ~/.cache/guoduo/ref_watch.json（本机，不入库）。
  python3 scripts/ref_watch.py          巡检
  python3 scripts/ref_watch.py --status 打印当前状态，不通知
"""
import json
import os
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import upstream_sync as us  # noqa: E402

REF_REPO = "https://github.com/Amor5207/lvguo-tv.git"
REF_DIR = pathlib.Path.home() / ".cache/guoduo/lvguo-tv"
STATE = pathlib.Path.home() / ".cache/guoduo/ref_watch.json"
# 2026-11-23 Medusa 补丁照抄的版本（core/patches/v5-medusa.ours.js）
REF_BASE = "32fcdfd"
# 只关心取源链路：签名、设备注册、播放请求
REF_PATHS = ["web/internal/sign/", "web/internal/lvguoplay/", "tv-playback-module/",
             "src/ink/pengfei/lvguo/net/"]


def git(*args):
    return subprocess.run(["git", *args], cwd=REF_DIR, text=True, capture_output=True, check=True).stdout.strip()


def load():
    try:
        return json.loads(STATE.read_text())
    except Exception:  # noqa: BLE001
        return {}


def check_ref(state, notes):
    if not (REF_DIR / ".git").exists():
        REF_DIR.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "-q", REF_REPO, str(REF_DIR)], check=True)
    git("fetch", "-q", "origin")
    head = git("rev-parse", "origin/HEAD")
    seen = state.get("ref_seen") or git("rev-parse", REF_BASE)
    if head == seen:
        return
    files = [f for f in git("diff", "--name-only", seen, head, "--", *REF_PATHS).splitlines() if f]
    log = git("log", "--format=%h %s", f"{seen}..{head}").splitlines()
    state["ref_seen"] = head
    if files:
        short = "、".join(pathlib.Path(f).name for f in files[:8]) + ("等" if len(files) > 8 else "")
        notes.append(f"绿果TV 有 {len(log)} 个新提交动了取源/签名（{short}），最新：{log[0][:80]}。"
                     f"要我对照看要不要跟进就回「看绿果」。")


def check_health(state, notes):
    ok, total, lines = us.smoke()
    app_line = next((ln for ln in lines if ln.startswith("App 接口 ")), "")
    m = re.match(r"App 接口 (\d+) 集", app_line)
    app = int(m.group(1)) if m else 0
    # ok：App 接口扛大头；degraded：App 接口全挂只剩官网兜底（前 5 集 360P）；down：基本取不到
    if total > 0 and app >= total * 0.8:
        status = "ok"
    elif app == 0 and ok > 0:
        status = "degraded"
    elif total > 0 and ok >= total * 0.8:
        status = "ok"
    else:
        status = "down"
    prev = state.get("health", "ok")
    state["health"], state["health_detail"] = status, f"{ok}/{total} {app_line}"
    if status == prev:
        return
    if status == "ok":
        notes.append(f"GuoDuo 取源已恢复正常（实测 {ok}/{total}，{app_line}）。")
    elif status == "degraded":
        notes.append(f"⚠️ GuoDuo 红果 App 接口挂了，只剩官网兜底（前 5 集 360P）。实测 {ok}/{total}。"
                     f"多半是红果又改了签名校验，回「修取源」我去对照上游/绿果。")
    else:
        bad = "；".join(ln for ln in lines if not ln.startswith("App 接口 "))[:200]
        notes.append(f"🚨 GuoDuo 取源挂了：实测 {ok}/{total}。{bad}")


def main():
    state, notes = load(), []
    if "--status" in sys.argv:
        print(json.dumps(state, ensure_ascii=False, indent=1))
        return
    for step in (check_ref, check_health):
        try:
            step(state, notes)
        except Exception as e:  # noqa: BLE001  巡检自身出错不刷屏：只记状态
            state[f"{step.__name__}_error"] = str(e)[:300]
        else:
            state.pop(f"{step.__name__}_error", None)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, ensure_ascii=False, indent=1))
    for n in notes:
        print("NOTIFY: " + n)


if __name__ == "__main__":
    main()
