/**
 * Canvas 歌词渲染组件（移植自 audio-interaction-master 的 LrcView）。
 *
 * 逐行绘制 + 400ms ease-in-out 补间滚动 + 上下渐隐遮罩，视觉效果远好于 List 方案。
 * 逐字特效（LetterGradient / LetterScaleGradient / LetterStar）需要 KRC 逐字
 * 时间轴；本项目 LyricsApi 只有行级时间轴，固定使用 LyricScrollEffect.Line。
 *
 * ── 时间轴同步（2026-10-21 改造，见 design/歌词同步问题诊断与方案.md）──
 * 入参 `lyricMilliSecondsTime` 来自 STORE_PROGRESS，而那条链路为了不拖垮进度条
 * 是按 **500ms 分桶**推送的（MusicPlayer.PROGRESS_PUSH_INTERVAL_MS）。
 * 直接把桶值当播放位置判行，换行平均滞后 171~235ms、最坏 500ms，
 * 且行间隔 < 500ms 的密集歌（说唱 / 日文短句）会**整行跳过**。
 *
 * 本组件的做法是「tick 校正 + 本机时钟外推 + 换行精准唤醒」：
 *   1. 每来一个 tick 就把它当作新的锚点（值 + 到达时刻），
 *      用 `锚点值 + (now - 锚点时刻) × 播放倍率` 算出「现在放到哪儿了」，
 *      精度从 500ms 提到 ~20ms（只受定时器精度限制），**不增加任何声明式重渲染**；
 *   2. 判行后算出「距下一行起点还有多久」，用一次 setTimeout 睡到那一刻再判，
 *      不做常驻 60fps 轮询（每行只唤醒 1~2 次，比原先每个 tick 全量重绘更省）；
 *   3. 外推上限 1.2s：tick 丢了（卡顿 / 后台冻结）就不再往前推，等下一个 tick 校正，
 *      避免「卡住时歌词越走越远，恢复后猛回头」。
 *
 * 行级判据用二分查「最后一个 lineStartTime <= 当前时刻」的行（左闭右开）。
 * 旧实现是线性扫描 + 右边界 `>=`，因为行时长 = 下一行起点 − 本行起点，
 * `>=` 会让上一行在下一行起点那一刻仍然命中 → 换行永远再晚一个 tick。
 *
 * 移植适配（按本项目 ArkTS 规范）：
 *   - 默认导出改具名导出；去掉 hypium / MediaService Logger 依赖（console 即可）；
 *   - AnimatorResult 延迟到 aboutToAppear 创建（属性初始化时 UIContext 未就绪）；
 *   - onAreaChange 的 Area.width 是 Length 联合类型，补 parseAreaLength 归一化；
 *   - 修正参考工程 onAreaChange 宽/高分支里画布偏移取正负号不一致的问题（统一 -offset）。
 */

import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { LrcEntry } from './LrcEntry';
import { angleToRadian } from './LrcUtils';
import { Rectangle, LyricTopPosition, LyricScrollEffect } from './LyricConst';
import { STORE_PLAYBACK_SPEED, STORE_PLAYBACK_SPEED_ENABLED } from '../common/Constants';

const NONE_LINE: number = -1;
const STAR_ANGLE_NUMBER: number = 5;
const EMPTY_LYRIC: LrcEntry = {
  lineStartTime: 0,
  lineDuration: 0,
  lineWords: '此歌曲为纯音乐，请您欣赏',
  words: []
};
/** 逐字渐变的进度间隔（在极小的区间内从高亮色跳回常规色） */
const GRADIENT_PROGRESS_SPACE = 0.0000001;
const GRADIENT_PROGRESS_MAX = 1 - GRADIENT_PROGRESS_SPACE;

/**
 * 本机时钟外推的上限（ms）。
 * tick 正常 500ms 一次，超过这个值说明 tick 丢了（缓冲卡顿 / 后台冻结）——
 * 此时停止外推，等下一个 tick 把锚点拉回来，宁可歌词停在原地也不要越走越远。
 */
const EXTRAPOLATE_CAP_MS: number = 1200;
/** 换行唤醒的延后量（ms）：确保唤醒时已经跨过换行点，而不是差几毫秒判成上一行 */
const WAKE_LEAD_MS: number = 6;
/** 单次唤醒的最小延迟（ms）：避免 delay<=0 时退化成 0ms 忙等 */
const WAKE_MIN_MS: number = 10;
/**
 * 单次唤醒的最大延迟（ms）：只是兜底。
 * 正常情况下每个 tick（500ms）都会重排定时器，远到不了这个上限。
 */
