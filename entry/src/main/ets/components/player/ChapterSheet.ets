/**
 * 分段列表弹层内容（共享组件）。
 *
 * 由播放页功能行「分段列表」键（ControlAreaComponent）的 bindSheet 挂载，
 * 数据源 STORE_VIDEO_CHAPTERS（ChapterStore 发布的当前曲章节分段）。
 *
 * 宿主约定（QueueSheet 同款）：bindSheet 挂载本组件，弹层开关以 @Link
 * showSheet 传入 —— 点章节行 seek 跳转后由内容侧置 false 关闭弹层。
 * 当前章节按播放进度实时高亮（from <= progress < to，波形图标 + 主题色）。
 * 弹层高度：宿主用 SheetSize.FIT_CONTENT（内容自适应，固定半屏会在章节偏少时
 * 下方大片留白）—— 故本组件根节点不能用百分比高（FIT_CONTENT 文档约束），
 * 章节多时靠 maxScrollHeightVp 的 constraintSize 上限在列表内滚动。
 */

import { CHAPTER_SOURCE_DESC, CHAPTER_SOURCE_TOP_COMMENT, VideoChapter } from '../../model/MusicModels';
import { MusicPlayer } from '../../player/MusicPlayer';
import {
  STORE_PROGRESS,
  STORE_THEME_PRIMARY,
  STORE_VIDEO_CHAPTERS,
  STORE_WINDOW_HEIGHT_VP,
  STORE_WINDOW_WIDTH_VP,
  STORE_SAFE_TOP
} from '../../common/Constants';

/** 秒 → "m:ss"（分段起始时间显示） */
function formatChapterTime(totalSeconds: number): string {
  const s: number = Math.max(0, Math.floor(totalSeconds));
  const m: number = Math.floor(s / 60);
  const r: number = s % 60;
  return `${m}:${r < 10 ? '0' : ''}${r}`;
}

@Component
export struct ChapterSheet {
  /** 当前曲章节分段（ChapterStore 发布镜像） */
  @StorageProp(STORE_VIDEO_CHAPTERS) chapters: VideoChapter[] = [];
  /**
   * 播放进度（秒，500ms 分桶推送）：当前章节高亮判定。
   * 订阅圈死在本弹层小子树内（弹层内容仅标题 + 章节行，重渲染代价可控；
   * 播放页控制区其余部分不受影响 —— 与 PlayerProgressArea 同款圈法）。
   */
  @StorageProp(STORE_PROGRESS) progress: number = 0;
  /** 主题色（当前章节高亮） */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';
  /** 宿主弹层开关：点章节行 seek 后由本组件置 false 关闭 */
  @Link showSheet: boolean;
  /** 窗口高（vp，EntryAbility 首帧发布）：FIT_CONTENT 列表滚动上限计算 */
  @StorageProp(STORE_WINDOW_HEIGHT_VP) windowHeightVp: number = 0;
  /** 窗口宽（vp）：大窗 POPUP 档系统上限按窗口短边 90% 取 */
  @StorageProp(STORE_WINDOW_WIDTH_VP) windowWidthVp: number = 0;
  /** 顶部安全区（vp）：手机底部弹层可达高度扣除 */
  @StorageProp(STORE_SAFE_TOP) safeTopVp: number = 0;

  private player: MusicPlayer = MusicPlayer.getInstance();

  /**
   * 章节列表高度上限（vp）。FIT_CONTENT 下 List 必须有界：章节多时在界内
   * 滚动，否则半模态触顶后尾部章节被裁不可达。计算口径与 DescSheet 同款：
   * · 手机底部弹层：窗口高 - 顶部安全区 - 8vp（系统顶界余量）- 16vp 余量；
   * · 大窗 POPUP（窗口宽 ≥840vp 触发）：系统上限为窗口短边 90%，两限取小。
   * 镜像未就绪（0）回落常规手机可用高度，宁短勿裁。
   */
  private maxScrollHeightVp(): number {
    if (this.windowHeightVp <= 0) {
      return 480;
    }
    const safeTop: number = this.safeTopVp > 0 ? this.safeTopVp : 36;
    const bottomCap: number = this.windowHeightVp - safeTop - 8 - 16;
    if (this.windowWidthVp >= 840) {
      const shortSide: number = Math.min(this.windowWidthVp, this.windowHeightVp);
      const popupCap: number = shortSide * 0.9 - 16;
      return Math.max(240, Math.round(Math.min(bottomCap, popupCap)));
    }
    return Math.max(240, Math.round(bottomCap));
  }

  /** 当前播到的章节下标（from <= progress < to）；落在分段间隙（数据异常兜底）返回 -1 */
  private activeChapterIndex(): number {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].from <= this.progress && this.progress < this.chapters[i].to) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 分段数据来源标识（首条为准 —— 同一次发布的分段来源一致：官方 view_points
   * 全 'official'，简介解析全 'desc'，置顶评论解析全 'topReply'）。弹层标题
   * 右侧小字，让用户知道看到的分段是官方数据还是手写时间戳解析的兜底结果。
   */
  private sourceLabel(): string {
    if (this.chapters.length === 0) {
      return '';
    }
    const first: VideoChapter = this.chapters[0];
    if (first.source === CHAPTER_SOURCE_DESC) {
      return '来自简介解析';
    }
    if (first.source === CHAPTER_SOURCE_TOP_COMMENT) {
      return '来自置顶评论解析';
    }
    return '官方分段';
  }

  build() {
    Column() {
      Row() {
        Text(`分段列表(${this.chapters.length})`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        if (this.chapters.length > 0) {
          Blank()
          Text(this.sourceLabel())
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 16, bottom: 12 })

      // 空态防御：入口显隐已改由设置开关控制（不再按章节数门控），无分段视频
      // 点击入口即落此空态；章节数据在弹层开着时被清空（切歌）时也在此兜底。
      if (this.chapters.length === 0) {
        Column() {
          Text('该视频没有分段')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.chapters, (chapter: VideoChapter, index: number): void => {
            ListItem() {
              Row({ space: 10 }) {
                if (index === this.activeChapterIndex()) {
                  SymbolGlyph($r('sys.symbol.waveform'))
                    .fontSize(16)
                    .fontColor([this.themePrimary])
                    .width(24)
                } else {
                  Text(`${index + 1}`)
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                    .width(24)
                    .textAlign(TextAlign.Center)
                }
                Text(chapter.title)
                  .fontSize(14)
                  .fontColor(index === this.activeChapterIndex()
                    ? this.themePrimary
                    : $r('sys.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(formatChapterTime(chapter.from))
                  .fontSize(12)
                  .fontColor(index === this.activeChapterIndex()
                    ? this.themePrimary
                    : $r('sys.color.font_secondary'))
              }
              .width('100%')
              .padding({ left: 24, right: 24, top: 10, bottom: 10 })
            }
            .onClick((): void => {
              // 点行跳到该章节起点；弹层收起回播放页（点击目标明确，无需停留）
              this.player.seek(chapter.from);
              this.showSheet = false;
            })
          }, (chapter: VideoChapter, index: number): string => `${index}_${chapter.from}_${chapter.title}`)
        }
        .width('100%')
        .constraintSize({ maxHeight: this.maxScrollHeightVp() })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(8)
      }
    }
    .width('100%')
  }
}
