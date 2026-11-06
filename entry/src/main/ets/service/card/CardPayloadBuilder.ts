/**
 * 卡片载荷构建与推送（Form 扩展进程 / UIAbility 进程共用）。
 *
 * 职责：
 *  · 从 PlayerStateStore 快照（player_state.json 双文件）读当前曲目 —— Form 进程
 *    与主进程同一沙箱，读同一份文件，天然双进程自给；
 *  · 歌词：getLyricForTrack（缓存优先，含 24h miss 闸）；心动卡随机连续 4 行、
 *    动态歌词卡取「当前行 + 下一行」窗口；无歌词回落『纯音乐，请欣赏』；
 *  · 封面：下载 coverUrl → 取沉浸主色（effectKit ColorPicker + HSB dealColor，
 *    移植示例 ImageUtils 算法）→ 写临时文件 → formImages fd 随 payload 推给
 *    卡片渲染进程；推送完成由调用方关闭 fd；
 *  · formProvider.updateForm 统一出口（全量 push / 轻量播放态 / 轻量歌词窗口）。
 */

import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Track, LyricResult } from '../../model/MusicModels';
import { getLyricForTrack, getLyricOffset } from '../../api/LyricsApi';
import { initLyricCache } from '../LyricCacheStore';
import { initPlayerStateStore, readPlayerStateFile, PersistedPlayerState } from '../PlayerStateStore';
import { initPreferences, AppPreferences } from '../../preferences/AppPreferences';
import { FormCardName } from '../../widget/model/CardFormConstant';

const TAG: string = 'CardPayloadBuilder';
/** 无歌词 / 纯音乐时的固定文案 */
const LYRIC_FALLBACK: string = '纯音乐，请欣赏';
/** 默认品牌色（封面取色失败 / 无封面时的卡片底色） */
export const DEFAULT_COLOR_HEX: string = 'fb7299';
const DEFAULT_COLOR_RGBA: string = 'rgba(251, 114, 153, 1)';
/** 心动歌词卡展示行数（连续随机截取） */
const HEART_LYRIC_LINE_COUNT: number = 4;
/** formProvider「卡片不存在」错误码（16501）：卡片已被用户从桌面移除，推送方应清理死记录 */
export const FORM_NOT_EXIST_CODE: number = 16501;

/**
 * 卡片已被移除（updateForm 报 16501）时上抛给调用方：
 * 调用方据此从 CardFormStore 删除该 formId 死记录，止损后续每次
 * 播放态 / 进度 / 歌词推送对同一路径的无效更新。
 * 其余错误不上抛（维持「出口自吞」既有契约，调用方无需逐处兜底）。
 */
function rethrowIfFormGone(e: Object): void {
  const be: BusinessError = e as BusinessError;
  if (be.code === FORM_NOT_EXIST_CODE) {
    throw be;
  }
}

/** 封面取色结果 */
class CoverColor {
  hex: string = DEFAULT_COLOR_HEX;
  rgba: string = DEFAULT_COLOR_RGBA;
}

/** 歌词窗口（动态歌词卡推送单元） */
class LyricWindow {
  lines: string[] = [LYRIC_FALLBACK];
  index: number = 0;
}

/** 卡片全量载荷（formBindingData 直接消费；字段名即卡片页 LocalStorage 键名） */
class CardPayload {
  formId: string = '';
  isPlay: boolean = false;
  title: string = '';
  singer: string = '';
  songId: string = '';
  isCollected: boolean = false;
  hasCover: boolean = false;
  musicCover: string = 'cover';
  formImages: Record<string, number> = {};
  imageColor: string = DEFAULT_COLOR_RGBA;
  imageColorHex: string = DEFAULT_COLOR_HEX;
  lrcArray: string[] = [LYRIC_FALLBACK];
  currentLyricIndex: number = 0;
  progress: number = 0;
  duration: number = 0;
  /** 锁屏卡片：定时停止活跃（sleepTimerEnd > now） */
  sleepOn: boolean = false;
  /** 锁屏卡片：定时结束文案（「HH:mm 停」，推送前格式化好） */
  sleepText: string = '定时';
}