const WAKE_MAX_MS: number = 1000;

/**
 * 副行（翻译 / 罗马音）字号比例：相对常规行字号。
 * 翻译行必须明显小于主歌词，否则「两句一样大」会让人分不清哪句在唱。
 */
const SUB_TEXT_SCALE: number = 0.68;
/** 副行与上一行文字之间的间距（vp） */
const SUB_TEXT_GAP: number = 3;

/** Area.width/height 是 Length（number|string|Resource），归一化成 number（vp） */
function parseAreaLength(len: Length): number {
  if (typeof len === 'number') {
    return len;
  }
  if (typeof len === 'string') {
    return Number.parseFloat(len);
  }
  return 0;
}

@Component
export struct LrcView {
  @Prop @Watch('onTimeUpdated') lyricMilliSecondsTime: number = 0;
  @Prop @Watch('onLyricUpdated') mLrcEntryList: Array<LrcEntry> = [];
  @Prop @Watch('onEffectChanged') lyricScrollEffect: LyricScrollEffect = LyricScrollEffect.Line;
  /** 播放状态：暂停时挂起滚动补间，同时冻结本机时钟外推 */
  @Prop @Watch('playLyrics') isPlay: boolean = false;
  lyricTopPosition: LyricTopPosition = LyricTopPosition.Top;

  private readonly mNormalTextColor: string = '#99ffffff';
  private viewWidth: number = 360;
  private viewHeight: number = 500;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private mCurrentLine: number = NONE_LINE;
  private readonly TEXT_ADD_SIZE: number = 2;
  private lyricRectangle: Rectangle = new Rectangle(0, 0, 0, 0);
  /** 首行歌词的初始 Y（Middle 时取内容区上部约 1/2.8 处） */
  private initFirstLineY: number = 0;
  /** 滚动补间（aboutToAppear 里经 UIContext 创建） */
  private animator: AnimatorResult | null = null;
  private mNormalTextSize: number = 20;
  private mDividerHeight: number = 24;
  private mCurrentTextSize: number = 24;
  private fontFamily: string = 'HarmonyHeiTi';
  private mCurrentTextColor: string = '#FFFFFF';
  private fontWeight: string = 'bold';
  private paddingLeft: number = 0;
  private paddingRight: number = 0;
  private paddingTop: number = 0;
  private paddingBottom: number = 0;
  private lrcWidth: number = 0;
  private lrcHeight: number = 0;
  private lrcX: number = 0;
  private lrcY: number = 0;
  private curCanvasOffsetY: number = 0;
  private starAverageAngle: number = 0;
  private starOutCircleAngle: number = 0;
  private starInCircleAngle: number = 0;
  private starsPath2D: Path2D = new Path2D();
  private starsColor: string = '#18BBFC';
  /** 上一次处理过的 tick 值（ms）：用来区分「新 tick」与「其它原因触发的重绘」 */
  private lastTickMs: number = -1;
  /** 当前锚点值（lyricMilliSecondsTime）到达时的本机时刻，外推的基准 */
  private baseLocalMs: number = 0;
  /** 换行精准唤醒的定时器 id；-1 = 未排 */
  private wakeTimer: number = -1;

  aboutToAppear(): void {
    this.baseLocalMs = Date.now();
    const options: AnimatorOptions = {
      duration: 400,
      easing: 'linear',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    };
    this.animator = this.getUIContext().createAnimator(options);
  }

  aboutToDisappear(): void {
    this.cancelWake();
    if (this.animator !== null) {
      this.animator.finish();
      this.animator = null;
    }
  }

  /**
   * 滚动到目标偏移：从当前偏移补间到 -desOffsetY（ease-in-out 起收都缓，换行不突兀）。
   *
   * 暂停态改为**瞬时对齐**：补间动画是自走的 400ms，暂停时若仍播放，
   * 拖动进度条会出现「歌词自己滚一段」的错觉（历史 bug，顺手修掉）。
   */
  startAnimator(desOffsetY: number): void {
    if (this.animator !== null) {
      this.animator.finish();
    }
    if (!this.isPlay) {
      this.drawContent(-desOffsetY);
      return;
    }
    if (this.animator === null) {
      return;
    }
    const options: AnimatorOptions = {
      duration: 400,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: this.curCanvasOffsetY,
      end: -desOffsetY
    };
    this.animator = this.getUIContext().createAnimator(options);
    this.animator.onFrame = (value: number): void => {
      this.drawContent(value);
    };
    this.animator.onCancel = (): void => {
    };
    this.animator.onFinish = (): void => {
    };
    this.animator.play();
  }

