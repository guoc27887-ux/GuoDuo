#!/usr/bin/env python3
"""上游 jackotom/hongguo-drama 自动同步 + 实测。

  python3 scripts/upstream_sync.py            检查上游；有更新就同步到工作区、打本地补丁、构建核心、实测取源
  python3 scripts/upstream_sync.py --check    只看上游有没有新提交、改了哪些我们用的文件，不动工作区

退出码：0 = 已是最新或同步并实测通过；10 = 上游有更新但只动了我们不用的文件（只更新 UPSTREAM_COMMIT）；
        2 = 本地补丁打不上（上游改到了同一处，要人看）；3 = 实测没过（不提交，工作区还原）；1 = 其它错误。
同步通过后只在本地提交，不发版；发版仍由维护者跑 release.sh（或 upstream_watch.sh 带 --release）。

我们对上游文件的本地改动全部写在 PATCHES 里：每条是「上游原文 → 我们的写法」。同步时按条替换；
上游原文找不到 = 上游改了那一处，脚本停下来要人看，绝不会悄悄丢掉本地改动。
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
UP_REPO = "https://github.com/jackotom/hongguo-drama.git"
CACHE = pathlib.Path(os.environ.get("HG_UPSTREAM_DIR", pathlib.Path.home() / ".cache/guoduo/hongguo-drama"))

# 我们用到的上游文件：本地名 → 上游路径
FILES = {
    "account-session.js": "src/native/account-session.js",
    "app-source.js": "src/native/app-source.js",
    "catalog.js": "src/native/catalog.js",
    "danmaku-sign.js": "src/native/danmaku-sign.js",
    "danmaku.js": "src/native/danmaku.js",
    "download-quality.js": "src/native/download-quality.js",
    "hema.js": "src/native/hema.js",
    "hongguo-app-catalog.js": "src/native/hongguo-app-catalog.js",
    "hongguo-app-search.js": "src/native/hongguo-app-search.js",
    "playback-device.js": "src/native/playback-device.js",
    "playback-signature.js": "src/native/playback-signature.js",
    "playback-v5.js": "src/native/playback-v5.js",
    "public-details.js": "src/native/public-details.js",
    "public.js": "android/web/public.js",
    "request-signal.js": "src/native/request-signal.js",
    "sm3.js": "src/native/sm3.js",
    "xifan.js": "src/native/xifan.js",
}

# 本地改动：(文件, 上游原文, 我们的写法, 说明)
PATCHES = [
    ("app-source.js",
     "    if (!['/reading/distribution/category/landpage/v/', '/reading/bookapi/bookmall/cell/change/v'].includes(apiPath)) {",
     "    if (!['/reading/distribution/category/landpage/v/', '/reading/bookapi/bookmall/cell/change/v', '/novel/player/video_detail/v1/'].includes(apiPath)) {",
     "放行剧集详情接口（每集评论/点赞统计）"),
    ("app-source.js",
     "                        ...(requestedQuality === 'auto' ? {} : { width: selected.width, height: selected.height }) });",
     "                        width: selected.width, height: selected.height });  // GuoDuo：推荐缓存按横竖分桶，auto 也带上宽高",
     "auto 画质也带回宽高"),
    ("catalog.js", "require('./web-media-guard')", "require('../shims/web-media-guard.js')", "web-media-guard 用 JSC 替身"),
    ("hema.js", "require('./web-media-guard')", "require('../shims/web-media-guard.js')", "web-media-guard 用 JSC 替身"),
    ("xifan.js", "require('./web-media-guard')", "require('../shims/web-media-guard.js')", "web-media-guard 用 JSC 替身"),
    ("public.js", "import request from './transport.js';", "import request from '../shims/transport.js';", "transport 用 JSC 替身"),
]

# 实测：搜这几部剧，每部取前 N 集播放地址（真实网络）
SMOKE_KEYWORDS = ["小安寻亲", "闪婚", "神医"]
SMOKE_EPISODES = 3


def sh(*args, cwd=None, check=True, capture=True):
    r = subprocess.run(args, cwd=cwd, text=True, capture_output=capture)
    if check and r.returncode != 0:
        raise SystemExit(f"命令失败：{' '.join(args)}\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip() if capture else ""


def upstream_head():
    if not (CACHE / ".git").exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        sh("git", "clone", "-q", UP_REPO, str(CACHE))
    sh("git", "fetch", "-q", "origin", cwd=CACHE)
    return sh("git", "rev-parse", "origin/HEAD", cwd=CACHE)


def pinned():
    return (ROOT / "core/UPSTREAM_COMMIT").read_text().split()[-1]


def changed_files(old, new):
    out = sh("git", "diff", "--name-only", old, new, "--", *FILES.values(), cwd=CACHE)
    return [p for p in out.splitlines() if p]


def apply(new):
    """把上游 new 的文件写进 core/upstream/，再打本地补丁；补丁打不上返回失败列表"""
    up = ROOT / "core/upstream"
    for local, path in FILES.items():
        (up / local).write_text(sh("git", "show", f"{new}:{path}", cwd=CACHE) + "\n", encoding="utf-8")
    failed = []
    for local, orig, ours, why in PATCHES:
        p = up / local
        s = p.read_text(encoding="utf-8")
        if s.count(orig) == 1:
            p.write_text(s.replace(orig, ours), encoding="utf-8")
        elif ours in s:
            pass   # 上游自己改成了我们的写法
        else:
            failed.append(f"{local}：{why}")
    return failed


def smoke():
    """拿刚同步的核心实测：搜剧 → 取分集 → 取播放地址。返回 (成功, 总数, 明细)"""
    js = r"""