/** 构建结果：payload + 待关闭的封面 fd（-1 = 无封面） */
class CardBuildResult {
  payload: CardPayload = new CardPayload();
  coverFd: number = -1;
}

/** 轻量推送：播放态 */
class PlayStatusData {
  isPlay: boolean = false;
}

/** 轻量推送：歌词窗口（动态歌词卡） */
class LyricWindowData {
  lrcArray: string[] = [];
  currentLyricIndex: number = 0;
  isPlay: boolean = false;
}

/** 轻量推送：播放进度（外屏播控卡） */
class ProgressData {
  progress: number = 0;
  duration: number = 0;
  isPlay: boolean = false;
}

/** 锁屏卡片定时停止态（全量 / 轻量推送共用读取） */
class SleepStateData {
  sleepOn: boolean = false;
  sleepText: string = '定时';
}

/** 两位数字符串（不足补零：9 → '09'） */
function pad2(value: number): string {
  const clamped: number = Math.max(0, Math.min(59, Math.round(value)));
  const raw: string = clamped.toString();
  return raw.length < 2 ? `0${raw}` : raw;
}

/**
 * 读锁屏卡片定时停止态：AppSettings.sleepTimerEnd（跨进程落盘字段）> 当前
 * 时刻 → 活跃，文案「HH:mm 停」此处格式化好（卡片内不做时间运算）。
 */
function readLockSleepState(): SleepStateData {
  const data: SleepStateData = new SleepStateData();
  const end: number = AppPreferences.getSettings().sleepTimerEnd;
  if (end > Date.now()) {
    data.sleepOn = true;
    const d: Date = new Date(end);
    data.sleepText = `${pad2(d.getHours())}:${pad2(d.getMinutes())} 停`;
  }
  return data;
}

/**
 * 卡片运行环境（按进程幂等）：Preferences（歌词源 cookie / 偏好）、
 * 歌词缓存目录、播放快照目录。UIAbility 进程三项早已就位，重复 init 无害；
 * Form 扩展进程冷起时由此补齐。
 */
let cardEnvPromise: Promise<void> | null = null;

export function ensureCardEnv(context: common.Context): Promise<void> {
  if (cardEnvPromise === null) {
    const pending: Promise<void> = (async (): Promise<void> => {
      await initPreferences(context);
      initLyricCache(context);
      initPlayerStateStore(context);
    })();
    pending.catch((): void => {
      if (cardEnvPromise === pending) {
        cardEnvPromise = null;
      }
    });
    cardEnvPromise = pending;
  }
  return cardEnvPromise;
}

/** 两位十六进制（不足补零，示例原实现 9 → '9' 会拼出 5 位色值） */
function toHex2(value: number): string {
  const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
  const raw: string = clamped.toString(16);
  return raw.length < 2 ? `0${raw}` : raw;
}

/**
 * HSB 沉浸色算法（移植示例 ImageUtils.dealColor）：压亮度 + 保色相，
 * 输出适合做卡片渐变底色的 [r, g, b]。
 */
