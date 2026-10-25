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
import { Track, LyricResult } from '../../model/MusicModels';
import { getLyricForTrack, getLyricOffset } from '../../api/LyricsApi';
import { initLyricCache } from '../LyricCacheStore';
import { initPlayerStateStore, readPlayerStateFile, PersistedPlayerState } from '../PlayerStateStore';
import { initPreferences } from '../../preferences/AppPreferences';
import { FormCardName } from '../../widget/model/CardFormConstant';

const TAG: string = 'CardPayloadBuilder';
/** 无歌词 / 纯音乐时的固定文案 */
export const LYRIC_FALLBACK: string = '纯音乐，请欣赏';
/** 默认品牌色（封面取色失败 / 无封面时的卡片底色） */
const DEFAULT_COLOR_HEX: string = 'fb7299';
const DEFAULT_COLOR_RGBA: string = 'rgba(251, 114, 153, 1)';
/** 心动歌词卡展示行数（连续随机截取） */
const HEART_LYRIC_LINE_COUNT: number = 4;

/** 封面取色结果 */
export class CoverColor {
  hex: string = DEFAULT_COLOR_HEX;
  rgba: string = DEFAULT_COLOR_RGBA;
}

/** 歌词窗口（动态歌词卡推送单元） */
export class LyricWindow {
  lines: string[] = [LYRIC_FALLBACK];
  index: number = 0;
}

/** 卡片全量载荷（formBindingData 直接消费；字段名即卡片页 LocalStorage 键名） */
export class CardPayload {
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
}

/** 构建结果：payload + 待关闭的封面 fd（-1 = 无封面） */
export class CardBuildResult {
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
export function dealColor(rRGB: number, gRGB: number, bRGB: number): number[] {
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
export async function computeCoverColor(buffer: ArrayBuffer): Promise<CoverColor> {
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
    const safeId: string = track.id.replace(/[^0-9A-Za-z_-]/g, '_');
    const path: string = `${context.tempDir}/card_cover_${safeId}.jpg`;
    coverFile = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(coverFile.fd, buffer);
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

/** 溢出页（liveForm）封面结果：临时文件路径 + 主色 */
export class OverflowCoverResult {
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
export async function pickRandomLyricLines(track: Track): Promise<string[]> {
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
 * 无播放快照（首次安装 / 从未播放）返回 null，调用方跳过推送。
 */
export async function buildCardPayload(context: common.Context, formName: string): Promise<CardBuildResult | null> {
  await ensureCardEnv(context);
  const state: PersistedPlayerState | null = await readCardSnapshot();
  if (state === null || state.currentTrack === null) {
    return null;
  }
  const track: Track = state.currentTrack;
  const result: CardBuildResult = await prepareCover(context, track);
  const payload: CardPayload = result.payload;
  payload.isPlay = state.isPlaying;
  payload.title = track.title;
  payload.singer = track.artist;
  payload.songId = track.id;
  payload.isCollected = track.isLiked;
  if (formName === FormCardName.LYRICS) {
    payload.lrcArray = await pickRandomLyricLines(track);
  } else if (formName === FormCardName.DYNAMIC_LYRICS) {
    const lyric: LyricResult | null = await getLyricForTrack(track);
    const win: LyricWindow = buildLyricWindow(lyric, track, state.progress);
    payload.lrcArray = win.lines;
    payload.currentLyricIndex = 0;
  }
  return result;
}

/** 全量推送一张卡片（推送后关闭封面 fd） */
export async function pushCardToForm(context: common.Context, formId: string, formName: string): Promise<void> {
  let coverFd: number = -1;
  try {
    const result: CardBuildResult | null = await buildCardPayload(context, formName);
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
  }
}