  /**
   * 播放状态变化。
   *
   * 恢复播放：把外推基准重置到「此刻」，否则暂停期间累积的 elapsed 会被一次性
   * 外推出去（暂停 10 分钟 = 歌词瞬间跑到结尾）。
   * 暂停：冻结外推（audioNow 直接返回锚点值）并停掉换行唤醒，
   * 但**不重绘** —— 锚点值比真实暂停位置最多早 500ms，此时重绘会让歌词倒退一行。
   */
  playLyrics(): void {
    if (this.isPlay) {
      this.baseLocalMs = Date.now();
      if (this.animator !== null) {
        this.animator.play();
      }
      this.judgeAndDraw(this.audioNow());
      this.scheduleWake();
    } else {
      this.cancelWake();
      if (this.animator !== null) {
        this.animator.pause();
      }
    }
  }

  /** 当前播放倍率：开关关闭或读取异常时按 1.0（与 MusicPlayer.applySpeedOnPrepared 同口径） */
  private playRate(): number {
    const enabled: boolean = (AppStorage.get(STORE_PLAYBACK_SPEED_ENABLED) as boolean) ?? false;
    if (!enabled) {
      return 1;
    }
    const rate: number = (AppStorage.get(STORE_PLAYBACK_SPEED) as number) ?? 1.0;
    return rate > 0 ? rate : 1;
  }

  /**
   * 「现在实际放到哪儿了」（ms）。
   *
   * 锚点 = 最近一个 tick 的值 + 它到达的本机时刻；播放中用两者的时间差外推。
   * 外推有上限（EXTRAPOLATE_CAP_MS）：tick 丢了就停住等校正，不越走越远。
   */
  private audioNow(): number {
    const anchorMs: number = this.lyricMilliSecondsTime;
    if (!this.isPlay || this.baseLocalMs <= 0) {
      return anchorMs;
    }
    const elapsed: number = Date.now() - this.baseLocalMs;
    if (elapsed <= 0) {
      return anchorMs;
    }
    return anchorMs + Math.min(elapsed, EXTRAPOLATE_CAP_MS) * this.playRate();
  }

  private cancelWake(): void {
    if (this.wakeTimer !== -1) {
      clearTimeout(this.wakeTimer);
      this.wakeTimer = -1;
    }
  }

  /** 下一行的起点（ms）；已经是最后一行 / 没有歌词时返回 -1 */
  private nextLineStart(nowMs: number): number {
    const list: Array<LrcEntry> = this.mLrcEntryList;
    if (!list || list.length === 0) {
      return -1;
    }
    const next: number = this.findShowLine(nowMs) + 1;
    if (next < 0 || next >= list.length) {
      return -1;
    }
    return list[next].lineStartTime;
  }

  /**
   * 排一次「换行唤醒」。
   *
   * 不做常驻轮询：算出下一行起点对应的本机时刻，一次 setTimeout 睡到那里。
   * 每个 tick 到达都会重排（见 onTimeUpdated），所以这条定时器的延迟天然
   * 被 tick 不断修正 —— 每行实际只唤醒 1~2 次。
   */
  private scheduleWake(): void {
    this.cancelWake();
    if (!this.isPlay || !this.hasLrc()) {
      return;
    }
    const nowAudio: number = this.audioNow();
    const nextStart: number = this.nextLineStart(nowAudio);
    if (nextStart < 0 || nextStart <= nowAudio) {
      // 已经在最后一行，或算出来的是个过去时刻（tick 刚落、还没重绘）
      return;
    }
    const rate: number = this.playRate();
    const localAtSwitch: number = this.baseLocalMs
      + (nextStart - this.lyricMilliSecondsTime) / rate;
    const delay: number = localAtSwitch - Date.now() + WAKE_LEAD_MS;
    if (delay < WAKE_MIN_MS) {
      // 算出来已经过了换行点却没换行 → 外推与真实进度有偏差（倍率读错 / 系统时间跳变）。
      // 此时**不再 10ms 空转**，把校正交给下一个 tick（≤500ms 必到），
      // 最坏退回旧行为，但不会出现忙等把 CPU 打满。
      return;
    }
    this.wakeTimer = setTimeout((): void => {
      this.wakeTimer = -1;
      this.judgeAndDraw(this.audioNow());
      this.scheduleWake();
    }, Math.min(delay, WAKE_MAX_MS));
  }

