/**
 * 「视频简介」弹层内容（共享组件）。
 *
 * 由播放页功能行「视频简介」键（ControlAreaComponent）的 bindSheet 挂载。
 * 弹层两部分：上半视频简介（getVideoDetail 的 desc，长文可展开收起）、
 * 下半置顶评论（getTopReply：UP 置顶楼优先，无置顶回落热门首评，
 * 标签按 isTop 切换「置顶评论 / 热门评论」）。
 *
 * 懒加载：弹层开关 @Link showSheet 经 @Watch 监听 —— 每次置 true 时按当前曲
 * 并行拉取简介与评论（aid 缺失时先 await view 结果取 aid 再拉评论），
 * 两者各自失败独立降级（互不影响，只标记对应分区失败态）。
 * 宿主约定（ChapterSheet / QueueSheet 同款）：bindSheet 挂载本组件。
 * 弹层高度：宿主用 SheetSize.FIT_CONTENT（内容自适应，固定半屏会在内容偏短时
 * 下方大片留白）—— 故本组件根节点不能用百分比高（FIT_CONTENT 文档约束），
 * 超长内容靠 maxScrollHeightVp 的 constraintSize 上限在内部滚动。
 */

import { Track, TopReplyResult, VideoDetail } from '../../model/MusicModels';
import { getTopReply, getVideoDetail } from '../../api/BilibiliApi';
import {
  STORE_CURRENT_TRACK,
  STORE_WINDOW_HEIGHT_VP,
  STORE_WINDOW_WIDTH_VP,
  STORE_SAFE_TOP
} from '../../common/Constants';

