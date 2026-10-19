/**
 * 歌单导入服务（网易云 / QQ 音乐 → 本地歌单，2026-10-16）。
 * 方案见 design/歌单导入方案-网易云与QQ音乐.md，三层管线：
 *
 *   ① 获取：文本粘贴（主路径，永不失效）/ 网易云链接直连（v6 拿 ID → v3 分批查详情）/
 *      QQ 音乐直连（一次全量）。链接识别覆盖 PC 网页 + **App 分享**（`/m/playlist`、
 *      `taoge.html?id=`）+ **分享短链**（`c6.y.qq.com/base/fcgi-bin/u?__=`，靠 302 的
 *      Location 反查 ID，见 resolveShareShortLink）；命中平台域名却提不出 ID 时**明确
 *      提示**，绝不静默降级成「一行一首」把整串分享文本当歌名去搜。
 *      直连均为非公开接口，失败一律抛错由调用方降级提示。
 *   ② 匹配：B 站搜索 + 打分分档（强匹配自动选中 / 弱匹配人工复核 / 未找到兜底手动搜），
 *      **并发 4 + 全局节流 200ms**（每首候选取 30 条）+ 轮内同曲去重 + 风控即停
 *      （-352/-412/-509/-799），保留进度可续。旧版「串行 + 每首硬等 1.0~1.5s」已废弃，
 *      见下方 MATCH_CONCURRENCY 处的实测依据。
 *   ③ 落库：一次建单落盘（createPlaylist + updatePlaylist 两次 persist，禁止逐首
 *      addTrackToPlaylist —— 它每调一次全量重写所有分片，500 次 = I/O 灾难）。
 *
 * ⚠️ 隐私红线：请求网易云 / QQ 必须 skipCookie + skipReferer —— HttpUtil 默认会自动
 * 附加 B 站 Cookie（buvid + 登录态）与 B 站 Referer，绝不能发给第三方。
 *
 * 进度广播：ImportTaskManager 单例（DownloadManager 的 queue/pump 同款思路），
 * 每处理一首向 AppStorage(STORE_IMPORT_STATE) 广播一份新快照对象，导入向导页
 * @StorageLink + @Watch 订阅；离开页面任务继续跑，回来能看到进度。
 */

import { HttpUtil } from '../utils/HttpUtil';
import { cleanTitle, parseDurationText, stripHtmlTags, toHttpsUrl } from '../utils/TextUtil';
import { BiliApiError, SearchResponse, SearchResultItem, searchVideo } from '../api/BilibiliApi';
import { buildTrack, slimTrack, Track, Playlist } from '../model/MusicModels';
import {
  createPlaylist,
  getPlaylists,
  PLAYLIST_MAX_ITEMS,
  updatePlaylist
} from './LibraryStore';
import { STORE_IMPORT_STATE } from '../common/Constants';

//
// ─────────────────────────── 模型 ───────────────────────────
//

/** 外部平台的一首歌（获取工序的统一输出，匹配工序的输入） */
export interface ExternalSong {
  title: string;
  /** 多歌手用 `/` 连接，空串 = 未知 */
  artist: string;
  /** 时长（秒），0 = 未知（文本粘贴无时长时跳过时长打分） */
  durationSec: number;
}

/** 一次识别出的外部歌单（文本解析或链接直连的产物） */
export interface ExternalPlaylist {
  /** 歌单原名（直连有值；文本粘贴为空） */
  name: string;
  coverUrl: string;
  songs: ExternalSong[];
  /** 展示用来源标签（网易云歌单 / QQ 音乐歌单 / 文本列表） */
  sourceLabel: string;
}

/** 导入任务阶段（向导页 5 态由它 + 页面本地态共同驱动） */
export enum ImportPhase {
  IDLE = 0,
  MATCHING = 1,
  /** 自然跑完 */
  DONE = 2,
  /** 用户主动中断（保留已完成进度，可续） */
  STOPPED = 3,
  /** 命中 B 站搜索风控即停（保留进度，可续） */
  RISK = 4
}

/** 单首曲目的匹配档位 */
export enum ImportItemStatus {
  PENDING = 0,
  /** 强匹配（≥5 分）：已自动选中 */
  STRONG = 1,
  /** 弱匹配（3~4 分）：进待确认列表，附 Top3 候选 */
  WEAK = 2,
  /** 未找到：可手动搜 / 跳过 */
  MISSING = 3,
  /** 复核时用户明确跳过 */
  SKIPPED = 4
}

/** 一首歌的匹配结果（items 下标 = 在歌单中的原顺序，复核靠它定位） */
export interface ImportItem {
  song: ExternalSong;
  status: ImportItemStatus;
  /** Top3 候选（弱匹配 / 手动搜索结果） */
  candidates: Track[];
  /** 最终选中的 B 站曲目（强匹配自动填，复核可改） */
  chosen: Track | null;
  /** 未找到时的原因（复核界面展示） */
  failReason: string;
}

/** 任务快照（每次 notify 都生成新对象广播，AppStorage 消费方拿到的是只读快照） */
export interface ImportState {
  phase: ImportPhase;
  total: number;
  processed: number;
  strong: number;
  weak: number;
  missing: number;
  skipped: number;
  /** 正在匹配的曲目名（匹配中实时滚动展示） */
  currentTitle: string;
  /** 风控即停时的提示语 */
  riskMessage: string;
  /** 识别来源的歌单原名（落库默认名） */
  sourceName: string;
  /** 识别来源的封面（落库用） */
  sourceCoverUrl: string;
  items: ImportItem[];
}

//
// ───────────────────── ① 获取：文本粘贴解析 ─────────────────────
//