  /**
   * 判行 + 重绘：只有换行才滚动/重绘。
   *
   * 行级歌词（本项目固定 Line 效果）在同一行内不需要重绘 —— 旧实现每个 tick
   * 都全量重绘一遍（60 行 × measureText），纯属浪费；逐字特效才需要按时间重绘。
   */
  private judgeAndDraw(nowMs: number): void {
    if (!this.hasLrc()) {
      this.drawContent(0);
      return;
    }
    const line: number = this.findShowLine(nowMs);
    if (line !== this.mCurrentLine) {
      this.mCurrentLine = line;
      if (line < 0) {
        // 时间在第一行之前（前奏）：回到顶部，不高亮任何行
        this.startAnimator(0);
      } else {
        // 留下的 lag 是「换行比这一行真实起点晚多少」——
        // 真机 hilog 过滤 [LrcView] 应稳定在几十 ms 量级（改造前 170~500ms）
        console.info(`[LrcView] line ${line} lag ${Math.round(nowMs - this.mLrcEntryList[line].lineStartTime)}ms`);
        this.smoothScrollTo(line);
      }
      return;
    }
    if (this.lyricScrollEffect !== LyricScrollEffect.Line) {
      this.drawContent(this.curCanvasOffsetY);
    }
  }

  /**
   * 立即对齐到当前时间所在行（不补间）。
   *
   * 切歌 / 歌词换了一批时必须瞬时对齐：否则会从上一首的滚动位置补间过来，
   * 观感是「从第 3 行一路滑到第 50 行」。
   */
  private alignImmediately(): void {
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return;
    }
    this.calculate();
    if (!this.hasLrc()) {
      this.mCurrentLine = NONE_LINE;
      this.drawContent(0);
      return;
    }
    const line: number = this.findShowLine(this.lyricMilliSecondsTime);
    this.mCurrentLine = line;
    if (this.animator !== null) {
      this.animator.finish();
    }
    this.drawContent(-this.getOffset(line));
  }

  /** 滚动效果切换：保持当前偏移重绘（不同效果绘制分支不同） */
  onEffectChanged(): void {
    this.drawContent(this.curCanvasOffsetY);
  }

  /** 画一颗五角星（LetterStar 特效用，行级歌词不会走到） */
  private drawStars(x: number, y: number, outRadius: number, inRadius: number, rotateAngle: number): void {
    this.starsPath2D = new Path2D();
    this.context.fillStyle = this.starsColor;
    for (let i = 0; i < STAR_ANGLE_NUMBER; i++) {
      let outX = (Math.cos(angleToRadian(rotateAngle + this.starOutCircleAngle + i * this.starAverageAngle)) * outRadius) + x;
      let outY = -(Math.sin(angleToRadian(rotateAngle + this.starOutCircleAngle + i * this.starAverageAngle)) * outRadius) + y;
      let inX = (Math.cos(angleToRadian(rotateAngle + this.starInCircleAngle + i * this.starAverageAngle)) * inRadius) + x;
      let inY = -(Math.sin(angleToRadian(rotateAngle + this.starInCircleAngle + i * this.starAverageAngle)) * inRadius) + y;
      if (i === 0) {
        this.starsPath2D.moveTo(outX, outY);
      }
      this.starsPath2D.lineTo(outX, outY);
      this.starsPath2D.lineTo(inX, inY);
    }
    this.starsPath2D.closePath();
    this.context.fill(this.starsPath2D);
  }

  private calculate(): void {
    this.lrcWidth = this.viewWidth - this.paddingLeft - this.paddingRight;
    this.lrcHeight = this.viewHeight - this.paddingTop - this.paddingBottom;
    // 每次尺寸变化都重算：原先只在 initFirstLineY === 0 时算一次，
    // 横竖屏 / 分屏 / 折叠屏展开导致的高度变化后，首行基准会停在旧值上
    switch (this.lyricTopPosition) {
      case LyricTopPosition.Middle:
        this.initFirstLineY = this.paddingTop + this.lrcHeight / 2.8;
        break;
      case LyricTopPosition.Top:
        this.initFirstLineY = this.paddingTop;
        break;
      default:
        break;
    }
    this.lrcX = 0;
    this.lrcY = this.initFirstLineY;

    this.starAverageAngle = 360 / STAR_ANGLE_NUMBER;
    this.starOutCircleAngle = 90 - this.starAverageAngle;
    let halfAverageAngle = this.starAverageAngle / 2;
    this.starInCircleAngle = halfAverageAngle + this.starOutCircleAngle;
  }

  private reset(): void {
    this.lrcY = this.initFirstLineY;
  }

  /** 单行文本高度（含折行） */
  private getLineHeight(text: string, isCurrent?: boolean): number {
    let lineHeight = 0;
    if (isCurrent) {
      this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
    } else {
      this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
    }
    let textMetrics: TextMetrics = this.context.measureText(text);
    if (textMetrics.width > this.lrcWidth) {
      let start = 0;
      let end = text.length - 1;
      let textTemp = text;
      while (this.context.measureText(text.substring(start, end)).width > this.lrcWidth) {
        if (textTemp.lastIndexOf(' ') !== -1) {
          end = textTemp.lastIndexOf(' ');
          textTemp = textTemp.substring(0, end);
        } else {
          end--;
        }
      }
      if (this.context.measureText(text.substring(start, end)).width <= this.lrcWidth) {
        lineHeight += textMetrics.height;
        start = end;
      }
      if (start < text.length - 1) {
        lineHeight += textMetrics.height;
      }
    } else {
      lineHeight = textMetrics.height;
    }
    return lineHeight;
  }

  private progressGrad(startX: number, startY: number, endX: number, endY: number, progress: number): CanvasGradient {
    let grad = this.context.createLinearGradient(startX, startY, endX, endY);
    grad.addColorStop(progress, this.mCurrentTextColor);
    grad.addColorStop(progress + GRADIENT_PROGRESS_SPACE, this.mNormalTextColor);
    return grad;
  }

  /** 折行绘制（文本超宽时按空格断行） */
  private drawMultipleLine(lyric: LrcEntry, textMetrics: TextMetrics): number {
    let lineHeight = 0;
    let start = 0;
    let end = 1;
    this.context.textAlign = 'start';
    let text = lyric.lineWords;
    let textTemp = lyric.lineWords;
    end = text.length - 1;

    while (this.context.measureText(text.substring(start, end)).width > this.lrcWidth) {
      if (textTemp.lastIndexOf(' ') !== -1) {
        end = textTemp.lastIndexOf(' ');
        textTemp = textTemp.substring(0, end);
      } else {
        end--;
      }
    }

    if (this.context.measureText(text.substring(start, end)).width <= this.lrcWidth) {
      if (start === 0) {
        this.lrcY = this.lrcY + textMetrics.height + this.mDividerHeight;
      } else {
        this.lrcY = this.lrcY + textMetrics.height;
      }
      lineHeight += textMetrics.height;
      this.context.fillText(text.substring(start, end), this.lrcX, this.lrcY, this.lrcWidth);
      start = end;
    }

    if (start !== 0 && text.charAt(start) === ' ') {
      start += 1;
    }

    if (start < text.length - 1) {
      this.lrcY = this.lrcY + textMetrics.height;
      lineHeight += textMetrics.height;
      this.context.fillText(text.substring(start), this.lrcX, this.lrcY, this.lrcWidth);
    }
    return lineHeight;
  }

  /** 单行绘制（当前行按滚动效果分支；行级歌词 words 为空，走 default 左对齐） */
  private drawSingleLine(lyric: LrcEntry, textMetrics: TextMetrics, isCurrent: boolean): number {
    this.lrcY = this.lrcY + this.mDividerHeight + textMetrics.height;
    let text = lyric.lineWords;
    if (isCurrent) {
      switch (this.lyricScrollEffect) {
        case LyricScrollEffect.LetterScaleGradient:
          if (lyric.words && lyric.words.length > 0) {
            let startX = this.lrcX - textMetrics.width / 2;
            let endX = startX + textMetrics.width;
            let gradY = this.lrcY - textMetrics.height / 2;

            let wordX = startX;
            this.context.textAlign = 'start';
            for (let i = 0; i < lyric.words.length; i++) {
              let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
              let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
              if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                let wordProgress =
                  (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                let wordPassedProgress = i / lyric.words.length;
                let progress = wordPassedProgress + wordProgress;
                this.context.fillStyle = this.progressGrad(startX, gradY, endX, gradY, progress);
                this.context.font =
                  this.fontWeight + ' ' + (this.mCurrentTextSize + this.TEXT_ADD_SIZE) + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[i].text, wordX, this.lrcY + this.TEXT_ADD_SIZE / 2, this.lrcWidth);
              } else {
                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[i].text, wordX, this.lrcY, this.lrcWidth);
              }
              wordX += this.context.measureText(lyric.words[i].text).width;
            }
          } else {
            this.context.textAlign = 'center';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        case LyricScrollEffect.LetterGradient:
          if (lyric.words && lyric.words.length > 0) {
            // ⚠️ `this.lrcX` 是**左边界**（非当前行分支用 textAlign='start' 以它为起点），
            // 这里切成 center 后必须自己换算中心点，否则整行会右移半个行宽
            // （2026-10-22 启用逐字歌词时暴露：以前 words 恒为空，这段从没真正跑过）
            this.context.textAlign = 'center';
            let startX_g = this.lrcX;
            let endX_g = this.lrcX + textMetrics.width;
            let gradY_g = this.lrcY - textMetrics.height / 2;

            let progress = 0;
            let findPlayingWord = false;
            for (let i = 0; i < lyric.words.length; i++) {
              let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
              let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
              if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                let wordProgress =
                  (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                let wordPassedProgress = i / lyric.words.length;
                progress = wordPassedProgress + wordProgress;
                findPlayingWord = true;
                break;
              }
            }
            if (!findPlayingWord) {
              if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                progress = 0;
              } else if (this.lyricMilliSecondsTime >= lyric.lineStartTime + lyric.lineDuration) {
                progress = GRADIENT_PROGRESS_MAX;
              } else {
                console.error('This should not be happening.');
              }
            }

            this.context.fillStyle = this.progressGrad(startX_g, gradY_g, endX_g, gradY_g, progress);
            // center 模式下 x 要给中心点；lrcX 是左边界
            this.context.fillText(text, this.lrcX + textMetrics.width / 2, this.lrcY, this.lrcWidth);
          } else {
            this.context.textAlign = 'start';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        case LyricScrollEffect.LetterStar:
          if (lyric.words && lyric.words.length > 0) {
            let textStartX = this.lrcX - textMetrics.width / 2;
            let textEndX = textStartX + textMetrics.width;
            let gradY_Star = this.lrcY - textMetrics.height / 2;

            let wordXX = textStartX;
            let starX = textStartX;
            let starRotate = 0;
            this.context.textAlign = 'start';
            let findPlayingWordStar = false;
            for (let i = 0; i < lyric.words.length; i++) {
              let wordStartTime = lyric.lineStartTime + lyric.words[i].wordStartTime;
              let wordEndTime = lyric.lineStartTime + lyric.words[i].wordStartTime + lyric.words[i].duration;
              if (wordStartTime <= this.lyricMilliSecondsTime && wordEndTime >= this.lyricMilliSecondsTime) {
                let wordProgress =
                  (this.lyricMilliSecondsTime - wordStartTime) / lyric.words[i].duration / lyric.words.length;
                let wordPassedProgress = i / lyric.words.length;
                let progress = wordPassedProgress + wordProgress;
                this.context.fillStyle = this.progressGrad(textStartX, gradY_Star, textEndX, gradY_Star, progress);
                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[i].text, wordXX, this.lrcY, this.lrcWidth);
                findPlayingWordStar = true;
                starX = wordXX + this.context.measureText(lyric.words[i].text).width / 2;
              } else {
                this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
                this.context.fillText(lyric.words[i].text, wordXX, this.lrcY, this.lrcWidth);
              }
              wordXX += this.context.measureText(lyric.words[i].text).width;
            }

            if (!findPlayingWordStar) {
              if (this.lyricMilliSecondsTime < lyric.lineStartTime) {
                starX = textStartX;
              } else if (this.lyricMilliSecondsTime > lyric.lineStartTime + lyric.lineDuration) {
                starX = this.lrcX + textMetrics.width / 2 -
                  this.context.measureText(lyric.words[lyric.words.length - 1].text).width / 2;
              } else {
                console.error('This should not be happening.');
              }
            }
            let starY = this.lrcY - textMetrics.height;
            this.drawStars(starX, starY, this.mDividerHeight / 2, this.mDividerHeight / 4, starRotate);
          } else {
            this.context.textAlign = 'center';
            this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          }
          break;
        default:
          this.context.textAlign = 'start';
          this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
          break;
      }
    } else {
      this.context.textAlign = 'start';
      this.context.fillText(text, this.lrcX, this.lrcY, this.lrcWidth);
    }
    return textMetrics.height;
  }

  /**
   * 副行（翻译 / 罗马音）占用的总高度。
   * 必须与 `drawSubLines` 实际绘制的高度严格一致 —— 滚动定位（getOffset）
   * 依赖它，两边不一致会表现为「每次换行都差半行」。
   */
  private getSubHeight(lyric: LrcEntry): number {
    const subs: string[] | undefined = lyric.subLines;
    if (subs === undefined || subs.length === 0) {
      return 0;
    }
    const size: number = this.mNormalTextSize * SUB_TEXT_SCALE;
    let count: number = 0;
    for (let i = 0; i < subs.length; i++) {
      if (subs[i].length > 0) {
        count++;
      }
    }
    return count * (size + SUB_TEXT_GAP);
  }

  /** 超宽文本按需截断（副行不折行，否则行高算式与滚动定位会脱钩） */
  private fitText(text: string): string {
    if (this.context.measureText(text).width <= this.lrcWidth) {
      return text;
    }
    let lo: number = 0;
    let hi: number = text.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.context.measureText(`${text.substring(0, mid)}…`).width <= this.lrcWidth) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    const keep: number = Math.max(0, lo - 1);
    return `${text.substring(0, keep)}…`;
  }

  /**
   * 绘制副行（翻译在前，罗马音在后），返回占用高度。
   * 副行比主行更暗、更小：它是辅助信息，视觉权重必须低于主歌词。
   */
  private drawSubLines(lyric: LrcEntry, isCurrent: boolean): number {
    const subs: string[] | undefined = lyric.subLines;
    if (subs === undefined || subs.length === 0) {
      return 0;
    }
    const size: number = this.mNormalTextSize * SUB_TEXT_SCALE;
    this.context.font = this.fontWeight + ' ' + size + 'vp ' + this.fontFamily;
    this.context.fillStyle = isCurrent ? this.mCurrentTextColor : this.mNormalTextColor;
    this.context.globalAlpha = isCurrent ? 0.82 : 0.64;
    this.context.textAlign = 'start';
    this.context.textBaseline = 'bottom';
    let used: number = 0;
    for (let i = 0; i < subs.length; i++) {
      const text: string = subs[i];
      if (text.length === 0) {
        continue;
      }
      this.lrcY = this.lrcY + size + SUB_TEXT_GAP;
      this.context.fillText(this.fitText(text), this.lrcX, this.lrcY);
      used += size + SUB_TEXT_GAP;
    }
    this.context.globalAlpha = 1;
    return used;
  }

  private drawLyricLine(lyric: LrcEntry, isCurrent: boolean): number {
    let lineHeight = 0;
    if (isCurrent) {
      this.context.font = this.fontWeight + ' ' + this.mCurrentTextSize + 'vp ' + this.fontFamily;
      this.context.fillStyle = this.mCurrentTextColor;
      // 当前行柔和文字发光：低强度白影，只烘托高亮、不做闪烁
      this.context.shadowBlur = 12;
      this.context.shadowColor = 'rgba(255, 255, 255, 0.35)';
    } else {
      this.context.font = this.fontWeight + ' ' + this.mNormalTextSize + 'vp ' + this.fontFamily;
      this.context.fillStyle = this.mNormalTextColor;
    }
    this.context.textBaseline = 'bottom';
    let textMetrics: TextMetrics = this.context.measureText(lyric.lineWords);

    if (textMetrics.width > this.lrcWidth) {
      lineHeight = this.drawMultipleLine(lyric, textMetrics);
    } else {
      lineHeight = this.drawSingleLine(lyric, textMetrics, isCurrent);
    }
    // 发影用完即关：渐隐遮罩 fillRect 不能带 shadow，否则整屏泛光
    this.context.shadowBlur = 0;
    // 副行（翻译 / 罗马音）画在主行下方，占用高度一并返回
    const subHeight: number = this.drawSubLines(lyric, isCurrent);
    return lineHeight + subHeight;
  }

  private drawContent(desOffsetY: number): void {
    this.context.clearRect(0, 0, this.viewWidth, this.lrcY + this.viewHeight);
    this.reset();

    this.context.globalCompositeOperation = 'source-over';
    this.lrcY = this.initFirstLineY + desOffsetY;
    this.curCanvasOffsetY = desOffsetY;

    if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
      let index = 0;
      for (let mLrcEntryListElement of this.mLrcEntryList) {
        let isCurrentLine = this.mCurrentLine === index ? true : false;
        this.drawLyricLine(mLrcEntryListElement, isCurrentLine);
        index++;
      }
    } else {
      this.drawLyricLine(EMPTY_LYRIC, true);
    }

    this.updateLyricArea(this.paddingLeft, this.paddingTop, this.viewWidth - this.paddingRight,
      this.viewHeight - this.paddingBottom);

    if (this.mLrcEntryList && this.mLrcEntryList.length > 0) {
      // 上下渐隐遮罩：先按歌词形状填充，再用透明渐变以 source-in 方式裁剪
      this.context.globalCompositeOperation = 'source-in';
      let grad = this.context.createLinearGradient(0, 0, 0, this.viewHeight);
      grad.addColorStop(0.0, '#00ffffff');
      grad.addColorStop(0.15, '#ffffffff');
      grad.addColorStop(0.3, '#ffffffff');
      grad.addColorStop(0.7, '#4dffffff');
      grad.addColorStop(1.0, '#00ffffff');
      this.context.fillStyle = grad;
      this.context.fillRect(0, 0, this.viewWidth, this.viewHeight);
    }
  }

  private updateLyricArea(left: number, top: number, right: number, bottom: number): void {
    this.lyricRectangle = new Rectangle(left, top, right, bottom);
  }

  hasLrc(): boolean {
    return this.mLrcEntryList && this.mLrcEntryList.length > 0;
  }

  getOffset(line: number): number {
    let offsetY = 0;
    switch (this.lyricTopPosition) {
      case LyricTopPosition.Top:
        for (let i = 0; i <= line && i < this.mLrcEntryList.length; i++) {
          const sub: number = this.getSubHeight(this.mLrcEntryList[i]);
          if (i === line) {
            offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, true) / 2
              - this.getLineHeight(this.mLrcEntryList[i].lineWords, false) / 2;
          } else {
            offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, false) + sub + this.mDividerHeight;
          }
        }
        break;
      case LyricTopPosition.Middle:
        for (let i = 0; i <= line && i < this.mLrcEntryList.length; i++) {
          const sub: number = this.getSubHeight(this.mLrcEntryList[i]);
          if (i === line) {
            offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, true) / 2
              + sub / 2 + this.mDividerHeight;
          } else {
            offsetY += this.getLineHeight(this.mLrcEntryList[i].lineWords, false) + sub + this.mDividerHeight;
          }
        }
        break;
      default:
        break;
    }
    return offsetY;
  }

  smoothScrollTo(line: number): void {
    let offset = this.getOffset(line);
    console.info(`[LrcView] smoothScrollTo line: ${line}, offset: ${offset}`);
    this.startAnimator(offset);
  }

  /** 歌词内容变化：停掉在跑的动画与唤醒，瞬时对齐到当前行（切歌不滑行） */
  onLyricUpdated(): void {
    this.cancelWake();
    this.lastTickMs = this.lyricMilliSecondsTime;
    this.baseLocalMs = Date.now();
    this.alignImmediately();
    this.scheduleWake();
  }

  /**
   * 收到新的进度 tick（500ms 一次）。
   *
   * 只把 tick 当锚点用：记下「值 + 到达时刻」，然后用外推值判行。
   * 换行是否发生由外推决定，所以歌词不必等这 500ms —— 这是本次改造的核心。
   */
  onTimeUpdated(): void {
    const tickMs: number = this.lyricMilliSecondsTime;
    if (tickMs !== this.lastTickMs) {
      this.lastTickMs = tickMs;
      this.baseLocalMs = Date.now();
    }
    this.judgeAndDraw(this.audioNow());
    this.scheduleWake();
  }

  /**
   * 当前时间所在行。
   *
   * 二分查「最后一个 lineStartTime <= milliSeconds」的行 —— 天然左闭右开：
   * 在下一行起点那一刻就已经切到下一行，不会像旧实现的 `>=` 那样把上一行
   * 多留一个 tick。顺带不再依赖 lineDuration，重复时间标签（duration=0）的行
   * 也能被正确命中；复杂度从 O(n) 降到 O(log n)（每次判行都调）。
   *
   * 返回 NONE_LINE 表示「时间在第一行之前」（前奏），调用方据此不高亮任何行。
   */
  findShowLine(milliSeconds: number): number {
    const list: Array<LrcEntry> = this.mLrcEntryList;
    if (!list || list.length === 0) {
      return NONE_LINE;
    }
    let lo: number = 0;
    let hi: number = list.length - 1;
    let found: number = NONE_LINE;
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      if (list[mid].lineStartTime <= milliSeconds) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }

  build() {
    Canvas(this.context)
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.viewWidth = parseAreaLength(newArea.width);
        this.viewHeight = parseAreaLength(newArea.height);
        if (parseAreaLength(oldArea.width) !== parseAreaLength(newArea.width)
          || parseAreaLength(oldArea.height) !== parseAreaLength(newArea.height)) {
          this.calculate();
          // 用外推后的「当前播放位置」对齐，而不是滞后的 tick 值：
          // 尺寸变化往往伴随旋转/折叠，此刻对齐偏了一行会很显眼
          const line: number = this.findShowLine(this.audioNow());
          this.mCurrentLine = line;
          this.drawContent(-this.getOffset(line));
          this.scheduleWake();
        }
      })
  }
}