function dealColor(rRGB: number, gRGB: number, bRGB: number): number[] {
  const max: number = Math.max(Math.max(rRGB, gRGB), bRGB);
  const min: number = Math.min(Math.min(rRGB, gRGB), bRGB);
  const sHSB: number = max === 0 ? 0 : (max - min) / max;
  let bHSB: number = max / 255;
  let hHSB: number = 0;
  if (max === min) {
    hHSB = 0;
  } else if (max === rRGB && gRGB >= bRGB) {
    hHSB = (60 * (gRGB - bRGB)) / (max - min) + 0;
  } else if (max === rRGB && gRGB < bRGB) {
    hHSB = (60 * (gRGB - bRGB)) / (max - min) + 360;
  } else if (max === gRGB) {
    hHSB = (60 * (bRGB - rRGB)) / (max - min) + 120;
  } else {
    hHSB = (60 * (rRGB - gRGB)) / (max - min) + 240;
  }

  if (bHSB >= 0.4) {
    bHSB = 0.3;
  } else if (bHSB >= 0.2) {
    bHSB -= 0.1;
  } else {
    bHSB = bHSB + 0.2;
  }

  const i: number = Math.floor((hHSB / 60) % 6);
  const f: number = hHSB / 60 - i;
  const p: number = bHSB * (1 - sHSB);
  const q: number = bHSB * (1 - f * sHSB);
  const t: number = bHSB * (1 - (1 - f) * sHSB);
  let r: number = rRGB;
  let g: number = gRGB;
  let b: number = bRGB;
  switch (i) {
    case 0:
      r = bHSB;
      g = t;
      b = p;
      break;
    case 1:
      r = q;
      g = bHSB;
      b = p;
      break;
    case 2:
      r = p;
      g = bHSB;
      b = t;
      break;
    case 3:
      r = p;
      g = q;
      b = bHSB;
      break;
    case 4:
      r = t;
      g = p;
      b = bHSB;
      break;
    case 5:
      r = bHSB;
      g = p;
      b = q;
      break;
    default:
      break;
  }
  return [Math.floor(r * 255.0), Math.floor(g * 255.0), Math.floor(b * 255.0)];
}