const path = require('node:path');
const dir = process.argv[2], kws = JSON.parse(process.argv[3]), N = +process.argv[4];
const { fetchAppPlayUrl, signedMetadataRequest, requestJson } = require(path.join(dir, 'app-source.js'));
const { searchApp } = require(path.join(dir, 'hongguo-app-search.js'));
const { fetchPublicFallback } = require(path.join(dir, '..', 'web-fallback.cjs'));
(async () => {
  let ok = 0, total = 0, app = 0, web = 0; const lines = [];
  for (const kw of kws) {
    let sid;
    try { sid = String((await searchApp(kw, { page: 1 })).results[0].series_id); }
    catch (e) { lines.push(`搜索「${kw}」失败 ${e.code || ''} ${e.message}`); total += N; continue; }
    const body = { series_id: sid, biz_param: { caller_scene: 'single_col', detail_page_version: 0, from_video_id: '',
      need_all_video_definition: false, need_mp4_align: false, source: 4, video_id_type: 1 } };
    const s = signedMetadataRequest('/novel/player/video_detail/v1/', {}, body);
    const j = await requestJson(s.url, { method: 'POST', headers: s.headers, data: s.body }, Date.now() + 15000).catch(e => ({ e }));
    const vids = (j?.data?.video_data?.video_list || []).slice(0, N).map(v => String(v.vid));
    if (!vids.length) { lines.push(`「${kw}」取分集失败`); total += N; continue; }
    for (const vid of vids) {
      total++;
      // 与 App 一致：App 接口取不到再走官网兜底（core/web-fallback.cjs），任一条通就算能播
      try { await fetchAppPlayUrl(vid, {}); ok++; app++; continue; }
      catch (e) {
        try { await fetchPublicFallback(vid); ok++; web++; }
        catch (w) { lines.push(`「${kw}」${vid} App ${e.code || ''} ${String(e.message).slice(0, 40)}；官网兜底 ${w.code || ''} ${String(w.message).slice(0, 30)}`); }
      }
    }
  }
  lines.unshift(`App 接口 ${app} 集，官网兜底 360P ${web} 集`);
  console.log(JSON.stringify({ ok, total, lines }));
})().catch(e => console.log(JSON.stringify({ ok: 0, total: 1, lines: [String(e.message)] })));
"""
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        shutil.copytree(ROOT / "core/upstream", td / "upstream")
        shutil.copytree(ROOT / "core/shims", td / "shims")
        shutil.copy(ROOT / "core/web-fallback.cjs", td / "web-fallback.cjs")
        nm = CACHE / "node_modules"
        if not (nm / "axios").exists():
            sh("npm", "i", "--silent", "--no-audit", "--no-fund", "axios", cwd=CACHE)
        (td / "node_modules").symlink_to(nm)
        (td / "smoke.cjs").write_text(js, encoding="utf-8")
        env = dict(os.environ, HOME=str(td))
        r = subprocess.run(["node", str(td / "smoke.cjs"), str(td / "upstream"), json.dumps(SMOKE_KEYWORDS), str(SMOKE_EPISODES)],
                           text=True, capture_output=True, env=env, timeout=300)
        try:
            d = json.loads(r.stdout.strip().splitlines()[-1])
        except Exception:  # noqa: BLE001
            d = {"ok": 0, "total": 1, "lines": [r.stderr[-300:]]}
    return d["ok"], d["total"], d["lines"]


def main():
    check_only = "--check" in sys.argv
    old, new = pinned(), upstream_head()
    subject = sh("git", "log", "-1", "--format=%s", new, cwd=CACHE)
    if old == new:
        print(f"上游已是最新：{new[:7]} {subject}")
        return 0
    log = sh("git", "log", "--format=%h %ad %s", "--date=format:%m-%d", f"{old}..{new}", cwd=CACHE)
    files = changed_files(old, new)
    print(f"上游有新提交（{old[:7]} → {new[:7]}）：\n{log}")
    print("我们用到的文件里改了：" + ("、".join(pathlib.Path(f).name for f in files) or "没有"))
    if check_only:
        return 0
    if sh("git", "status", "--porcelain", "--untracked-files=no", "--", "core", cwd=ROOT):
        raise SystemExit("core/ 有未提交改动，先处理")

    if not files:
        (ROOT / "core/UPSTREAM_COMMIT").write_text(f"jackotom/hongguo-drama {new}\n")
        sh("git", "add", "core/UPSTREAM_COMMIT", cwd=ROOT)
        sh("git", "commit", "-qm", f"chore(上游): 记录 hongguo-drama {new[:7]}（没改到我们用的文件）", cwd=ROOT)
        print("只更新了 UPSTREAM_COMMIT")
        return 10

    failed = apply(new)
    if failed:
        sh("git", "checkout", "--", "core/upstream", cwd=ROOT)
        print("❌ 本地补丁打不上（上游改到了同一处），已还原，要人看：\n  " + "\n  ".join(failed))
        return 2

    ok, total, lines = smoke()
    print(f"实测取源：{ok}/{total}")
    for ln in lines:
        print(("  · " if ln.startswith("App 接口 ") else "  ✗ ") + ln)
    if total == 0 or ok < total * 0.8:
        sh("git", "checkout", "--", "core/upstream", cwd=ROOT)
        print("❌ 实测没过，已还原，不提交")
        return 3

    sh("node", "build.cjs", cwd=ROOT / "core")
    (ROOT / "core/UPSTREAM_COMMIT").write_text(f"jackotom/hongguo-drama {new}\n")
    sh("git", "add", "core/upstream", "core/UPSTREAM_COMMIT", "HongGuo/Resources/hgcore.js", cwd=ROOT)
    names = "、".join(pathlib.Path(f).name for f in files)
    sh("git", "commit", "-qm", f"fix(取源): 同步上游 hongguo-drama {new[:7]}（{subject}）——改动 {names}；本地补丁 {len(PATCHES)} 处已保留；实测取源 {ok}/{total}", cwd=ROOT)
    print(f"✅ 已同步并提交（本地），实测 {ok}/{total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
