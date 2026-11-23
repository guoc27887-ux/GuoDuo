import { Buffer } from 'buffer/';
import { browseList } from './upstream/hongguo-app-catalog.js';
import { searchApp } from './upstream/hongguo-app-search.js';
import { fetchAppPlayUrl, signedMetadataRequest, requestJson } from './upstream/app-source.js';
import { website, parseDetail } from './upstream/public.js';
import { parsePage, toSeconds, cleanControl, setDeviceIdentityFile, MAX_TEXT_LEN, BASE_URL, COMMENT_PATH, USER_AGENT } from './upstream/danmaku.js';
import * as dmSign from './upstream/danmaku-sign.js';
import axios from './shims/axios.cjs';
import { fetchPublicDetails } from './upstream/public-details.js';
import { createAccountService } from './upstream/account-session.js';
import * as xifan from './upstream/xifan.js';
import * as hema from './upstream/hema.js';
import { fetchPublicFallback } from './web-fallback.cjs';

const PLAYABLE = ['h264', 'avc', 'avc1', 'hevc', 'h265', 'hvc1', 'hev1', 'bytevc1'];
const APP_EMPTY_CODES = ['EMPTY_RESPONSE', 'ETIMEDOUT', 'ECONNABORTED', 'ERR_NETWORK'];
let appPlayDownUntil = 0;

const plain = e => ({ message: String(e?.message || e), code: e?.code || '' });
// 每个调用返回 Promise，结果统一回到原生 Native.done(callId, json)。
function wrap(callId, task) {
  Promise.resolve().then(task).then(
    value => Native.done(callId, JSON.stringify({ ok: true, value: value ?? null })),
    error => Native.done(callId, JSON.stringify({ ok: false, error: plain(error) })));
}
const unwrap = r => { if (r && r.success === false) throw Object.assign(new Error(r.error || '加载失败'), { code: r.code || '' }); return r; };
const controllers = new Map();
const sourceOf = id => String(id).startsWith('xifan:') ? xifan : String(id).startsWith('hema:') ? hema : null;

// 官方播放器同款请求体：count 200 + 服务端 cursor 续页（上游 requestWindow 固定 90 条且不带 cursor）。
// 服务端按匿名设备分档下发弹幕（实测同一集：105 / 135 / 216 / 577 条，同设备档位固定）。
// 首次用时拿当前这集第一窗试 5 个候选设备，留下给得最多的那个，钥匙串持久化。
let dmIdentity = null;
function newIdentity() { return { deviceId: dmSign.newDeviceId(), installId: dmSign.newDeviceId() }; }
function dmDevice() {
  if (dmIdentity) return dmIdentity;
  try { const v = JSON.parse(Native.kvGet('hg.danmaku.identity.v2') || 'null'); if (v?.deviceId && v?.installId) return (dmIdentity = v); } catch (_) {}
  return null;
}
async function calibrateDevice({ vid, bookId, duration, signal }) {
  if (dmDevice()) return dmIdentity;
  const cands = [0, 1, 2, 3, 4].map(newIdentity);
  const counts = await Promise.all(cands.map(id => requestWindowWithCursor({ vid, bookId, start: 0, duration, cursor: '', signal, identity: id })
    .then(j => j.data.data_list.length).catch(() => -1)));
  const best = counts.indexOf(Math.max(...counts));
  if (counts[best] < 0) throw new Error('弹幕接口不可用');
  dmIdentity = { ...cands[best], calibrated: counts };
  Native.kvSet('hg.danmaku.identity.v2', JSON.stringify(dmIdentity));
  return dmIdentity;
}
async function requestWindowWithCursor({ vid, bookId, start, duration, cursor, signal, identity }) {
  const stampMs = Date.now(), stamp = Math.floor(stampMs / 1000);
  const nonce = Buffer.from(Native.random(dmSign.NONCE_BYTES), 'base64');
  const { deviceId, installId } = identity || dmDevice();
  const rawQuery = dmSign.buildQuery({ stampMs, deviceId, installId });
  const body = { comment_source: 601, server_channel: 1000, group_id: vid, group_type: 30, comment_type: 20, sort: 1, count: 200,
    cursor: cursor || '', aid: 8662, compliance_status: 0,
    business_param: { book_id: bookId, start_offset_time: start, playlet_item_duration: duration, need_danmaku_guide_type: [1, 3, 4, 2] } };
  const r = await axios({ url: `${BASE_URL}${COMMENT_PATH(vid)}?${rawQuery}`, method: 'POST', data: JSON.stringify(body), signal, timeout: 15000,
    responseType: 'text', transformResponse: [d => d], maxRedirects: 0,
    headers: { 'User-Agent': USER_AGENT, Accept: 'application/json', 'X-XS-From-Web': '0', 'Sdk-Version': '2',
      'Content-Type': 'application/json; charset=utf-8', 'Comment-Source': '601', 'Server-Channel': '1000',
      ...dmSign.signCommentHeaders({ rawQuery, stamp, nonce }) } });
  const j = JSON.parse(r.data);
  if (String(j?.code) !== '0' || !Array.isArray(j?.data?.data_list)) throw new Error('弹幕接口响应无效');
  return j;
}

