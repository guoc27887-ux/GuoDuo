#!/bin/zsh
# 定时看上游 hongguo-drama 有没有更新；有就自动同步 + 实测，按结果通知老板。
#   scripts/upstream_watch.sh            同步 + 实测 + 本地提交，通知老板，等老板说「发」
#   scripts/upstream_watch.sh --release  实测通过就直接发版（升补丁版本号 → 写更新说明 → release.sh）
# 由 launchd 每小时跑一次（~/Library/LaunchAgents/me.rrmm.guoduo.upstream.plist）。
# 输出最后一行是给通知用的一句话摘要（以 NOTIFY: 开头）；没有更新时不输出 NOTIFY，保持安静。
set -u
cd "$(dirname "$0")/.."
LOG=${TMPDIR:-/tmp}/guoduo-upstream.log
AUTO_RELEASE=0; [[ ${1:-} == --release ]] && AUTO_RELEASE=1

# 只在干净的 main 上动手，别人正在改就跳过这一轮
[[ $(git rev-parse --abbrev-ref HEAD) == main ]] || { echo "不在 main，跳过"; exit 0; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "工作树有改动，跳过"; exit 0; }
git pull -q --ff-only origin main 2>/dev/null || { echo "拉不下 origin/main，跳过"; exit 0; }

python3 scripts/upstream_sync.py > "$LOG" 2>&1; RC=$?
cat "$LOG"
SUM=$(grep -m1 -E "^上游有新提交" "$LOG" | sed 's/：$//')
case $RC in
  0)
    if grep -q "上游已是最新" "$LOG"; then exit 0; fi
    git push -q origin main; git push -q gitee main 2>&1 | grep -v 'GITEE\|trace' || true
    if (( AUTO_RELEASE )); then
      OLD=$(grep -E '^ +MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}')
      NEW=$(echo $OLD | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
      BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION:' project.yml | head -1 | grep -oE '[0-9]+')
      sed -i '' -E "s/^( +)MARKETING_VERSION: $OLD\$/\1MARKETING_VERSION: $NEW/; s/^( +)CURRENT_PROJECT_VERSION: \"$BUILD\"\$/\1CURRENT_PROJECT_VERSION: \"$((BUILD+1))\"/" project.yml
      # 给用户看的更新说明（一键签「更新内容」会显示）：不贴上游英文提交，写人话
      UPC=$(awk '{print $2}' core/UPSTREAM_COMMIT)
      UPV=$(git -C "${HG_UPSTREAM_DIR:-$HOME/.cache/guoduo/hongguo-drama}" log --format=%s -30 "$UPC" 2>/dev/null | grep -m1 -oE '^release: [0-9]+\.[0-9]+(\.[0-9]+)?' | awk '{print $2}')
      printf "# GuoDuo %s\n\n## 修复\n- 红果接口有变动，同步了上游取源核心%s的修复，解决部分剧集取不到片源、播放失败的问题。\n" \
        "$NEW" "${UPV:+（hongguo-drama $UPV）}" > docs/releases/v$NEW.md
      xcodegen generate >/dev/null
      git add project.yml HongGuo.xcodeproj docs/releases/v$NEW.md && git commit -qm "release: GuoDuo $NEW（自动同步上游）" && git push -q origin main
      if ./release.sh >> "$LOG" 2>&1; then
        # 老板定（2026-11-23）：发版必须顺手装老板手机。release.local.sh 本机私有不入库，有才跑；连不上手机就留 OTA 链接
        PHONE=""
        if [[ -x ./release.local.sh ]]; then
          ./release.local.sh >> "$LOG" 2>&1
          INST=$(grep -E '✅ 已装|❌' "$LOG" | tail -2 | tr '\n' ' ')
          OTA=$(grep -m1 '^OTA: ' "$LOG" | sed 's/^OTA: //')
          PHONE=" 手机：${INST:-没连上，OTA $OTA}"
        fi
        echo "NOTIFY: GuoDuo 上游有更新，已自动同步、实测通过并发布 $NEW，一键签会自动更新。$PHONE"
      else
        echo "NOTIFY: GuoDuo 上游更新已同步并实测通过，但自动发版 $NEW 失败，日志 $LOG"
      fi
    else
      echo "NOTIFY: GuoDuo 上游有更新（${SUM#上游有新提交}），已自动同步并实测通过（$(grep -oE '实测取源：[0-9]+/[0-9]+' "$LOG")），代码已提交。回「发」就发版。"
    fi ;;
  10) git push -q origin main 2>/dev/null; exit 0 ;;   # 上游只改了我们不用的文件，静默
  2)  echo "NOTIFY: GuoDuo 上游有更新，但改到了我们本地改过的地方，自动同步停了，要人看。$(grep -A5 '本地补丁打不上' "$LOG" | tail -n +2 | tr '\n' ' ')" ;;
  3)  echo "NOTIFY: GuoDuo 上游有更新，同步后实测取源没通过（$(grep -oE '实测取源：[0-9]+/[0-9]+' "$LOG")），没提交，要人看。" ;;
  *)  echo "NOTIFY: GuoDuo 上游同步脚本出错（退出码 $RC），日志 $LOG" ;;
esac
