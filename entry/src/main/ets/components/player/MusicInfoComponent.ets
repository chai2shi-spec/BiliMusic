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
import { HttpUtil } from '../../utils/HttpUtil';
import {
  AUDIO_Q_DOLBY,
  AUDIO_Q_HIRES,
  STORE_CURRENT_TRACK,
  STORE_PLAYER_BG_DARK,
  STORE_PLAYER_FOLD_FULL,
  STORE_LOGIN_REV,
  formatTrackQuality
} from '../../common/Constants';
import { getLoginUser, LoginUser } from '../../service/LoginStore';
import {
  ENTRANCE_DURATION_MS,
  ENTRANCE_OFFSET_VP,
  LAYER_DELAY_INFO
} from '../../common/constants/InteractionConstants';

@Component
export struct MusicInfoComponent {
  @StorageProp(BreakpointConstants.CURRENT_BREAKPOINT) currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  @StorageLink(STORE_PLAYER_FOLD_FULL) isFoldFull: boolean = false;
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;

  /**
   * 背景明暗（PlayerInfoComponent 取色后写入）：浅色封面时把码率文字压深一档，
   * 否则 55% 白在浅色封面上读不出来。照TopAreaComponent 的消费方式。
   */
  @StorageProp(STORE_PLAYER_BG_DARK) isBgDark: boolean = true;

  /**
   * 登录用户（只为音质文案判断「是否大会员」）：登录 / 退出 / 用户信息变化时
   * `STORE_LOGIN_REV` 递增，这里跟着刷新。@StorageLink 是双向的，写不到，
   * 只读即可 —— 但**不能**用普通成员（只在创建时初始化一次，登录后不会变）。
   */
  @StorageLink(STORE_LOGIN_REV) loginRev: number = 0;

  /**
   * 圆盘边长上限（vp）：0 = 首帧尚未实测（先按旧的宽度驱动渲染，实测后收敛）。
   * 圆盘本身 aspectRatio(1) 宽变高，列宽接近列高的形态（宽折叠展开 / 折起外屏）
   * 会把控制区挤出屏幕；这里按「列高 − 标题块 − 控制区」的实测预算钳住它。
   */
  @State discSize: number = 0;

  /**
   * 分层入场（方案 B）：**标题块**（歌名 / 歌手）延迟 `LAYER_DELAY_INFO` 淡入 + 上移。
   *
   * 为什么单独给标题块加状态、而不是给整个 `GridRow` 根节点加：
   * 根节点里还装着 `CoverDiscComponent`（geometryTransition 独占形变），
   * 根节点一旦有 transform，它的目标框就会按动画中途的值计算 → 封面落位后再弹一下。
   * 所以动画必须挂在**封面之外的容器**上。
   */
  @State titleOpacity: number = 0;
  @State titleOffsetY: number = ENTRANCE_OFFSET_VP;

  aboutToAppear(): void {
    // 延迟直接交给 animateTo 的 delay，不用 setTimeout —— 少一个要清理的定时器
    this.getUIContext().animateTo(
      { duration: ENTRANCE_DURATION_MS, curve: Curve.EaseOut, delay: LAYER_DELAY_INFO },
      (): void => {
        this.titleOpacity = 1;
        this.titleOffsetY = 0;
      }
    );
  }

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

  /**
   * 音质回显文案（2026-10-08）。
   *
   * 为什么要回显：`Constants.ts` 的 AUDIO_Q_* 注释记着一条实测结论 ——
   * B 站侧只有一份低码率音源时，30280/30250/30251 三个档位会**指向同一份 66k 数据**。
   * 只显示档位标签（"192kbps"）就是在骗用户，必须显示实测码率。
   *
   * 文案分档（`formatTrackQuality` 负责前半段）：
   *   · 有实测码率 → 「176 kbps」
   *   · 大会员 + 高档位 → 追加「· Hi-Res 无损」/「· 杜比全景声」
   *   · 非大会员→ 追加「· 大会员可听杜比 / 无损」
   *   · 未登录 → 追加「· 登录可解锁更高音质」
   *
   * ⚠️ 「登录可解锁」只对**大会员**成立（30250 / 30251 需要大会员），
   * 所以未登录文案不能承诺杜比 / 无损 —— 只说「更高音质」。
   *
   * 返回空串 = 调用方整行不渲染（正在解析 / 本地文件 / 数据缺失）。
   */
  private qualityText(): string {
    const t: Track | null = this.currentTrack;
    if (t === null) {
      return '';
    }
    // 本地文件：没有经过 playurl 解析，码率字段是 0。只标来源，不假装有码率。
    if (t.localFilePath !== undefined && t.localFilePath.length > 0) {
      return '本地文件';
    }
    const base: string = formatTrackQuality(t.audioQuality, t.audioBandwidth);
    if (base.length === 0) {
      return '';
    }
    // 高档位标签只在**非杜比/非 Hi-Res** 时补（那两档 label 本身就是音质名，再加会重复）
    const hiLabel: string = t.audioQuality === AUDIO_Q_HIRES ? ' · Hi-Res 无损'
      : (t.audioQuality === AUDIO_Q_DOLBY ? ' · 杜比全景声' : '');
    if (hiLabel.length > 0) {
      return `${base}${hiLabel}`;
    }
    // 会员状态**在方法体内现算**：`loginUser` 若做成普通成员，只在组件创建时初始化一次，
    // 用户后来登录 / 退出都不会反映出来（自定义组件普通成员的经典坑）。
    // `loginRev`（@StorageLink）会随 LoginStore 的 bumpLoginRev 递增触发重渲染，
    // 方法体随之重读 —— 这样「登录后文案立刻从「登录可解锁」变成「大会员可听」」。
    const loginUser: LoginUser | null = getLoginUser();
    const vip: number = loginUser !== null ? loginUser.vipStatus : 0;
    if (vip === 1) {
      return base;
    }
    return HttpUtil.getLoginCookie().length > 0
      ? `${base} · 大会员可听杜比 / 无损`
      : `${base} · 登录可解锁更高音质`;
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
          // 分层入场（方案 B）：只挂 transform 系属性，不动 width/height/padding。
          // 这一层是「封面之外的容器」，所以不会影响 CoverDisc 的 geometryTransition 目标框。
          .opacity(this.titleOpacity)
          .translate({ y: this.titleOffsetY })
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

      // 音质回显（2026-10-08）：见 qualityText() 的注释。
      // 空串 = 整行不渲染（正在解析音源 / 本地文件 / 无数据），不占位不留空隙。
      if (this.qualityText().length > 0) {
        Text(this.qualityText())
          .fontSize(11)
          // ⚠️ 播放页是沉浸背景，这里**不能**用 $r('app.color.*') 的浅色 token ——
          // 跟随背景明暗压深/提亮（55% 白在浅色封面上读不出来）。
          // rgba 是播放页的既有例外（上一行 artistText 同样写法），别改成token。
          .fontColor(this.isBgDark ? 'rgba(255, 255, 255, 0.55)' : 'rgba(0, 0, 0, 0.55)')
          .fontFamily(PlayerConstants.FONT_FAMILY_BLACK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(StyleConstants.FULL_WIDTH)
          .margin({ top: 6 })
      }
    }
    .margin({ top: $r('app.float.music_info_margin_top') })
    .alignItems(HorizontalAlign.Start)
  }
}
