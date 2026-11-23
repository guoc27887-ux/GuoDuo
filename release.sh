#!/bin/zsh
# GuoDuo 公开发版：编译未签名 IPA → 打 tag → 发 GitHub Release（所有人下载后自签安装）
# App 内「检查更新」读 releases/latest 拿版本号，再读该 tag 下的 docs/releases/v<版本>.md 显示更新内容，
# 所以发版前必须：① 升 project.yml 的 MARKETING_VERSION ② 写好 docs/releases/v<版本>.md 并提交推送。
# 需要：Xcode 26+、xcodegen、node、gh（已登录）。维护者自用的 Ad Hoc / OTA 包走 release.local.sh（不入库）。
set -e
cd "$(dirname "$0")"
VER=$(grep -E '^ +MARKETING_VERSION:' project.yml | head -1 | awk '{print $2}')
TAG=v$VER
NOTES=docs/releases/$TAG.md
[ -f "$NOTES" ] || { echo "❌ 缺更新说明 $NOTES（App 内更新弹窗要显示它）"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "❌ 工作树有未提交改动，先提交"; exit 1; }
git fetch -q origin
[ -z "$(git log origin/HEAD..HEAD --oneline 2>/dev/null)" ] || { echo "❌ 本地有没推送的提交，先 git push"; exit 1; }

(cd core && { [ -d node_modules ] || npm ci --silent; } && node build.cjs)
xcodegen generate >/dev/null
DD=${TMPDIR:-/tmp}/hg-guoduo-rel
xcodebuild -project HongGuo.xcodeproj -scheme HongGuo -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
[ -z "$(git status --porcelain)" ] || { echo "❌ 构建改动了入库文件（hgcore.js / pbxproj 没同步提交？）"; git status --short; exit 1; }
IPA=build/GuoDuo-$VER-unsigned.ipa
rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$DD/Build/Products/Release-iphoneos/HongGuo.app" build/ipa/Payload/
(cd build/ipa && rm -f "../$(basename $IPA)" && zip -qry "../$(basename $IPA)" Payload)
echo "✅ $IPA"

if ! gh release view $TAG >/dev/null 2>&1; then
  gh release create $TAG --target "$(git rev-parse HEAD)" --title "GuoDuo $VER" --notes-file "$NOTES"
fi
for i in 1 2 3; do gh release upload $TAG "$IPA" --clobber && break; echo "上传重试 $i"; sleep 5; done
echo "✅ 已发布 https://github.com/81199000/GuoDuo/releases/tag/$TAG（私有）"

# Gitee 镜像：代码 + tag + 发行版（没配 gitee 远端就跳过，国内源回落 GitHub）
if git remote get-url gitee >/dev/null 2>&1; then
  # gh release create 刚建的 tag，GitHub 偶尔几秒后才能 fetch 到（0.6.9/0.7.0 都因此 Gitee 缺 tag、发行版 400）
  for i in 1 2 3 4 5; do git fetch -q origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null && break; sleep 3; done
  git push -q gitee HEAD:main "$TAG" 2>&1 | grep -v 'GITEE\|trace' || true
  [ -f scripts/sync_gitee_release.py ] && python3 scripts/sync_gitee_release.py "$TAG" || true
fi

# 全能签 / 轻松签软件源（读刚发的 Release 重新生成）
python3 scripts/build_sign_source.py
# App 内检查更新读 dl.oneduo.app（Cloudflare R2）：同步软件源 / IPA / 更新说明，失败就停
python3 scripts/sync_r2.py || { echo "❌ R2 同步失败，App 内收不到更新"; exit 1; }
if [ -n "$(git status --porcelain docs/source)" ]; then
  git add docs/source && git commit -q -m "chore(源): 软件源更新到 $TAG" && git push -q origin HEAD
  git remote get-url gitee >/dev/null 2>&1 && { git push -q gitee HEAD:main 2>&1 | grep -v 'GITEE\|trace' || true; }
  echo "✅ 软件源 国内 https://gitee.com/remon8/guoduo/raw/main/docs/source/guoduo.json"
  echo "         海外 https://raw.githubusercontent.com/81199000/GuoDuo/main/docs/source/guoduo-github.json"
fi
# 验收：App 内更新检查读这里
LATEST=$(curl -s -H 'Cache-Control: no-cache' "https://dl.oneduo.app/guoduo/guoduo.json?t=$(date +%s)" | python3 -c "import sys,json;print(json.load(sys.stdin)['apps'][0]['version'])")
[ "$LATEST" = "$VER" ] && echo "✅ App 内更新检查（dl.oneduo.app）→ $LATEST" || { echo "❌ dl.oneduo.app 上是 $LATEST，不是 $VER"; exit 1; }