// 弹幕匿名标识需跨重启复用；钥匙串一条。
setDeviceIdentityFile('hg.danmaku.identity');
// 钥匙串本身加密，safeStorage 只做透传。
const safeStorage = { isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'keychain',
  encryptString: s => Buffer.from(s, 'utf8'), decryptString: b => Buffer.from(b).toString('utf8') };
const account = createAccountService({ filePath: 'hg.account.session', safeStorage });

const normEpisodes = d => ({ series_id: String(d.series_id), series_title: String(d.series_title || '未命名短剧'),
  cover: d.cover || '', description: d.description || '',
  episodes: (d.episodes || []).map((e, i) => ({ vid: String(e.vid), number: Number(e.number || e.vid_index) || i + 1, locked: e.locked === true })) });

globalThis.HG = {
  browse(callId, category, page, genre) { wrap(callId, async () => {
    if (category === 'xifan' || category === 'hema') return unwrap(await (category === 'xifan' ? xifan : hema).browseList({ page }));
    return unwrap(await browseList({ category, page, genre: genre || '' }));
  }); },
  // 粘贴红果分享链接/口令里的链接 → 剧集编号。只认 URL 参数与 /player/ 路径，不跟随跳转。
  resolveShare(callId, text) { wrap(callId, async () => {
    const m = String(text || '').match(/https?:\/\/[^\s<>"'，。）)]+/);
    if (!m) throw new Error('没有找到链接');
    let url = new URL(m[0]);
    for (let hop = 0; hop < 4; hop++) {
      const direct = url.searchParams.get('video_series_id') || url.searchParams.get('series_id');
      if (/^\d{1,30}$/.test(direct || '')) return { series_id: direct };
      const player = url.pathname.match(/^\/player\/(\d{1,30})(?:\/|$)/);
      if (player) return { series_id: player[1] };
      const scheme = url.searchParams.get('schemeParams');
      const vid = scheme && decodeURIComponent(scheme).match(/"video_id"\s*:\s*"(\d{1,30})"/);
      if (vid) return { series_id: vid[1] };
      const r = await (await import('./shims/axios.cjs')).default({ url: url.href, maxRedirects: 0, validateStatus: () => true, responseType: 'text', transformResponse: [d => d] });
      if (!r.headers?.location) break;
      url = new URL(r.headers.location, url);
    }
    throw new Error('无法从链接中识别红果剧集');
  }); },
  search(callId, keyword, page, cursor, source) { wrap(callId, async () => {
    if (source === 'xifan' || source === 'hema') return unwrap(await (source === 'xifan' ? xifan : hema).search(keyword, page));
    return searchApp(keyword, { page, cursor: cursor ? JSON.parse(cursor) : null });
  }); },
  episodes(callId, sid) { wrap(callId, async () => {
    const other = sourceOf(sid);
    if (other) return normEpisodes(await other.fetchEpisodeList(String(sid)));
    return normEpisodes(parseDetail(await website(`/player/${sid}`), String(sid)));
  }); },
  // 只返回原生能播的编码；签名和 contentKey 原样透传，不改动。
  source(callId, vid, quality) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const other = sourceOf(vid);
        if (other) {
          const r = await other.fetchPlayUrlSingle(String(vid));
          if (!r.url) throw Object.assign(new Error(r.error || '片源不可用'), { code: r.locked ? 'LOCKED' : '' });
          return { vid: String(vid), variants: [{ url: r.url, contentKey: null, codec: 'h264', quality: '', userAgent: 'Mozilla/5.0', referer: '' }] };
        }
        // 红果 App 播放接口会回 HTTP 200 空包：2026-11-19 是随机四成失败，2026-11-23 起全线空包（上游 8.0 也修不回来，
        // 换官网网页播放器的公开兜底接口）。上游 8.0 内部已经轮换 6 个入口 + 节流换号，这里只再补 1 轮；
        // 仍是空包就记 5 分钟「App 不可用」，期间直接走官网兜底（完整一集 360P H.264，不加密），省掉每集 3~4 秒白等。
        let s, lastErr;
        if (Date.now() >= appPlayDownUntil) {
          for (let round = 0; round < 2 && !s; round++) {
            if (round) await new Promise(r => setTimeout(r, 600));
            if (controller.signal.aborted) break;
            try { s = await fetchAppPlayUrl(String(vid), { quality: quality || 'auto', signal: controller.signal }); }
            catch (e) {
              lastErr = e;
              if (!APP_EMPTY_CODES.includes(e?.code)) break;
              Native.log(`source retry vid=${vid} round=${round + 1} code=${e.code}`);
            }
          }
          if (s) appPlayDownUntil = 0;
          else if (APP_EMPTY_CODES.includes(lastErr?.code)) appPlayDownUntil = Date.now() + 5 * 60 * 1000;
        }
        if (!s && !controller.signal.aborted) {
          try { s = await fetchPublicFallback(String(vid), controller.signal); Native.log(`source web-fallback vid=${vid}`); }
          catch (e) { Native.log(`source web-fallback fail vid=${vid} ${e.code || ''} ${e.message}`); if (!lastErr) lastErr = e; }
        }
        if (!s) throw lastErr || new Error('取源失败');
        const all = s.variants || [s];
        const variants = all.filter(v => PLAYABLE.includes(String(v.codec).toLowerCase()))
          .map(v => ({ url: v.url, contentKey: v.contentKey || null, codec: v.codec, quality: v.quality || s.quality || '', userAgent: v.userAgent || s.userAgent || '', referer: v.referer || '' }));
        if (!variants.length) throw Object.assign(new Error('本集只有 ByteVC2 编码，iOS 暂不支持'), { code: 'UNSUPPORTED_CODEC' });
        // 宽高：同一集各码流画幅一致，取第一条带尺寸的；推荐缓存靠它在下载前分横竖
        const sized = all.find(v => Number(v.width) > 0 && Number(v.height) > 0);
        return { vid: String(vid), variants, width: Number(sized?.width) || 0, height: Number(sized?.height) || 0 };
      } finally { controllers.delete(callId); }
    });
  },
  // 分时弹幕：服务端按 30 秒一窗下发，同一窗再用 cursor 续页；每页 200 条（官方播放器的上限），
  // 并带上本集真实时长（openhongguo 实测：时长给大了会白翻空窗）。一次把整集拉完再返回。
  danmaku(callId, sid, vid, startMs, durationMs) {
    const controller = new AbortController(); controllers.set(callId, controller);
    wrap(callId, async () => {
      try {
        const duration = Math.max(30000, Math.min(24 * 3600 * 1000, Number(durationMs) || 3600000));
        let start = Math.max(0, Number(startMs) || 0), cursor = '', reported = 0;
        const out = [], seen = new Set();
        await calibrateDevice({ vid: String(vid), bookId: String(sid), duration, signal: controller.signal });
        for (let page = 0; page < 60 && start < duration; page++) {
          const payload = await requestWindowWithCursor({ vid: String(vid), bookId: String(sid), start, duration, cursor, signal: controller.signal })
            .catch(e => { if (out.length) return null; throw Object.assign(new Error('弹幕源暂不可用'), { code: 'DANMAKU_UNAVAILABLE', cause: e }); });
          if (!payload) break;
          const { items, nextMs, hasMore } = parsePage(payload, String(vid));
          for (const it of items) {
            const t = toSeconds(it.timeRaw); const text = cleanControl(it.text);
            if (t === null || !text || text.length > MAX_TEXT_LEN) continue;
            const key = `${t.toFixed(3)}|${text}`; if (seen.has(key)) continue; seen.add(key);
            out.push({ time: t, text, color: it.color, mode: it.mode });
          }
          try { reported = JSON.parse(payload?.data?.common_list_info?.cursor || '{}').danmaku_count || reported; } catch (_) {}
          if (!hasMore || nextMs === null || nextMs <= start) break;
          cursor = String(payload?.data?.common_list_info?.cursor || '');
          start = nextMs;
        }
        out.sort((a, b) => a.time - b.time);
        return { items: out, next: null, reported };
      } finally { controllers.delete(callId); }
    });
  },
  // App 剧集详情：每集评论数 / 点赞数，整剧追剧数 / 播放量（官网第 6 集以后不公开，只能走 App 签名接口）。
  stats(callId, sid) { wrap(callId, async () => {
    const body = { series_id: String(sid), biz_param: { caller_scene: 'single_col', detail_page_version: 0, from_video_id: '',
      need_all_video_definition: false, need_mp4_align: false, source: 4, video_id_type: 1 } };
    const s = signedMetadataRequest('/novel/player/video_detail/v1/', {}, body);
    const j = await requestJson(s.url, { method: 'POST', headers: s.headers, data: s.body }, Date.now() + 10000);
    if (!j || Number(j.code) !== 0) throw new Error('剧集统计不可用');
    const vd = j.data?.video_data || {};
    if (String(vd.series_id_str || vd.series_id || sid) !== String(sid)) throw new Error('剧集统计不匹配');
    const n = v => Number.isFinite(Number(v)) ? Number(v) : null;
    return { follows: n(vd.followed_cnt), plays: n(vd.series_play_cnt),
      episodes: (vd.video_list || []).map(e => ({ vid: String(e.vid), comments: n(e.comment_count), likes: n(e.digged_count) })) };
  }); },
  // 官网公开页的本集热评（最多 15 条）+ 本集点赞、本剧收藏数。
  comments(callId, sid, vid) { wrap(callId, async () => {
    const d = unwrap(await fetchPublicDetails(String(sid), String(vid), { reviewsLimit: 15 }));
    return { total: d.episode_reviews?.total ?? null, items: (d.episode_reviews?.items || []).slice(0, 15),
      episodeLikes: d.episode_like_count ?? null, favorites: d.favorite_count ?? null };
  }); },
  accountStatus(callId) { wrap(callId, () => account.status()); },
  accountStartLogin(callId) { wrap(callId, () => account.startLogin()); },
  accountPollLogin(callId, id) { wrap(callId, () => account.pollLogin(id)); },
  accountCancelLogin(callId, id) { wrap(callId, () => account.cancelLogin?.(id)); },
  accountLogout(callId) { wrap(callId, () => account.logout()); },
  accountHistory(callId, refresh) { wrap(callId, () => account.history({ refresh: !!refresh })); },
  cancel(callId) { controllers.get(callId)?.abort(); },
};
globalThis.Buffer = Buffer;
Native.log('HG core ready');