/** 封面取色（失败回落品牌色，绝不抛出） */
async function computeCoverColor(buffer: ArrayBuffer): Promise<CoverColor> {
  const result: CoverColor = new CoverColor();
  let pixelMap: image.PixelMap | undefined = undefined;
  try {
    const source: image.ImageSource = image.createImageSource(buffer);
    pixelMap = source.createPixelMapSync();
    const picker: effectKit.ColorPicker = await effectKit.createColorPicker(pixelMap);
    const main: effectKit.Color = picker.getMainColorSync();
    const rgb: number[] = dealColor(main.red, main.green, main.blue);
    result.rgba = `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, 1)`;
    result.hex = `${toHex2(rgb[0])}${toHex2(rgb[1])}${toHex2(rgb[2])}`;
  } catch (e) {
    console.error(`[${TAG}] computeCoverColor failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
  } finally {
    if (pixelMap !== undefined) {
      pixelMap.release().catch((): void => {
      });
    }
  }
  return result;
}

/** 下载封面 → 写临时文件 → 返回打开的 fd + 主色（fd 由调用方关） */
async function prepareCover(context: common.Context, track: Track): Promise<CardBuildResult> {
  const result: CardBuildResult = new CardBuildResult();
  if (track.coverUrl.length === 0) {
    return result;
  }
  let request: http.HttpRequest | null = null;
  let coverFile: fs.File | null = null;
  try {
    request = http.createHttp();
    const resp: http.HttpResponse = await request.request(track.coverUrl, {
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    if (resp.responseCode !== http.ResponseCode.OK || !(resp.result instanceof ArrayBuffer)) {
      console.error(`[${TAG}] prepareCover bad response code=${resp.responseCode} url=${track.coverUrl}`);
      return result;
    }
    const buffer: ArrayBuffer = resp.result;
    const color: CoverColor = await computeCoverColor(buffer);
    const safeId: string = coverSafeId(track.id);
    const path: string = `${context.tempDir}/card_cover_${safeId}.jpg`;
    coverFile = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(coverFile.fd, buffer);
    // 主色落盘小文件：溢出页（liveForm）本地命中封面时同步取底色用（读写失败
    // 仅留痕，不影响推送 —— 溢出页读不到回落品牌色）。
    try {
      const colorFile: fs.File = fs.openSync(`${context.tempDir}/card_cover_color.txt`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(colorFile.fd, color.hex);
      fs.closeSync(colorFile);
    } catch (e) {
      console.error(`[${TAG}] write cover color failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    }
    // 图片标识每次推送必须不同：formImages 渲染端以「imgName 是否变化」决定是否刷新图片
    const imgKey: string = `cover_${Date.now()}`;
    const formImages: Record<string, number> = {};
    formImages[imgKey] = coverFile.fd;
    const payload: CardPayload = result.payload;
    result.coverFd = coverFile.fd;
    payload.hasCover = true;
    payload.musicCover = imgKey;
    payload.formImages = formImages;
    payload.imageColor = color.rgba;
    payload.imageColorHex = color.hex;
    coverFile = null; // fd 所有权移交调用方
  } catch (e) {
    console.error(`[${TAG}] prepareCover failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    if (coverFile !== null) {
      try {
        fs.closeSync(coverFile);
      } catch (closeErr) {
        console.error(`[${TAG}] close cover file failed: ${JSON.stringify(closeErr)}`);
      }
    }
  } finally {
    if (request !== null) {
      request.destroy();
    }
  }
  return result;
}

/** 读播放快照（Form 进程 / 主进程同沙箱同文件） */
export async function readCardSnapshot(): Promise<PersistedPlayerState | null> {
  return readPlayerStateFile();
}

/** 封面临时文件名用的曲目 id 清洗（prepareCover 落盘文件与溢出页本地复用同一路径） */
function coverSafeId(trackId: string): string {
  return trackId.replace(/[^0-9A-Za-z_-]/g, '_');
}

/** 溢出页本地封面命中结果：临时文件路径 + 卡片底色主色 */
export class OverflowLocalCover {
  path: string = '';
  colorHex: string = DEFAULT_COLOR_HEX;
}

/**
 * 读 Form 进程推卡时落盘的本地封面（card_cover_<safeId>.jpg + 主色小文件）：
 * 溢出页（liveForm）优先走这里秒显封面 —— 点播放 = 继续播放不打断当前曲目，
 * 本地文件与溢出页应显示的封面必然同曲；未命中（tempDir 被系统清理 / 首次推送
 * 尚未完成）返回 null，调用方回落网络下载路径。
 */
export function readLocalOverflowCover(context: common.Context, track: Track): OverflowLocalCover | null {
  if (track.coverUrl.length === 0) {
    return null;
  }
  const path: string = `${context.tempDir}/card_cover_${coverSafeId(track.id)}.jpg`;
  try {
    fs.accessSync(path);
  } catch (e) {
    return null;
  }
  const result: OverflowLocalCover = new OverflowLocalCover();
  result.path = path;
  try {
    const stored: string = fs.readTextSync(`${context.tempDir}/card_cover_color.txt`).trim();
    result.colorHex = stored.length > 0 ? stored : DEFAULT_COLOR_HEX;
  } catch (e) {
    // 主色文件缺失 / 损坏：回落品牌色（不挡封面显示）
    result.colorHex = DEFAULT_COLOR_HEX;
  }
  return result;
}

/** 溢出页（liveForm）封面结果：临时文件路径 + 主色 */
class OverflowCoverResult {
  path: string = '';
  color: CoverColor = new CoverColor();
}

/**
 * 下载封面到临时文件并取主色（溢出页用；与 formImages fd 无关，
 * 页面直接以沙箱路径作 backgroundImage 渲染）。
 */
export async function downloadCoverToTemp(context: common.Context,
  coverUrl: string): Promise<OverflowCoverResult | null> {
  if (coverUrl.length === 0) {
    return null;
  }
  let request: http.HttpRequest | null = null;
  let coverFile: fs.File | null = null;
  try {
    request = http.createHttp();
    const resp: http.HttpResponse = await request.request(coverUrl, {
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    if (resp.responseCode !== http.ResponseCode.OK || !(resp.result instanceof ArrayBuffer)) {
      return null;
    }
    const buffer: ArrayBuffer = resp.result;
    const result: OverflowCoverResult = new OverflowCoverResult();
    result.color = await computeCoverColor(buffer);
    const path: string = `${context.tempDir}/card_overflow_cover.jpg`;
    coverFile = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(coverFile.fd, buffer);
    fs.closeSync(coverFile);
    coverFile = null;
    result.path = path;
    return result;
  } catch (e) {
    console.error(`[${TAG}] downloadCoverToTemp failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    if (coverFile !== null) {
      try {
        fs.closeSync(coverFile);
      } catch (closeErr) {
        console.error(`[${TAG}] close overflow cover failed: ${JSON.stringify(closeErr)}`);
      }
    }
    return null;
  } finally {
    if (request !== null) {
      request.destroy();
    }
  }
}

/** 心动歌词卡：当前曲目歌词随机连续 4 行 */
async function pickRandomLyricLines(track: Track): Promise<string[]> {
  const lyric: LyricResult | null = await getLyricForTrack(track);
  if (lyric === null || lyric.instrumental || lyric.lines.length === 0) {
    return [LYRIC_FALLBACK];
  }
  const texts: string[] = [];
  for (let i = 0; i < lyric.lines.length; i++) {
    const text: string = lyric.lines[i].text.trim();
    if (text.length > 0) {
      texts.push(text);
    }
  }
  if (texts.length === 0) {
    return [LYRIC_FALLBACK];
  }
  if (texts.length <= HEART_LYRIC_LINE_COUNT) {
    return texts;
  }
  const maxStart: number = texts.length - HEART_LYRIC_LINE_COUNT;
  const start: number = Math.floor(Math.random() * (maxStart + 1));
  return texts.slice(start, start + HEART_LYRIC_LINE_COUNT);
}

/** 由缓存的歌词结果构建「当前行 + 下一行」窗口（含歌词偏移，秒） */
export function buildLyricWindow(lyric: LyricResult | null, track: Track, progressSec: number): LyricWindow {
  const win: LyricWindow = new LyricWindow();
  if (lyric === null || lyric.instrumental || lyric.lines.length === 0) {
    return win;
  }
  const offsetSec: number = getLyricOffset(track.id) / 1000;
  const pos: number = progressSec + offsetSec;
  let idx: number = 0;
  for (let i = 0; i < lyric.lines.length; i++) {
    if (lyric.lines[i].time <= pos) {
      idx = i;
    } else {
      break;
    }
  }
  win.index = idx;
  const cur: string = lyric.lines[idx].text.trim();
  const next: string = idx + 1 < lyric.lines.length ? lyric.lines[idx + 1].text.trim() : '';
  if (cur.length === 0) {
    return win;
  }
  win.lines = next.length > 0 ? [cur, next] : [cur];
  return win;
}

/** 取某曲目歌词（CardPublisher 自管缓存时直接用 getLyricForTrack 即可） */
export function fetchCardLyric(track: Track): Promise<LyricResult | null> {
  return getLyricForTrack(track);
}

/**
 * 构建指定卡片的完整载荷（快照 + 歌词 + 封面 fd + 主色）。
 * state 注入实时快照（主进程 CardPublisher 换歌全量推专用——换歌瞬间
 * player_state.json 落盘晚于切歌通知数百 ms，盘上还是旧曲，必须喂内存值）；
 * 默认 null = 走盘自给（Form 扩展进程冷起 / 主进程启动回填场景）。
 * 无播放快照（首次安装 / 从未播放）返回 null，调用方跳过推送。
 */
async function buildCardPayload(context: common.Context, formName: string,
  state: PersistedPlayerState | null = null): Promise<CardBuildResult | null> {
  await ensureCardEnv(context);
  // 注入优先、盘读兜底：Form 进程无主进程 AppStorage，只能读盘
  const snapshot: PersistedPlayerState | null = state !== null ? state : await readCardSnapshot();
  const track: Track | null = snapshot !== null ? snapshot.currentTrack : null;
  if (track === null) {
    // 锁屏卡片例外：无播放快照（首次安装 / 从未播放）也要可推 —— chip 独立
    // 于曲目工作，回落占位文案；其余卡片无快照返回 null 由调用方跳过
    if (formName !== FormCardName.LOCK_SCREEN) {
      return null;
    }
    const empty: CardBuildResult = new CardBuildResult();
    empty.payload.title = 'BiliMusic';
    empty.payload.singer = '未在播放';
    const emptySleep: SleepStateData = readLockSleepState();
    empty.payload.sleepOn = emptySleep.sleepOn;
    empty.payload.sleepText = emptySleep.sleepText;
    return empty;
  }
  const result: CardBuildResult = await prepareCover(context, track);
  const payload: CardPayload = result.payload;
  payload.isPlay = snapshot !== null ? snapshot.isPlaying : false;
  payload.title = track.title;
  payload.singer = track.artist;
  payload.songId = track.id;
  payload.isCollected = track.isLiked;
  payload.progress = snapshot !== null ? snapshot.progress : 0;
  payload.duration = snapshot !== null ? snapshot.duration : 0;
  if (formName === FormCardName.LOCK_SCREEN) {
    const sleep: SleepStateData = readLockSleepState();
    payload.sleepOn = sleep.sleepOn;
    payload.sleepText = sleep.sleepText;
  } else if (formName === FormCardName.LYRICS) {
    payload.lrcArray = await pickRandomLyricLines(track);
  } else if (formName === FormCardName.DYNAMIC_LYRICS) {
    const lyric: LyricResult | null = await getLyricForTrack(track);
    const win: LyricWindow = buildLyricWindow(lyric, track, snapshot !== null ? snapshot.progress : 0);
    payload.lrcArray = win.lines;
    payload.currentLyricIndex = 0;
  }
  return result;
}

/** 全量推送一张卡片（推送后关闭封面 fd）；state 语义见 buildCardPayload */
export async function pushCardToForm(context: common.Context, formId: string, formName: string,
  state: PersistedPlayerState | null = null): Promise<void> {
  let coverFd: number = -1;
  try {
    const result: CardBuildResult | null = await buildCardPayload(context, formName, state);
    if (result === null) {
      return;
    }
    coverFd = result.coverFd;
    result.payload.formId = formId;
    const formMsg: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(result.payload);
    await formProvider.updateForm(formId, formMsg);
    console.info(`[${TAG}] updateForm ok formId=${formId} formName=${formName}`);
  } catch (e) {
    console.error(`[${TAG}] pushCardToForm failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    rethrowIfFormGone(e);
  } finally {
    if (coverFd >= 0) {
      try {
        fs.closeSync(coverFd);
      } catch (closeErr) {
        console.error(`[${TAG}] close cover fd failed: ${JSON.stringify(closeErr)}`);
      }
    }
  }
}

/** 轻量推送：播放态变化（不重取封面/歌词） */
export async function pushPlayStatusToForm(formId: string, isPlay: boolean): Promise<void> {
  try {
    const data: PlayStatusData = new PlayStatusData();
    data.isPlay = isPlay;
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  } catch (e) {
    console.error(`[${TAG}] pushPlayStatusToForm failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    rethrowIfFormGone(e);
  }
}

/** 轻量推送：动态歌词窗口（歌词行变化时） */
export async function pushLyricWindowToForm(formId: string, lines: string[],
  currentLyricIndex: number, isPlay: boolean): Promise<void> {
  try {
    const data: LyricWindowData = new LyricWindowData();
    data.lrcArray = lines;
    data.currentLyricIndex = currentLyricIndex;
    data.isPlay = isPlay;
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  } catch (e) {
    console.error(`[${TAG}] pushLyricWindowToForm failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    rethrowIfFormGone(e);
  }
}

/** 轻量推送：播放进度（外屏播控卡进度条，主进程 1s 节拍调用） */
export async function pushProgressToForm(formId: string, progress: number,
  duration: number, isPlay: boolean): Promise<void> {
  try {
    const data: ProgressData = new ProgressData();
    data.progress = progress;
    data.duration = duration;
    data.isPlay = isPlay;
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  } catch (e) {
    console.error(`[${TAG}] pushProgressToForm failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    rethrowIfFormGone(e);
  }
}

/**
 * 轻量推送：锁屏卡片定时停止态（定时开启 / 取消时只推 sleepOn + sleepText，
 * 不重取封面 / 快照）。读盘自给（AppSettings.sleepTimerEnd），Form 扩展进程
 * 与主进程均可调用。
 */
export async function pushLockCardStateToForm(context: common.Context, formId: string): Promise<void> {
  try {
    await ensureCardEnv(context);
    const data: SleepStateData = readLockSleepState();
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
  } catch (e) {
    console.error(`[${TAG}] pushLockCardStateToForm failed: ${e instanceof Error ? e.message : JSON.stringify(e)}`);
    rethrowIfFormGone(e);
  }
}
