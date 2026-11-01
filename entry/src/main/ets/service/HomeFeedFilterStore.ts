/**
 * 「首页筛选」规则存储（文件型 JSON，只作用于首页「推荐」tab）。
 *
 * 规则体量不受 Preferences 单值 8192 字节预算约束（名单/方案可自由增长），
 * 落盘走 `filesDir/home_feed_filter.json`，与 IntroSkipStore / HomeFeedCacheStore
 * 同一套写法：内存优先 + 防抖落盘 + 全 IO try/catch 永不抛 + 损坏即弃回默认。
 *
 * 与 UI 的契约：任何规则变更（设置页保存 / 列表快捷屏蔽 / 档位切换）都走
 * updateFeedFilterConfig —— 它负责两件事：防抖落盘、递增 STORE_FEED_FILTER_REV
 * 版本号。推荐 tab 是常驻 Tab，aboutToAppear 只触发一次，规则改完返回全靠
 * 这个版本号 @Watch 驱动「从 recommendRaw 即时重滤」（不发网络请求）。
 *
 * 时序说明：initRest 与 loadContent 并行 —— init 完成前 getFeedFilterConfig
 * 返回默认配置（无任何规则 = 全透传，无害）；init 装载真实规则后补一次 rev
 * 递增，把可能已渲染的推荐列表用真实规则重滤一遍。
 */

import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { FeedFilterConfig, parseFeedFilterConfig, defaultFeedFilterConfig, copyFeedFilterConfig }
  from '../model/FeedFilterModels';
import { STORE_FEED_FILTER_REV } from '../common/Constants';

/** 防抖落盘间隔：设置页连续微调 / 批量增删名单时合一次写 */
const FLUSH_DELAY_MS: number = 500;

let storePath: string = '';
let config: FeedFilterConfig = defaultFeedFilterConfig();
let inited: boolean = false;
let flushTimer: number = -1;

/**
 * 初始化：装载 home_feed_filter.json 进内存。AppContainer.initRest 调用，
 * 同步执行（毫秒级）。幂等：重复调用只生效一次（防 initRest 重试链双跑）。
 */
export function initHomeFeedFilterStore(context: common.Context): void {
  if (inited) {
    return;
  }
  inited = true;
  try {
    storePath = `${context.filesDir}/home_feed_filter.json`;
    if (fs.accessSync(storePath)) {
      const raw: string = fs.readTextSync(storePath);
      // 损坏即弃：解析/校验任何畸形都回默认配置（等价于「未开启筛选」）
      config = parseFeedFilterConfig(raw);
    }
  } catch (e) {
    console.error(`initHomeFeedFilterStore failed: ${JSON.stringify(e)}`);
    // 装载失败不致命：配置从默认开始，后续写入照常累积（覆盖写会自愈）
  }
  // 装载完成补一次版本号递增：首页若已按默认配置（全透传）渲染，
  // 这次 bump 触发 @Watch 用真实规则重滤；首页未渲染时无害（rev 无人订阅）
  bumpFeedFilterRev();
}

function persist(): void {
  if (storePath.length === 0) {
    return;
  }
  let file: fs.File | null = null;
  try {
    file = fs.openSync(storePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(config));
  } catch (e) {
    console.error(`persist home feed filter failed: ${JSON.stringify(e)}`);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (closeErr) {
        console.error(`close home feed filter file failed: ${JSON.stringify(closeErr)}`);
      }
    }
  }
}

function scheduleFlush(): void {
  if (flushTimer !== -1) {
    return;
  }
  flushTimer = setTimeout((): void => {
    flushTimer = -1;
    persist();
  }, FLUSH_DELAY_MS);
}

/** 递增规则版本号：推荐 tab @StorageProp + @Watch 收到后从 recommendRaw 重滤 */
export function bumpFeedFilterRev(): void {
  const cur: number = AppStorage.get<number>(STORE_FEED_FILTER_REV) ?? 0;
  AppStorage.setOrCreate(STORE_FEED_FILTER_REV, cur + 1);
}

/**
 * 读当前配置（返回深拷贝副本：调用方在副本上编辑，改完走 updateFeedFilterConfig
 * 提交，防止绕过 store 直改内存对象导致落盘/版本号漏发）。
 */
export function getFeedFilterConfig(): FeedFilterConfig {
  return copyFeedFilterConfig(config);
}

/**
 * 提交新配置：内存替换（拷贝隔离调用方后续改动）+ 防抖落盘 + 版本号递增。
 * 未 init（卡片进程等无主进程编排的场景）静默降级：只进内存，不落盘不广播。
 */
export function updateFeedFilterConfig(next: FeedFilterConfig): void {
  config = copyFeedFilterConfig(next);
  if (storePath.length > 0) {
    scheduleFlush();
  }
  bumpFeedFilterRev();
}
