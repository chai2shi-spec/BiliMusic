/**
 * 播放页封面页（移植自 audio-interaction-master 的 MusicInfoComponent）。
 *
 * 结构：圆形大封面 + 呼吸光晕（CoverDiscComponent，与 miniBar 唱片同 id 的
 * geometryTransition 一镜到底）+ 歌名 / 歌手 + 底部控制区（ControlAreaComponent）。
 * 数据源全部来自既有播放状态（STORE_CURRENT_TRACK），不引入新数据。
 */

import { Track } from '../../model/MusicModels';
import { StyleConstants } from '../../common/constants/StyleConstants';
import { BreakpointConstants } from '../../common/constants/BreakpointConstants';
import { PlayerConstants } from '../../common/constants/PlayerConstants';
import { ControlAreaComponent } from './ControlAreaComponent';
import { CoverDiscComponent } from './CoverDiscComponent';
import {
  STORE_CURRENT_TRACK,
  STORE_PLAYER_FOLD_FULL
} from '../../common/Constants';

@Component
export struct MusicInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_PLAYER_FOLD_FULL) isFoldFull: boolean = false;
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;

  /**
   * 圆盘边长上限（vp）：0 = 首帧尚未实测（先按旧的宽度驱动渲染，实测后收敛）。
   * 圆盘本身 aspectRatio(1) 宽变高，列宽接近列高的形态（宽折叠展开 / 折起外屏）
   * 会把控制区挤出屏幕；这里按「列高 − 标题块 − 控制区」的实测预算钳住它。
   */
  @State discSize: number = 0;
  /** 内容列实测宽 / 高（onAreaChange 回写） */
  private colW: number = 0;
  private colH: number = 0;
  /** 标题块 / 控制区实测高（圆盘的高度预算要减掉这两块） */
  private titleH: number = 0;
  private ctrlH: number = 0;

  /** Area 尺寸（Length）→ vp 数值；资源型（理论上不会出现）按 0 兜底 */
  private toVp(v: Length): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      return parseFloat(v);
    }
    return 0;
  }

  /**
   * 圆盘边长 = min(列宽, 列高 − 标题块 − 控制区)。
   * 四项实测就位前不动（保持 0 = 宽度驱动）；预算为负时同样退回宽度驱动。
   * 瘦长屏（普通手机）预算大于列宽，min 取列宽 —— 与旧行为完全一致，
   * 只有空间不足的形态才会收缩圆盘。
   */
  private recomputeDisc(): void {
    if (this.colW <= 0 || this.colH <= 0 || this.titleH <= 0 || this.ctrlH <= 0) {
      // 暂留诊断日志，验证通过后可删
      console.info(`[MusicInfo] recompute skip: colW=${this.colW}, colH=${this.colH}, titleH=${this.titleH}, ctrlH=${this.ctrlH}`);
      return;
    }
    this.discSize = Math.min(this.colW, this.colH - this.titleH - this.ctrlH);
    console.info(`[MusicInfo] discSize=${this.discSize} (colW=${this.colW}, colH=${this.colH}, titleH=${this.titleH}, ctrlH=${this.ctrlH})`);
  }

  private titleText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '暂无播放内容';
    }
    return t.title.length > 0 ? t.title : '未知歌曲';
  }

  private artistText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '—';
    }
    return t.artist.length > 0 ? t.artist : '未知歌手';
  }

  build() {
    GridRow({
      columns: {
        xs: BreakpointConstants.COLUMN_SM,
        sm: BreakpointConstants.COLUMN_SM,
        md: BreakpointConstants.COLUMN_MD
      },
      gutter: BreakpointConstants.GUTTER_MUSIC_X,
      breakpoints: { reference: BreakpointsReference.ComponentSize }
    }) {
      GridCol({
        span: {
          xs: BreakpointConstants.SPAN_SM,
          sm: BreakpointConstants.SPAN_SM,
          md: BreakpointConstants.SPAN_MD
        },
        offset: { md: BreakpointConstants.OFFSET_MD }
      }) {
        Column() {
          this.CoverInfo()
          // 标题块包一层测高容器：@Builder 调用不能链属性，onAreaChange 挂在包装上
          Column() {
            this.MusicInfo()
          }
          .onAreaChange((_old: Area, n: Area): void => {
            this.titleH = this.toVp(n.height);
            this.recomputeDisc();
          })
          Blank()
          // 控制区同样包一层测高容器，实测高度参与圆盘预算
          Column() {
            ControlAreaComponent()
          }
          .onAreaChange((_old: Area, n: Area): void => {
            this.ctrlH = this.toVp(n.height);
            this.recomputeDisc();
          })
        }
        .height(StyleConstants.FULL_HEIGHT)
        .width(StyleConstants.FULL_WIDTH)
        .clip(false)
        .onAreaChange((_old: Area, n: Area): void => {
          this.colW = this.toVp(n.width);
          this.colH = this.toVp(n.height);
          this.recomputeDisc();
        })
      }
    }
  }

  /** 大封面：圆形裁切 + 呼吸光晕 + 柔和投影（含空封面占位，见 CoverDiscComponent） */
  @Builder
  CoverInfo(): void {
    Row() {
      CoverDiscComponent({ discSize: this.discSize })
    }
    .width(StyleConstants.FULL_WIDTH)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  MusicInfo(): void {
    Column() {
      Text(this.titleText())
        .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ?
        $r('app.float.title_font_play_md') : $r('app.float.title_font_play'))
        .fontColor(Color.White)
        .opacity(0.95)
        .fontWeight(FontWeight.Bold)
        .fontFamily(PlayerConstants.FONT_FAMILY_BOLD)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.artistText())
        .textAlign(TextAlign.Start)
        .fontSize(this.currentBreakpoint === BreakpointConstants.BREAKPOINT_MD && !this.isFoldFull ?
        $r('app.float.title_font_play') : $r('app.float.font_fourteen'))
        .fontColor('rgba(255, 255, 255, 0.55)')
        .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
        .margin({ top: $r('app.float.music_text_margin_top') })
        .width(StyleConstants.FULL_WIDTH)
        .fontWeight(FontWeight.Regular)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .margin({ top: $r('app.float.music_info_margin_top') })
    .alignItems(HorizontalAlign.Start)
  }
}