/** 评论发布时间（Unix 秒）→ "YYYY-MM-DD" */
function formatReplyDate(ctimeSec: number): string {
  const d: Date = new Date(ctimeSec * 1000);
  const y: number = d.getFullYear();
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return `${y}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
}

/** 点赞数 → 中文习惯显示（≥ 1 万显示「x.x万」） */
function formatLikeCount(like: number): string {
  if (like >= 10000) {
    return `${(like / 10000).toFixed(1)}万`;
  }
  return `${like}`;
}

/** 简介折叠行数上限（超过视为长文，提供「展开 / 收起」） */
const DESC_COLLAPSED_MAX_LINES: number = 8;
/** 简介长文判定阈值（字符数，与折叠行数配合的粗粒度启发式） */
const DESC_LONG_TEXT_THRESHOLD: number = 160;

@Component
export struct DescSheet {
  /** 当前曲（弹层打开时按它取 bvid / aid 拉数据） */
  @StorageProp(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /** 宿主弹层开关：置 true 时触发懒加载 */
  @Link @Watch('onShowChanged') showSheet: boolean;
  /** 加载中（简介与评论任一在途即为 true，全部落定后置 false） */
  @State loading: boolean = false;
  /** 视频简介正文（trim 后为空串 = 无简介，走空态） */
  @State descText: string = '';
  /** 简介加载失败标记（网络 / 风控拦截等，独立于评论区降级） */
  @State descFailed: boolean = false;
  /** 简介长文展开态（false = 折叠到行数上限 + 「展开」按钮） */
  @State descExpanded: boolean = false;
  /** 置顶评论（null = 无评论或尚未加载完） */
  @State reply: TopReplyResult | null = null;
  /** 评论加载失败标记（独立于简介区降级） */
  @State replyFailed: boolean = false;
  /** 加载竞态令牌：弹层关了再开 / 切歌后重开时，旧在途结果作废 */
  private loadSeq: number = 0;
  /** 窗口高（vp，EntryAbility 首帧发布）：FIT_CONTENT 内容滚动上限计算 */
  @StorageProp(STORE_WINDOW_HEIGHT_VP) windowHeightVp: number = 0;
  /** 窗口宽（vp）：大窗 POPUP 档系统上限按窗口短边 90% 取 */
  @StorageProp(STORE_WINDOW_WIDTH_VP) windowWidthVp: number = 0;
  /** 顶部安全区（vp）：手机底部弹层可达高度扣除 */
  @StorageProp(STORE_SAFE_TOP) safeTopVp: number = 0;

  /**
   * 内容滚动区高度上限（vp）。FIT_CONTENT 下 Scroll 必须有界：超长内容
   *（长简介展开 / 长评论）在界内滚动，否则半模态触顶后超出部分被裁不可达。
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

  aboutToAppear(): void {
    // bindSheet 首次构建内容时 @Link 已是 true，@Watch 不触发（初始化不回调），
    // 这里兜底首发加载；组件实例复用的后续开合走 onShowChanged。
    if (this.showSheet) {
      this.loadContent();
    }
  }

  /** 弹层每次打开（showSheet 置 true）按当前曲重拉（切歌后重开拿新曲数据） */
  private onShowChanged(): void {
    if (this.showSheet) {
      this.loadContent();
    }
  }

  /**
   * 并行拉取简介与评论：
   * · 简介：getVideoDetail(bvid).desc（viewCache 10 分钟缓存，重开秒回）；
   * · 评论：getTopReply(aid)（topReplyCache 会话缓存）；aid 缺失（部分构建
   *   路径 Track.aid = 0）时先 await view 结果取 aid 再拉。
   * 两任务独立 try/catch：任一失败只标记对应分区，另一分区照常展示。
   */
  private async loadContent(): Promise<void> {
    const track: Track | null = this.currentTrack;
    this.loadSeq += 1;
    const seq: number = this.loadSeq;
    this.descText = '';
    this.reply = null;
    this.descFailed = false;
    this.replyFailed = false;
    this.descExpanded = false;
    if (track === null || track.bvid.length === 0) {
      this.loading = false;
      this.descFailed = true;
      return;
    }
    this.loading = true;
    const detailTask: Promise<VideoDetail> = getVideoDetail(track.bvid);
    // Track.aid 是字符串（部分构建路径为空串）：解析为数字，无效 / 缺失时
    //（部分构建路径 aid = ''）先 await view 结果取 aid 再拉评论。
    const aidNum: number = parseInt(track.aid);
    const replyTask: Promise<TopReplyResult | null> = !Number.isNaN(aidNum) && aidNum > 0
      ? getTopReply(aidNum)
      : detailTask.then((detail: VideoDetail): Promise<TopReplyResult | null> => {
        return detail.aid > 0
          ? getTopReply(detail.aid)
          : Promise.resolve<TopReplyResult | null>(null);
      });
    try {
      const detail: VideoDetail = await detailTask;
      if (seq === this.loadSeq) {
        this.descText = detail.desc ?? '';
      }
    } catch (e) {
      if (seq === this.loadSeq) {
        this.descFailed = true;
        const errText: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.error(`[DescSheet] load desc failed: ${errText}`);
      }
    }
    try {
      const reply: TopReplyResult | null = await replyTask;
      if (seq === this.loadSeq) {
        this.reply = reply;
      }
    } catch (e) {
      if (seq === this.loadSeq) {
        this.replyFailed = true;
        const errText: string = e instanceof Error ? e.message : JSON.stringify(e);
        console.error(`[DescSheet] load reply failed: ${errText}`);
      }
    }
    if (seq === this.loadSeq) {
      this.loading = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text('视频简介')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 16, bottom: 12 })

      if (this.loading) {
        // FIT_CONTENT 根节点禁百分比高：加载态给固定可视高度（spinner 居中），
        // 内容落定后弹层高度随内容自适应。
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color($r('sys.color.font_secondary'))
        }
        .width('100%')
        .height(200)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // ===== 简介区 =====
            if (this.descFailed) {
              Text('简介加载失败，请稍后重试')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            } else if (this.descText.trim().length === 0) {
              Text('该视频没有简介')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            } else {
              Text(this.descText)
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .lineHeight(22)
                .maxLines(this.descExpanded ? 1000 : DESC_COLLAPSED_MAX_LINES)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
              if (this.descText.length > DESC_LONG_TEXT_THRESHOLD) {
                Text(this.descExpanded ? '收起' : '展开')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
                  .padding({ top: 4, bottom: 4 })
                  .onClick((): void => {
                    this.descExpanded = !this.descExpanded;
                  })
              }
            }

            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ top: 16, bottom: 16 })

            // ===== 置顶评论区 =====
            if (this.replyFailed) {
              Text('评论加载失败，请稍后重试')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            } else if (this.reply === null) {
              Text('暂无评论')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            } else {
              Column() {
                Text(this.reply.isTop ? '置顶评论' : '热门评论')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_tertiary'))
                  .width('100%')
                  .margin({ bottom: 8 })
                  .textAlign(TextAlign.Start)
                Text(this.reply.uname)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Row({ space: 8 }) {
                  Text(formatReplyDate(this.reply.ctime))
                    .fontSize(11)
                    .fontColor($r('sys.color.font_tertiary'))
                  Text(`赞 ${formatLikeCount(this.reply.like)}`)
                    .fontSize(11)
                    .fontColor($r('sys.color.font_tertiary'))
                }
                .margin({ top: 2 })
                Text(this.reply.message)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
                  .lineHeight(22)
                  .width('100%')
                  .margin({ top: 6 })
                  .textAlign(TextAlign.Start)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: this.maxScrollHeightVp() })
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
  }
}
