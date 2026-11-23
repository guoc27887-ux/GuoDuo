// GuoDuo 自有（不是上游拷贝，同步上游不会覆盖）：红果官网网页播放器的公开兜底接口。
// 同上游 8.0 hongguo.js fetchPublicFallbackPlayUrl。2026-11-23 起红果 App 播放接口全线 HTTP 200 空包，
// 这条仍能给完整一集 360P H.264/AAC MP4（不加密，不是 SEO 页的 10 秒预览）。
// App 里 axios 由 build.cjs 换成 Native 替身；scripts/upstream_sync.py 实测时用 Node 真 axios。
const axios = require('axios');

const API = 'https://hongguoduanju.com/api/video/protected/fallback-play-info';
const WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const REFERER = 'https://hongguoduanju.com/';
const fail = (message, code) => Object.assign(new Error(message), { code });

async function fetchPublicFallback(vid, signal) {
  vid = String(vid);
  if (!/^\d{1,30}$/.test(vid)) throw fail('分集编号无效', 'NO_PLAYABLE_SOURCE');
  const r = await axios({ url: API, method: 'POST',
    headers: { 'User-Agent': WEB_UA, Accept: 'application/json', 'Content-Type': 'application/json', Referer: REFERER },
    data: { item_id: vid }, timeout: 8000, maxRedirects: 0, responseType: 'json', validateStatus: () => true, signal });
  const p = r?.data;
  if (r?.status !== 200 || !p || typeof p !== 'object' || Number(p.base_resp?.StatusCode ?? p.code ?? 0) !== 0)
    // 403 public_fallback_unavailable = 官网只放每部剧前 5 集（2026-11-23 实测），不是网络问题
    throw r?.status === 403 ? fail('红果 App 接口失效中，官网只放前 5 集，这集要等上游修复', 'HTTP_403')
      : fail('官网兜底接口未返回片源', r?.status >= 400 ? `HTTP_${r.status}` : 'NO_PLAYABLE_SOURCE');
  let media;
  try { media = new URL(String(p.main_url || '').replace(/^http:\/\//, 'https://')); } catch (_) { media = null; }
  if (!media || media.protocol !== 'https:' || media.username || media.password
      || !/(^|\.)(?:qznovelvod|fqnovelvod|douyinvod)\.com$/i.test(media.hostname))
    throw fail('官网兜底片源地址无效', 'NO_PLAYABLE_SOURCE');
  return { url: media.href, contentKey: null, codec: 'h264', quality: '360p', width: 360, height: 640,
    userAgent: WEB_UA, referer: REFERER, source: 'web' };
}

module.exports = { fetchPublicFallback };
