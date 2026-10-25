/**
 * 播放页封面取色（降采样直方图聚类 + 双色调）。
 *
 * effectKit.createColorPicker().getLargestProportionColor() 单点取色对
 * 黑白 / 大色块封面发灰发闷、单色渐变层次感弱，故本文件在 TaskPool 内对
 * 48×48 降采样封面做 4bit/通道量化直方图聚类（4096 桶），按「饱和度^1.5 ×
 * √count × 明度窗」评分选出 vibrant 主色，另挑 muted 深辅色，双色调驱动
 * 播放页背景渐变（Spotify Palette 风格）。effectKit 路径在
 * PlayerInfoComponent 作兜底。
 *
 * ⚠️ @Concurrent 限制（同 utils/CacheFsTasks.ets，必须遵守）：
 *   - 只能是本文件顶层函数，不得写成闭包 / 类方法 / 箭头函数；
 *   - 不得捕获外层变量、禁止自引用（es2abc 报「not import variable or local
 *     variable」），全部换算逻辑内联在任务函数体内；
 *   - 参数与返回值必须可序列化（ArrayBuffer → 命名 interface 满足）；
 *   - 只能通过 taskpool.execute(函数引用, ...) 调用，禁止主线程直接同步调用。
 */

/**
 * 取色结果（taskpool 结构化克隆回传的命名载体）。
 * main：展示用 vibrant 主色 [r, g, b]（0-255，已做平滑亮度重映射）；
 * deep：muted 深辅色 [r, g, b]（0-255，恒比主色暗、同色系）；
 * dark：主色明暗（写 STORE_PLAYER_BG_DARK，状态栏/顶栏消费）；
 * ok：false = 无有效像素（全透明/空数据），调用方走 effectKit 兜底。
 */
export interface CoverPaletteResult {
  ok: boolean;
  main: number[];
  deep: number[];
  dark: boolean;
}

/**
 * 封面取色任务（TaskPool 专用）：48×48 RGBA_8888 缓冲 → 量化直方图 → 双色调。
 * 输入像素约 2.3K、候选桶 ≤64，任务内仅四个 16KB Int32Array 的定量分配，
 * TaskPool 上毫秒级完成，主线程只收最终 RGB。
 */