/** 「共 57 首」之类汇总行，忽略 */
const SUMMARY_LINE_RE: RegExp = /共\s*\d+\s*首/;
/** 行首序号（带分隔符的 `1.` `01、` `1：` 一律安全可去） */
const LEADING_INDEX_RE: RegExp = /^\d{1,3}\s*[.、．:：]\s*/;
/** 零填充行首序号（`01 起风了`）。非零填充的 `7 Rings` / `99 Luftballons` 不能误伤 */
const LEADING_PADDED_INDEX_RE: RegExp = /^0\d\s+/;
/** 「歌名 - 歌手」分隔（带空格的 - / – / —，避免误伤词内连字符） */
const DASH_SPLIT_RE: RegExp = /\s+[-–—]\s*/;
/** 行尾时长（`04:37`） */
const TRAILING_DURATION_RE: RegExp = /\s(\d{1,2}:\d{2})$/;
/** 首尾包裹引号 */
const WRAPPING_QUOTES_RE: RegExp = /^[「『《"'“‘]+|[」』》"'”’]+$/g;
/** 含链接的行（http/https 或裸 www.）——分享文本里的链接行永不是歌名 */
const URL_LINE_RE: RegExp = /(?:https?:\/\/|www\.)\S+/i;

/**
 * 解析粘贴的歌词列表文本（路线 A，主路径）。
 * 容错规则见方案 §2A：一行一首；按 - / – / — 切「歌名 - 歌手」；无分隔符整行当歌名；
 * 去行首序号与包裹引号；忽略空行与「共 N 首」汇总行；行尾 mm:ss 记为时长；同曲去重。
 */
export function parseSongListText(text: string): ExternalSong[] {
  const out: ExternalSong[] = [];
  const seen: Set<string> = new Set<string>();
  const lines: string[] = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    // 含链接的行**整行丢弃**。分享文本形如
    //   「分享歌单《暴露年龄！90后MP3里的经典老歌》https://c6.y.qq.com/… @… 音乐」
    // 若不过滤，整行（90+ 字符）会当成一首「歌名」去搜 B 站：模糊搜索照样返回结果，
    // 但打分要求「视频标题包含歌名」→ 全部出局 → 报告页显示「未找到」
    // （2026-10-16 实测根因之一）。
    if (URL_LINE_RE.test(line)) {
      continue;
    }
    // 汇总行只有「共 N 首」没有分隔符；带分隔符的行哪怕是汇总也当作歌处理（宁可多解析）
    if (SUMMARY_LINE_RE.test(line) && !DASH_SPLIT_RE.test(line)) {
      continue;
    }
    line = line.replace(LEADING_INDEX_RE, '');
    line = line.replace(LEADING_PADDED_INDEX_RE, '');
    let durationSec: number = 0;
    const durMatch: RegExpMatchArray | null = line.match(TRAILING_DURATION_RE);
    if (durMatch !== null) {
      durationSec = parseDurationText(durMatch[1]);
      line = line.substring(0, line.length - durMatch[0].length).trim();
    }
    let title: string = '';
    let artist: string = '';
    const parts: string[] = line.split(DASH_SPLIT_RE);
    if (parts.length >= 2) {
      title = parts[0].trim();
      // 歌手名里也可能有带空格的连字符（如 Twenty One - Pilots），后半段原样拼回
      artist = parts.slice(1).join(' - ').trim();
    } else {
      title = line;
    }
    title = title.replace(WRAPPING_QUOTES_RE, '').trim();
    artist = artist.replace(WRAPPING_QUOTES_RE, '').trim();
    if (title.length === 0) {
      continue;
    }
    const key: string = `${title}|${artist}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    const song: ExternalSong = { title: title, artist: artist, durationSec: durationSec };
    out.push(song);
  }
  return out;
}

/** 文本粘贴的默认歌单名：「导入歌单 MM-DD」（方案 §4 命名规则） */
export function defaultImportName(): string {
  const d: Date = new Date();
  const mon: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const monStr: string = mon < 10 ? `0${mon}` : `${mon}`;
  const dayStr: string = day < 10 ? `0${day}` : `${day}`;
  return `导入歌单 ${monStr}-${dayStr}`;
}

//
// ───────────────────── ① 获取：链接直连（B / C 路线） ─────────────────────
//

/**
 * 网易云歌单链接识别。覆盖三种真实形态（2026-10-16 按用户**实际分享链接**扩宽）：
 *   · PC 网页  `music.163.com/#/playlist?id=123`、`music.163.com/playlist?id=123`
 *   · App 分享 `music.163.com/m/playlist?id=17747519380&creatorId=…`
 *     —— 旧正则要求 host 后**紧跟** `playlist`，`/m/` 这一节直接把它挡在门外，
 *     这正是「网易云显示未找到」的根因之一
 *   · 旧路径   `music.163.com/playlist/123`
 *
 * 判定与提取拆成两步：先认平台域名（NETEASE_HOST_RE），再依次找 `?id=` / `/playlist/id`。
 * 拆开的原因：`&creatorId=8557921139` 里也含 `Id=`，必须靠 `[?&#]` 紧邻约束才能不误伤
 * （`[\s\S]*?id=` 这种宽松写法会把 `creatorId` 的值当成歌单 ID）。
 */
const NETEASE_HOST_RE: RegExp = /(?:^|[^a-z0-9.-])(?:y\.)?music\.163\.com/i;
const NETEASE_ID_QUERY_RE: RegExp = /[?&#]id=(\d{4,})/;
const NETEASE_ID_PATH_RE: RegExp = /\/playlist\/(\d{4,})/;

/**
 * QQ 音乐歌单链接识别。覆盖：
 *   · PC 网页  `y.qq.com/n/ryqq/playlist/123`（旧）/ `y.qq.com/n/ryqq_v2/playlist/123`
 *   · App 分享 `i.y.qq.com/n2/m/share/details/taoge.html?id=123`
 *   · 短链落点 `i2.y.qq.com/n3/other/pages/details/playlist.html?…&id=123`
 *   · 短链本身 `c6.y.qq.com/base/fcgi-bin/u?__=5Atx6oMdqE5N` → 走 detectShareShortLink
 */
const QQ_HOST_RE: RegExp = /(?:^|[^a-z0-9.-])(?:[a-z0-9-]+\.)*y\.qq\.com/i;
const QQ_ID_QUERY_RE: RegExp = /[?&#]id=(\d{4,})/;
const QQ_DISSTID_RE: RegExp = /[?&#]disstid=(\d{4,})/;
const QQ_ID_PATH_RE: RegExp = /\/(?:ryqq|ryqq_v2)\/playlist\/(\d{4,})/;

/** QQ 音乐分享短链（`__=` 后是服务端短码，URL 里**不含**歌单 ID，必须靠 302 反查） */
const QQ_SHORT_LINK_RE: RegExp =
  /https?:\/\/(?:[a-z0-9-]+\.)*y\.qq\.com\/base\/fcgi-bin\/u\?__=[A-Za-z0-9]+/i;
/** 网易云分享短链（同样不含 ID） */
const NETEASE_SHORT_LINK_RE: RegExp = /https?:\/\/(?:[a-z0-9-]+\.)*163cn\.tv\/[A-Za-z0-9]+/i;
/** 落点页 HTML 里的歌单 ID（QQ 兜底：`og:url` / `<link rel=canonical>` 都带 `/playlist/<id>`） */
const HTML_PLAYLIST_ID_RE: RegExp = /\/playlist\/(\d{4,})/;

export function detectNeteasePlaylistId(text: string): string {
  if (!NETEASE_HOST_RE.test(text)) {
    return '';
  }
  const query: RegExpMatchArray | null = text.match(NETEASE_ID_QUERY_RE);
  if (query !== null) {
    return query[1];
  }
  const path: RegExpMatchArray | null = text.match(NETEASE_ID_PATH_RE);
  return path !== null ? path[1] : '';
}

export function detectQqPlaylistId(text: string): string {
  if (!QQ_HOST_RE.test(text)) {
    return '';
  }
  const query: RegExpMatchArray | null = text.match(QQ_ID_QUERY_RE);
  if (query !== null) {
    return query[1];
  }
  const disstid: RegExpMatchArray | null = text.match(QQ_DISSTID_RE);
  if (disstid !== null) {
    return disstid[1];
  }
  const path: RegExpMatchArray | null = text.match(QQ_ID_PATH_RE);
  return path !== null ? path[1] : '';
}

/**
 * 文本里是否含外部平台**链接**（含短链）。
 * 用途：把「粘了链接但提取不出 ID」（该给明确提示）与「粘了歌曲列表」（正常解析）
 * 区分开 —— 旧版对前者静默降级成「一行一首」，导致整串分享文本被当成一首歌去搜。
 */
export function isExternalPlaylistLink(text: string): boolean {
  return NETEASE_HOST_RE.test(text) || QQ_HOST_RE.test(text)
    || NETEASE_SHORT_LINK_RE.test(text) || QQ_SHORT_LINK_RE.test(text);
}

/** 平台分享短链（URL 里不含歌单 ID，需 302 反查） */
export interface ShareShortLink {
  url: string;
  /** `'qq'` 或 `'netease'`（决定 Referer 与 ID 提取规则） */
  platform: string;
}

/** 从文本里提取平台分享短链（无则 null） */
export function detectShareShortLink(text: string): ShareShortLink | null {
  const qq: RegExpMatchArray | null = text.match(QQ_SHORT_LINK_RE);
  if (qq !== null) {
    const link: ShareShortLink = { url: qq[0], platform: 'qq' };
    return link;
  }
  const netease: RegExpMatchArray | null = text.match(NETEASE_SHORT_LINK_RE);
  if (netease !== null) {
    const link: ShareShortLink = { url: netease[0], platform: 'netease' };
    return link;
  }
  return null;
}

/**
 * 解析分享短链 → 歌单 ID（空串 = 解析失败）。
 * 两级策略：① 禁用重定向读 302 的 `Location`（轻量，首选）；② 兜底跟随请求落点页，
 * 从 `og:url` / `canonical` 里提 `/playlist/<id>`（2026-10-16 实测两条路都可用，
 * ①可能因引擎不支持 maxRedirects 而失效，故保留 ②）。
 * 隐私红线同文件头：第三方请求必须 skipCookie + skipReferer。
 */
export async function resolveShareShortLink(link: ShareShortLink): Promise<string> {
  const isQq: boolean = link.platform === 'qq';
  const referer: string = isQq ? 'https://y.qq.com/' : 'https://music.163.com/';
  const location: string = await HttpUtil.probeRedirectLocation(link.url, {
    skipCookie: true,
    skipReferer: true,
    headers: { 'Referer': referer }
  });
  const fromLocation: string = isQq ? detectQqPlaylistId(location) : detectNeteasePlaylistId(location);
  if (fromLocation.length > 0) {
    return fromLocation;
  }
  const html: string = await HttpUtil.requestText(link.url, {
    skipCookie: true,
    skipReferer: true,
    headers: { 'Referer': referer }
  });
  const fromHtml: RegExpMatchArray | null = html.match(HTML_PLAYLIST_ID_RE);
  return fromHtml !== null ? fromHtml[1] : '';
}

/** 网易云 v3 详情每批 ID 数（50~100 实测可用，取上限减少请求数） */
const NETEASE_BATCH_SIZE: number = 100;

interface NeteaseTrackIdRef {
  id?: number;
}

interface NeteaseV6Playlist {
  name?: string;
  coverImgUrl?: string;
  trackIds?: NeteaseTrackIdRef[];
}

interface NeteaseV6Resp {
  code?: number;
  playlist?: NeteaseV6Playlist;
}

interface NeteaseSongRef {
  id: number;
}

interface NeteaseArRef {
  name?: string;
}

interface NeteaseV3Song {
  name?: string;
  ar?: NeteaseArRef[];
  /** 时长（ms） */
  dt?: number;
}

interface NeteaseV3Resp {
  code?: number;
  songs?: NeteaseV3Song[];
}

/**
 * 网易云歌单直连（方案 §6.1，2026-10-12 实测口径）：
 * ① /api/v6/playlist/detail 拿 name / coverImgUrl / trackIds（完整 ID 顺序表，
 *    其 tracks 数组只含前约 6 首，不能当全量用）；
 * ② /api/v3/song/detail?c=[{"id":N},…] 按 ID 分批查详情。
 * ⚠️ skipCookie + skipReferer + 平台自己的 Referer（隐私红线，见文件头）。
 */
export async function fetchNeteasePlaylist(id: string): Promise<ExternalPlaylist> {
  const v6: NeteaseV6Resp = await HttpUtil.requestJson<NeteaseV6Resp>(
    `https://music.163.com/api/v6/playlist/detail?id=${id}`,
    {
      skipCookie: true,
      skipReferer: true,
      headers: { 'Referer': 'https://music.163.com/' }
    }
  );
  const playlist: NeteaseV6Playlist | undefined = v6.playlist;
  if (v6.code !== 200 || !playlist) {
    throw new Error('网易云歌单接口返回异常');
  }
  const ids: number[] = [];
  const rawIds: NeteaseTrackIdRef[] = playlist.trackIds ?? [];
  for (let i = 0; i < rawIds.length; i++) {
    const n: number | undefined = rawIds[i].id;
    if (typeof n === 'number' && n > 0) {
      ids.push(n);
    }
  }
  const songs: ExternalSong[] = [];
  for (let start: number = 0; start < ids.length; start += NETEASE_BATCH_SIZE) {
    const end: number = Math.min(start + NETEASE_BATCH_SIZE, ids.length);
    const refs: NeteaseSongRef[] = [];
    for (let i: number = start; i < end; i++) {
      refs.push({ id: ids[i] });
    }
    const v3: NeteaseV3Resp = await HttpUtil.requestJson<NeteaseV3Resp>(
      `https://music.163.com/api/v3/song/detail?c=${encodeURIComponent(JSON.stringify(refs))}`,
      {
        skipCookie: true,
        skipReferer: true,
        headers: { 'Referer': 'https://music.163.com/' }
      }
    );
    if (v3.code !== 200 || !Array.isArray(v3.songs)) {
      throw new Error('网易云歌曲详情接口返回异常');
    }
    const list: NeteaseV3Song[] = v3.songs;
    // 响应体积大，只保留 name / ar / dt 三个字段（方案 §6.1 注意项）
    for (let i: number = 0; i < list.length; i++) {
      const s: NeteaseV3Song = list[i];
      const title: string = typeof s.name === 'string' ? s.name : '';
      if (title.length === 0) {
        continue;
      }
      const names: string[] = [];
      const ars: NeteaseArRef[] = s.ar ?? [];
      for (let a: number = 0; a < ars.length; a++) {
        const name: string | undefined = ars[a].name;
        if (typeof name === 'string' && name.length > 0 && names.indexOf(name) < 0) {
          names.push(name);
        }
      }
      const dt: number = typeof s.dt === 'number' ? s.dt : 0;
      const song: ExternalSong = {
        title: title,
        artist: names.join('/'),
        durationSec: Math.round(dt / 1000)
      };
      songs.push(song);
    }
  }
  return {
    name: typeof playlist.name === 'string' ? playlist.name : '',
    coverUrl: typeof playlist.coverImgUrl === 'string' ? playlist.coverImgUrl : '',
    songs: songs,
    sourceLabel: '网易云歌单'
  };
}

interface QqSingerRef {
  name?: string;
}

interface QqSong {
  songname?: string;
  singer?: QqSingerRef[];
  /** 时长（秒） */
  interval?: number;
}

interface QqCd {
  dissname?: string;
  logo?: string;
  songlist?: QqSong[];
}

interface QqResp {
  code?: number;
  cdlist?: QqCd[];
}

/**
 * QQ 音乐歌单直连（方案 §6.2，2026-10-12 实测口径）：一次拿全量纯 JSON
 * （json=1 生效无 JSONP 壳）。g_tk=5381 是固定匿名值，平台加校验就会整体失效
 * —— 失败由调用方降级提示「改用文本粘贴」。
 */
export async function fetchQqPlaylist(id: string): Promise<ExternalPlaylist> {
  const url: string =
    `https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg` +
    `?type=1&json=1&utf8=1&onlysong=0&disstid=${id}&format=json&g_tk=5381`;
  const resp: QqResp = await HttpUtil.requestJson<QqResp>(url, {
    skipCookie: true,
    skipReferer: true,
    headers: { 'Referer': 'https://y.qq.com/' }
  });
  const cds: QqCd[] = resp.cdlist ?? [];
  if (resp.code !== 0 || cds.length === 0 || !Array.isArray(cds[0].songlist)) {
    throw new Error('QQ 音乐歌单接口返回异常');
  }
  const songs: ExternalSong[] = [];
  const list: QqSong[] = cds[0].songlist ?? [];
  for (let i: number = 0; i < list.length; i++) {
    const s: QqSong = list[i];
    const title: string = typeof s.songname === 'string' ? s.songname : '';
    if (title.length === 0) {
      continue;
    }
    const names: string[] = [];
    const singers: QqSingerRef[] = s.singer ?? [];
    for (let a: number = 0; a < singers.length; a++) {
      const name: string | undefined = singers[a].name;
      if (typeof name === 'string' && name.length > 0 && names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    const song: ExternalSong = {
      title: title,
      artist: names.join('/'),
      durationSec: typeof s.interval === 'number' ? s.interval : 0
    };
    songs.push(song);
  }
  return {
    name: typeof cds[0].dissname === 'string' ? cds[0].dissname : '',
    coverUrl: typeof cds[0].logo === 'string' ? cds[0].logo : '',
    songs: songs,
    sourceLabel: 'QQ 音乐歌单'
  };
}

//
// ───────────────────── ② 匹配：打分与映射 ─────────────────────
//

/**
 * 搜索结果 → Track（SearchPage.mapSearch 同构，方案 §4 建议的公共层复用）。
 * 与页面私有版唯一差异：标题剥 <em> 高亮用 TextUtil.stripHtmlTags（同一实现）。
 */
export function mapSearchResultToTrack(item: SearchResultItem): Track {
  return buildTrack({
    id: item.bvid,
    bvid: item.bvid,
    aid: String(item.aid),
    title: stripHtmlTags(item.title),
    artist: item.author,
    upMid: item.mid !== undefined ? String(item.mid) : '',
    coverUrl: toHttpsUrl(item.pic),
    duration: parseDurationText(item.duration),
    playCount: item.play,
    pubdate: item.pubdate ?? 0
  });
}

/** 方案 §3.2 的标题噪声词（命中一条 −2，只罚一次） */
const NOISE_WORDS: string[] = ['翻唱', '鬼畜', '伴奏', '合集', '教程', '纯音乐'];
/** 强匹配阈值（≥5 自动选中） */
const SCORE_STRONG: number = 5;
/** 弱匹配阈值（3~4 进待确认） */
const SCORE_WEAK: number = 3;
/** 出局分（标题不含歌名，直接淘汰） */
const SCORE_OUT: number = -100;
/** B 站搜索风控码（RETRYABLE_BIZ_CODES 同款口径），命中即停 */
const RISK_CODES: number[] = [-352, -412, -509, -799];

/** 匹配用归一化：全角→半角、统一小写、去空白（cleanTitle 负责去括号噪声段） */
function normalizeForMatch(raw: string): string {
  let s: string = raw.replace(/[\uFF01-\uFF5E]/g, (ch: string): string => {
    return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0);
  });
  s = s.replace(/\u3000/g, ' ');
  s = s.toLowerCase();
  return s.replace(/\s+/g, '');
}

/**
 * 打分（方案 §3.2）：歌名包含 +3（必须项）；标题或 UP 主名含歌手名 +2；
 * 时长差 ≤5s +2 / ≤30s +1 / >60s −3；标题含噪声词 −2。
 * 返回 SCORE_OUT 表示出局。
 */
export function scoreCandidate(song: ExternalSong, item: SearchResultItem): number {
  const videoTitle: string = stripHtmlTags(item.title);
  const normVideo: string = normalizeForMatch(cleanTitle(videoTitle));
  const normSong: string = normalizeForMatch(song.title);
  if (normSong.length === 0 || !normVideo.includes(normSong)) {
    return SCORE_OUT;
  }
  let score: number = 3;
  const normArtist: string = normalizeForMatch(song.artist);
  if (normArtist.length > 0) {
    const inTitle: boolean = normVideo.includes(normArtist);
    const inAuthor: boolean = normalizeForMatch(item.author).includes(normArtist);
    if (inTitle || inAuthor) {
      score += 2;
    }
  }
  if (song.durationSec > 0) {
    const dur: number = parseDurationText(item.duration);
    if (dur > 0) {
      const diff: number = Math.abs(dur - song.durationSec);
      if (diff <= 5) {
        score += 2;
      } else if (diff <= 30) {
        score += 1;
      } else if (diff > 60) {
        score -= 3;
      }
    }
  }
  const lowerTitle: string = videoTitle.toLowerCase();
  for (let i: number = 0; i < NOISE_WORDS.length; i++) {
    if (lowerTitle.includes(NOISE_WORDS[i])) {
      score -= 2;
      break;
    }
  }
  return score;
}

interface ScoredCandidate {
  score: number;
  play: number;
  item: SearchResultItem;
}

/** 轮内去重缓存项（同曲直接复用，零请求） */
interface CachedMatch {
  status: ImportItemStatus;
  candidates: Track[];
  chosen: Track | null;
  failReason: string;
}

/** 去重键：归一化后的「歌名|歌手」（大小写/全角/空白差异不重复搜） */
function matchCacheKey(song: ExternalSong): string {
  return `${normalizeForMatch(song.title)}|${normalizeForMatch(song.artist)}`;
}

//
// ────────────────── ② 匹配：并发调度 + 打分与映射 ──────────────────
//

/**
 * 匹配并发与节流（推翻方案 §3.3 原「严格串行 + 每首硬等 1.0~1.5s」）。
 *
 * 实测依据（2026-10-16，PC UA + buvid 打 `/x/web-interface/wbi/search/type`）：
 *   · 单请求 rt ≈ 420ms（纯网络往返；page_size 20/30/50 耗时一致）
 *   · 并发 2 / 3 / 5 / 8 各打 16 首 → **全部 100% 成功、零风控**，墙钟近线性下降
 *     （2 并发 221ms/首 → 8 并发 61ms/首）
 * 也就是说旧实现那 1.25s/首的等待**全是自缚**：500 首要跑约 14 分钟，其中 13 分钟在睡。
 *
 * 现取「并发 4 + 全局最小间隔 200ms」= 稳态上限 5 QPS（真机弱网时由 rt 决定，更低），
 * 比旧版快约 8 倍，同时给风控留一个量级余量；RISK_CODES 命中即停 + resume 的兜底不变。
 * 若真机出现限流，只需调小 MATCH_CONCURRENCY / 调大 MATCH_MIN_GAP_MS，其余逻辑无需动。
 */
const MATCH_CONCURRENCY: number = 4;
const MATCH_MIN_GAP_MS: number = 200;
/** 单次搜索取的候选数（20→30：实测 rt 完全一致，候选多 50% 能提高命中率、减少手工复核） */
const MATCH_PAGE_SIZE: number = 30;
/**
 * 广播节流（ms）：并发后每秒会 notify 近 20 次，每次都是「新建 items 数组」的全量快照，
 * 而向导页是 `@StorageLink` 全量订阅 → 匹配中会持续重渲染。
 * 故 worker 路径一律走 notifyThrottled（最多每 120ms 推一次），
 * 而 start / stop / resume / 用户操作走 notify 立即推，状态切换不掉帧。
 */
const IMPORT_NOTIFY_MS: number = 120;

function importSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

export function emptyImportState(): ImportState {
  return {
    phase: ImportPhase.IDLE,
    total: 0,
    processed: 0,
    strong: 0,
    weak: 0,
    missing: 0,
    skipped: 0,
    currentTitle: '',
    riskMessage: '',
    sourceName: '',
    sourceCoverUrl: '',
    items: []
  };
}

/**
 * 导入任务管理器（单例，DownloadManager 的 queue/pump 同款思路）：
 * 离开向导页任务继续跑；进度经 AppStorage(STORE_IMPORT_STATE) 广播新快照；
 * 风控即停保留进度，可 resume 续跑。
 */
export class ImportTaskManager {
  private static instance: ImportTaskManager | null = null;

  static getInstance(): ImportTaskManager {
    if (ImportTaskManager.instance === null) {
      ImportTaskManager.instance = new ImportTaskManager();
    }
    return ImportTaskManager.instance;
  }

  private state: ImportState = emptyImportState();
  /** 取号游标（items 下标）：worker 取走即自增；resume 从它继续 */
  private cursor: number = 0;
  /** 已完成计数（并发下不能再用 cursor 当 processed：cursor 是「已取走」） */
  private done: number = 0;
  private running: boolean = false;
  /** 当前在飞的条目下标（只用于拼「正在匹配」文案与风控回退） */
  private activeIndexes: number[] = [];
  /** 全局最小请求间隔的共享时间戳（节流，见 MATCH_MIN_GAP_MS） */
  private lastRequestAt: number = 0;
  /** 命中风控时置真：其余在飞 worker 的失败不作数（保持 PENDING 待 resume） */
  private riskHit: boolean = false;
  /** 风控回退水位：resume 时游标回到这里（在飞条目都不会被跳过） */
  private riskFloor: number = 0;
  /** 轮内同曲去重：同一首歌不重复搜（歌单内重复曲直接复用结果） */
  private matchCache: Map<string, CachedMatch> = new Map<string, CachedMatch>();
  /** 节流广播是否已挂起（见 notifyThrottled） */
  private notifyPending: boolean = false;

  getState(): ImportState {
    return this.state;
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 开始新一轮匹配（旧任务必须已结束；sourceName / coverUrl 供落库默认值） */
  start(songs: ExternalSong[], sourceName: string, coverUrl: string): void {
    if (this.running) {
      return;
    }
    const items: ImportItem[] = [];
    for (let i: number = 0; i < songs.length; i++) {
      const item: ImportItem = {
        song: songs[i],
        status: ImportItemStatus.PENDING,
        candidates: [],
        chosen: null,
        failReason: ''
      };
      items.push(item);
    }
    this.state = {
      phase: ImportPhase.MATCHING,
      total: items.length,
      processed: 0,
      strong: 0,
      weak: 0,
      missing: 0,
      skipped: 0,
      currentTitle: '',
      riskMessage: '',
      sourceName: sourceName,
      sourceCoverUrl: coverUrl,
      items: items
    };
    this.cursor = 0;
    this.done = 0;
    this.activeIndexes = [];
    this.riskHit = false;
    this.riskFloor = 0;
    this.lastRequestAt = 0;
    this.matchCache.clear();
    this.running = true;
    this.notify();
    this.run();
  }

  /** 续跑（仅 STOPPED / RISK 可续；从中断的游标继续） */
  resume(): void {
    if (this.running) {
      return;
    }
    const phase: ImportPhase = this.state.phase;
    if (phase !== ImportPhase.STOPPED && phase !== ImportPhase.RISK) {
      return;
    }
    this.state.phase = ImportPhase.MATCHING;
    this.state.riskMessage = '';
    this.riskHit = false;
    this.activeIndexes = [];
    this.lastRequestAt = 0;
    this.running = true;
    this.notify();
    this.run();
  }

  /** 用户主动中断：保留已完成进度，剩余条目停在 PENDING */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    if (this.state.phase === ImportPhase.MATCHING) {
      this.state.phase = ImportPhase.STOPPED;
    }
    this.notify();
  }

  /** 待复核条目（弱匹配 + 未找到）的 items 下标，按原顺序 */
  pendingReviewIndexes(): number[] {
    const out: number[] = [];
    const items: ImportItem[] = this.state.items;
    for (let i: number = 0; i < items.length; i++) {
      const st: ImportItemStatus = items[i].status;
      if (st === ImportItemStatus.WEAK || st === ImportItemStatus.MISSING) {
        out.push(i);
      }
    }
    return out;
  }

  /** 复核时手动搜索（路线 C）：替换该条目的候选列表（取前 3 条，不做打分过滤） */
  async searchManual(index: number, keyword: string): Promise<Track[]> {
    const items: ImportItem[] = this.state.items;
    if (index < 0 || index >= items.length) {
      return [];
    }
    const item: ImportItem = items[index];
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return item.candidates;
    }
    const resp: SearchResponse = await searchVideo(kw, 1, 20);
    const candidates: Track[] = [];
    const list: SearchResultItem[] = resp.result ?? [];
    for (let i: number = 0; i < list.length && candidates.length < 3; i++) {
      candidates.push(mapSearchResultToTrack(list[i]));
    }
    item.candidates = candidates;
    this.notify();
    return candidates;
  }

  /** 复核选中某候选：置为 STRONG（可导入计数随之 +1） */
  setChosen(index: number, track: Track): void {
    const items: ImportItem[] = this.state.items;
    if (index < 0 || index >= items.length) {
      return;
    }
    items[index].chosen = track;
    items[index].status = ImportItemStatus.STRONG;
    this.recount();
    this.notify();
  }

  /** 复核跳过某条 */
  skipItem(index: number): void {
    const items: ImportItem[] = this.state.items;
    if (index < 0 || index >= items.length) {
      return;
    }
    items[index].status = ImportItemStatus.SKIPPED;
    items[index].chosen = null;
    this.recount();
    this.notify();
  }

  /**
   * 落库（方案 §4）：收集全部 chosen → 按 bvid 去重 → 500 上限截断 →
   * 重名加「导入」后缀 → createPlaylist + updatePlaylist 一次落盘（两次 persist，
   * 绝不逐首 addTrackToPlaylist）。成功后任务复位（快照清空回 IDLE）。
   */
  finish(playlistName: string, coverUrl: string): Playlist | null {
    const chosen: Track[] = [];
    const seen: Set<string> = new Set<string>();
    const items: ImportItem[] = this.state.items;
    for (let i: number = 0; i < items.length; i++) {
      const t: Track | null = items[i].chosen;
      if (t === null || seen.has(t.bvid)) {
        continue;
      }
      seen.add(t.bvid);
      const slim: Track = slimTrack(t);
      slim.audioUrl = '';
      slim.localFilePath = '';
      chosen.push(slim);
    }
    if (chosen.length === 0) {
      return null;
    }
    const tracks: Track[] = chosen.slice(0, PLAYLIST_MAX_ITEMS);
    const base: string = playlistName.trim();
    const fallback: string = base.length > 0 ? base : defaultImportName();
    let finalName: string = fallback;
    const existing: Playlist[] = getPlaylists();
    for (let i: number = 0; i < existing.length; i++) {
      if (existing[i].name.trim() === finalName) {
        finalName = `${fallback} 导入`;
        break;
      }
    }
    // 文本粘贴无来源封面 → 首曲封面兜底（方案 §4）
    const cover: string = coverUrl.trim().length > 0 ? coverUrl.trim() : tracks[0].coverUrl;
    const created: Playlist = createPlaylist({ name: finalName, coverUrl: cover });
    const playlist: Playlist = Object.assign({}, created, { tracks: tracks });
    updatePlaylist(playlist);
    this.reset();
    return playlist;
  }

  /** 放弃本次任务（清快照回 IDLE；正在跑时先停） */
  reset(): void {
    this.running = false;
    this.state = emptyImportState();
    this.cursor = 0;
    this.done = 0;
    this.activeIndexes = [];
    this.riskHit = false;
    this.riskFloor = 0;
    this.matchCache.clear();
    this.notify();
  }

  /**
   * 并发调度：起 N 个 worker 共享同一个取号游标（`cursor` 取走即自增，单线程下天然无锁）。
   * worker 只在「做完手上这一首」后才退出，故停止/风控时 `cursor` 之前的条目必定已定状态，
   * resume 语义与旧串行版完全一致（不跳曲、不重复标记）。
   */
  private async run(): Promise<void> {
    const items: ImportItem[] = this.state.items;
    const left: number = items.length - this.cursor;
    const workerCount: number = Math.min(MATCH_CONCURRENCY, Math.max(1, left));
    const pool: Promise<void>[] = [];
    for (let i: number = 0; i < workerCount; i++) {
      pool.push(this.workerLoop());
    }
    await Promise.all(pool);
    if (this.riskHit) {
      // 风控：游标退回「在飞条目里的最小下标」，被中断的条目仍是 PENDING → resume 重跑这批
      this.cursor = this.riskFloor;
      this.riskHit = false;
      this.riskFloor = 0;
      this.activeIndexes = [];
      this.state.currentTitle = '';
      this.state.processed = this.done;
      this.recount();
      this.notify();
      return;
    }
    if (this.running) {
      this.running = false;
      this.activeIndexes = [];
      this.state.currentTitle = '';
      if (this.state.phase === ImportPhase.MATCHING) {
        this.state.phase = ImportPhase.DONE;
      }
      this.notify();
    }
  }

  /** 单个 worker：循环「取号 → 匹配 → 计数」，直到无号可取或被停 / 风控 */
  private async workerLoop(): Promise<void> {
    const items: ImportItem[] = this.state.items;
    while (this.running) {
      const idx: number = this.cursor;
      if (idx >= items.length) {
        return;
      }
      this.cursor = idx + 1;
      const item: ImportItem = items[idx];
      this.activeIndexes.push(idx);
      this.publishCurrent();
      this.notifyThrottled();
      try {
        await this.matchItem(item);
      } catch (e) {
        if (e instanceof BiliApiError && RISK_CODES.indexOf(e.code) >= 0) {
          this.hitRisk(idx);
          this.exitWorker(idx);
          return;
        }
        if (this.riskHit) {
          // 风控期间其它在飞请求的失败不作数：条目保持 PENDING，等 resume 重跑
          this.exitWorker(idx);
          return;
        }
        item.status = ImportItemStatus.MISSING;
        item.failReason = '搜索失败，可稍后手动重试';
      }
      this.done++;
      this.state.processed = this.done;
      this.exitWorker(idx);
    }
  }

  /** worker 退出前的统一收尾：摘掉在飞标记、刷新文案与计数 */
  private exitWorker(idx: number): void {
    this.dropActive(idx);
    this.recount();
    this.publishCurrent();
    this.notifyThrottled();
  }

  /** 命中风控：停轮 + 记录回退水位（取所有在飞条目的最小下标） */
  private hitRisk(idx: number): void {
    this.riskHit = true;
    this.running = false;
    this.state.phase = ImportPhase.RISK;
    this.state.riskMessage = 'B 站搜索被限流，已保留当前进度，稍后可继续';
    let floor: number = idx;
    for (let i: number = 0; i < this.activeIndexes.length; i++) {
      if (this.activeIndexes[i] < floor) {
        floor = this.activeIndexes[i];
      }
    }
    this.riskFloor = floor;
  }

  /** 全局节流：保证相邻两次「请求发起」间隔 ≥ MATCH_MIN_GAP_MS（单线程下无竞态） */
  private async throttle(): Promise<void> {
    const now: number = Date.now();
    const earliest: number = this.lastRequestAt + MATCH_MIN_GAP_MS;
    this.lastRequestAt = now > earliest ? now : earliest;
    const wait: number = earliest - now;
    if (wait > 0) {
      await importSleep(wait);
    }
  }

  private dropActive(idx: number): void {
    const p: number = this.activeIndexes.indexOf(idx);
    if (p >= 0) {
      this.activeIndexes.splice(p, 1);
    }
  }

  /** 拼「正在匹配」文案：并发下取最近 3 首，多出的收成「等 N 首」 */
  private publishCurrent(): void {
    const items: ImportItem[] = this.state.items;
    const show: number = Math.min(3, this.activeIndexes.length);
    let out: string = '';
    for (let i: number = 0; i < show; i++) {
      const t: string = items[this.activeIndexes[i]].song.title;
      out = out.length === 0 ? t : `${out}、${t}`;
    }
    if (this.activeIndexes.length > show) {
      out = `${out} 等 ${this.activeIndexes.length} 首`;
    }
    this.state.currentTitle = out;
  }

  /** 匹配一首（带轮内去重缓存）：同曲直接复用上次结果，零请求 */
  private async matchItem(item: ImportItem): Promise<void> {
    const key: string = matchCacheKey(item.song);
    const hit: CachedMatch | undefined = this.matchCache.get(key);
    if (hit !== undefined) {
      item.status = hit.status;
      item.candidates = hit.candidates.slice();
      item.chosen = hit.chosen;
      item.failReason = hit.failReason;
      return;
    }
    await this.matchOne(item);
    const cached: CachedMatch = {
      status: item.status,
      candidates: item.candidates.slice(),
      chosen: item.chosen,
      failReason: item.failReason
    };
    this.matchCache.set(key, cached);
  }

  /** 匹配一首：搜「歌名 歌手」（无结果降级「歌名」）→ 打分 → 分档（方案 §3.1） */
  private async matchOne(item: ImportItem): Promise<void> {
    const song: ExternalSong = item.song;
    let keyword: string = song.title;
    if (song.artist.length > 0) {
      keyword = `${song.title} ${song.artist}`;
    }
    await this.throttle();
    let resp: SearchResponse = await searchVideo(keyword, 1, MATCH_PAGE_SIZE);
    if (resp.result.length === 0 && song.artist.length > 0) {
      await this.throttle();
      resp = await searchVideo(song.title, 1, MATCH_PAGE_SIZE);
    }
    const list: SearchResultItem[] = resp.result ?? [];
    if (list.length === 0) {
      item.status = ImportItemStatus.MISSING;
      item.failReason = '没有搜到相关视频';
      return;
    }
    const scored: ScoredCandidate[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const score: number = scoreCandidate(song, list[i]);
      if (score > SCORE_OUT) {
        const c: ScoredCandidate = { score: score, play: list[i].play, item: list[i] };
        scored.push(c);
      }
    }
    if (scored.length === 0) {
      item.status = ImportItemStatus.MISSING;
      item.failReason = '没有找到足够相似的版本';
      return;
    }
    // 分高优先；同分优先播放量高的（方案 §3.2）
    scored.sort((a: ScoredCandidate, b: ScoredCandidate): number => {
      if (b.score !== a.score) {
        return b.score - a.score;
      }
      return b.play - a.play;
    });
    const candidates: Track[] = [];
    const topN: number = Math.min(3, scored.length);
    for (let i: number = 0; i < topN; i++) {
      candidates.push(mapSearchResultToTrack(scored[i].item));
    }
    const best: number = scored[0].score;
    if (best >= SCORE_STRONG) {
      item.status = ImportItemStatus.STRONG;
      item.candidates = candidates;
      item.chosen = candidates[0];
    } else if (best >= SCORE_WEAK) {
      item.status = ImportItemStatus.WEAK;
      item.candidates = candidates;
      item.chosen = null;
    } else {
      item.status = ImportItemStatus.MISSING;
      item.candidates = [];
      item.chosen = null;
      item.failReason = '相似度不足，建议手动搜索';
    }
  }

  private recount(): void {
    let strong: number = 0;
    let weak: number = 0;
    let missing: number = 0;
    let skipped: number = 0;
    const items: ImportItem[] = this.state.items;
    for (let i: number = 0; i < items.length; i++) {
      switch (items[i].status) {
        case ImportItemStatus.STRONG:
          strong++;
          break;
        case ImportItemStatus.WEAK:
          weak++;
          break;
        case ImportItemStatus.MISSING:
          missing++;
          break;
        case ImportItemStatus.SKIPPED:
          skipped++;
          break;
        default:
          break;
      }
    }
    this.state.strong = strong;
    this.state.weak = weak;
    this.state.missing = missing;
    this.state.skipped = skipped;
  }

  /** 广播快照（新对象 + 新 items 数组，@StorageLink 才能感知变化） */
  private notify(): void {
    AppStorage.setOrCreate(STORE_IMPORT_STATE, this.snapshot());
  }

  /** 节流广播（worker 高频路径用；收尾/状态切换仍走 notify 立即推） */
  private notifyThrottled(): void {
    if (this.notifyPending) {
      return;
    }
    this.notifyPending = true;
    setTimeout((): void => {
      this.notifyPending = false;
      this.notify();
    }, IMPORT_NOTIFY_MS);
  }

  private snapshot(): ImportState {
    const items: ImportItem[] = [];
    const source: ImportItem[] = this.state.items;
    for (let i: number = 0; i < source.length; i++) {
      const it: ImportItem = source[i];
      const copy: ImportItem = {
        song: it.song,
        status: it.status,
        candidates: it.candidates.slice(),
        chosen: it.chosen,
        failReason: it.failReason
      };
      items.push(copy);
    }
    return {
      phase: this.state.phase,
      total: this.state.total,
      processed: this.state.processed,
      strong: this.state.strong,
      weak: this.state.weak,
      missing: this.state.missing,
      skipped: this.state.skipped,
      currentTitle: this.state.currentTitle,
      riskMessage: this.state.riskMessage,
      sourceName: this.state.sourceName,
      sourceCoverUrl: this.state.sourceCoverUrl,
      items: items
    };
  }
}