@Concurrent
function extractCoverPaletteTask(buffer: ArrayBuffer, width: number, height: number): CoverPaletteResult {
  const fail: CoverPaletteResult = { ok: false, main: [0, 0, 0], deep: [0, 0, 0], dark: true };
  const total: number = width * height;
  if (width <= 0 || height <= 0 || buffer.byteLength < total * 4) {
    return fail;
  }
  const px: Uint8Array = new Uint8Array(buffer);
  // 4bit/通道量化 → 4096 桶；各桶累计像素数与 r/g/b 真实总量（桶均色即簇心色）
  const counts: Int32Array = new Int32Array(4096);
  const rs: Int32Array = new Int32Array(4096);
  const gs: Int32Array = new Int32Array(4096);
  const bs: Int32Array = new Int32Array(4096);
  let seen: number = 0;
  for (let i: number = 0; i < total; i++) {
    const o: number = i * 4;
    if (px[o + 3] < 128) {
      continue; // 半透明以下像素不参与取色（圆角/透明边）
    }
    const r: number = px[o];
    const g: number = px[o + 1];
    const b: number = px[o + 2];
    const key: number = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    counts[key]++;
    rs[key] += r;
    gs[key] += g;
    bs[key] += b;
    seen++;
  }
  if (seen === 0) {
    return fail;
  }
  // 非空桶按 count 降序，取前 64 作候选（占比大簇优先，长尾杂色滤除）
  const idx: number[] = [];
  for (let k: number = 0; k < 4096; k++) {
    if (counts[k] > 0) {
      idx.push(k);
    }
  }
  idx.sort((a: number, b: number): number => counts[b] - counts[a]);
  const candCount: number = Math.min(64, idx.length);

  // —— 逐候选桶算 HSB 评分：main（vibrant）/ deep（muted 深辅色）各选一桶
  let mainH: number = 0;
  let mainS: number = 0;
  let mainV: number = 0;
  let mainScore: number = 0;
  let mainFound: boolean = false;
  let deepH: number = 0;
  let deepS: number = 0;
  let deepV: number = 0;
  let deepScore: number = 0;
  let deepFound: boolean = false;
  for (let c: number = 0; c < candCount; c++) {
    const k: number = idx[c];
    const cnt: number = counts[k];
    const r: number = rs[k] / cnt;
    const g: number = gs[k] / cnt;
    const b: number = bs[k] / cnt;
    // RGB → HSB
    const maxc: number = Math.max(r, g, b);
    const minc: number = Math.min(r, g, b);
    const d: number = maxc - minc;
    const v: number = maxc / 255;
    const s: number = maxc <= 0 ? 0 : d / maxc;
    let h: number = 0;
    if (d > 0) {
      if (maxc === r) {
        h = (((g - b) / d) + (g < b ? 6 : 0)) / 6;
      } else if (maxc === g) {
        h = (((b - r) / d) + 2) / 6;
      } else {
        h = (((r - g) / d) + 4) / 6;
      }
    }
    // main 评分：饱和度^1.5 × √count × 明度窗（0.25~0.75 满权 1，向 0.05/0.95
    // 线性衰减）—— 近黑无色彩感、近白压亮后发灰，都压权；纯灰 s=0 天然零分，
    // 让位彩色簇（黑白封面由下方 mainFound 兜底接管）
    let bw: number = 0;
    if (v >= 0.05 && v <= 0.95) {
      if (v < 0.25) {
        bw = (v - 0.05) / 0.2;
      } else if (v <= 0.75) {
        bw = 1;
      } else {
        bw = 1 - (v - 0.75) / 0.2;
      }
    }
    const score: number = Math.pow(s, 1.5) * Math.sqrt(cnt) * bw;
    if (score > mainScore) {
      mainScore = score;
      mainFound = true;
      mainH = h;
      mainS = s;
      mainV = v;
    }
    // deep 评分：三角明度窗（峰 0.225，范围 0.15~0.30）× 饱和度适中因子 × √count
    // —— muted 深色簇独立于 main 评选，同图既有亮彩又有暗簇时两色天然分层
    let dw: number = 0;
    if (v >= 0.15 && v <= 0.3) {
      dw = 1 - Math.abs(v - 0.225) / 0.075;
    }
    if (dw > 0) {
      const dScore: number = dw * (0.5 + 0.5 * s) * Math.sqrt(cnt);
      if (dScore > deepScore) {
        deepScore = dScore;
        deepFound = true;
        deepH = h;
        deepS = s;
        deepV = v;
      }
    }
  }
  // main 兜底：整幅近黑/近白（明度窗全 0，如纯黑白封面）→ 取占比最大桶，
  // 平滑亮度重映射自会把亮度归位（保色相保饱和度，灰封面得到中性深灰底）
  if (!mainFound) {
    const k: number = idx[0];
    const cnt: number = counts[k];
    const r: number = rs[k] / cnt;
    const g: number = gs[k] / cnt;
    const b: number = bs[k] / cnt;
    const maxc: number = Math.max(r, g, b);
    const minc: number = Math.min(r, g, b);
    const d: number = maxc - minc;
    mainV = maxc / 255;
    mainS = maxc <= 0 ? 0 : d / maxc;
    mainH = 0;
    if (d > 0) {
      if (maxc === r) {
        mainH = (((g - b) / d) + (g < b ? 6 : 0)) / 6;
      } else if (maxc === g) {
        mainH = (((b - r) / d) + 2) / 6;
      } else {
        mainH = (((r - g) / d) + 4) / 6;
      }
    }
  }
  // main 平滑亮度重映射：原亮度 [0,1] → 目标 [0.28,0.45] 线性插值 —— 取代
  // dealColor「b≥0.4→0.3」一刀切跳变，保色相保饱和度、保亮度相对序
  const mainBright: number = 0.28 + 0.17 * mainV;
  // deep 兜底：候选里无 muted 深色簇（亮色封面常态）→ 由重映射后的 main 派生
  //（亮度 ×0.45 + 饱和度 ×0.7），保证深辅色恒比主色暗、同色系
  if (!deepFound) {
    deepH = mainH;
    deepS = mainS * 0.7;
    deepV = mainBright * 0.45;
  }
  // HSB → RGB（main / deep 各一次，逐段内联）
  const hues: number[] = [mainH, deepH];
  const sats: number[] = [mainS, deepS];
  const vals: number[] = [mainBright, deepV];
  const outR: number[] = [0, 0];
  const outG: number[] = [0, 0];
  const outB: number[] = [0, 0];
  for (let j: number = 0; j < 2; j++) {
    const c: number = vals[j] * sats[j];
    const x: number = c * (1 - Math.abs((hues[j] * 6) % 2 - 1));
    const m: number = vals[j] - c;
    const sec: number = Math.floor(hues[j] * 6);
    let r0: number = 0;
    let g0: number = 0;
    let b0: number = 0;
    if (sec === 0) {
      r0 = c;
      g0 = x;
    } else if (sec === 1) {
      r0 = x;
      g0 = c;
    } else if (sec === 2) {
      g0 = c;
      b0 = x;
    } else if (sec === 3) {
      g0 = x;
      b0 = c;
    } else if (sec === 4) {
      r0 = x;
      b0 = c;
    } else {
      r0 = c;
      b0 = x;
    }
    outR[j] = Math.round((r0 + m) * 255);
    outG[j] = Math.round((g0 + m) * 255);
    outB[j] = Math.round((b0 + m) * 255);
  }
  const main: number[] = [outR[0], outG[0], outB[0]];
  const deep: number[] = [outR[1], outG[1], outB[1]];
  // 主色明暗（0.299/0.587/0.114 加权亮度）< 0.5 → 深底（状态栏/顶栏浅色图标）
  const lum: number = (0.299 * main[0] + 0.587 * main[1] + 0.114 * main[2]) / 255;
  const result: CoverPaletteResult = { ok: true, main: main, deep: deep, dark: lum < 0.5 };
  return result;
}

/** 统一 rgba 字符串产出（与 STORE_PLAYER_IMAGE_COLOR 的 rgba 格式钉死约定一致） */
export function buildRgba(rgb: number[], alpha: number): string {
  return `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${alpha})`;
}

export { extractCoverPaletteTask };
