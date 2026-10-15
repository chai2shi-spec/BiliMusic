/**
 * 常驻迷你播放条（MiniPlayerBar）—— 「悬浮沉浸」底栏样式（NavBarStyle.IMMERSIVE）
 * 的第二层叠加：悬浮在原生 Tabs 页签栏上方，切 Tab 不消失（挂在 Tabs 之外的
 * Stack 层，见 Index.floatingImmersiveNav）。
 *
 * 双态（滚动吸附，见 utils/MiniBarSnapController.ets）：
 *   · 悬浮态（默认）：高 56 / 圆角 24 / 不透明度 1，底部离页签栏顶部 8vp；
 *   · 吸附态：四个 Tab 页列表内容上滚跨阈值后收缩 —— 高 36 / 圆角 0 / 不透明度 0.8，
 *     底边贴住页签栏顶部（间距归零），与页签栏视觉一体；
 *   · 翻转信号走 AppStorage(STORE_MINI_BAR_COLLAPSED)（页面侧写入），
 *     本组件 @StorageProp @Watch 订阅后**本地** animateTo 驱动过渡 ——
 *     跨组件写 AppStorage 无法保证动画作用域，动画必须由持有动画属性的组件驱动；
 *   · 吸附态点击仍可跳播放详情页（PlayBar 恒展开渲染，36vp 矮条容纳 32vp 唱片）。
 *
 * 定位（Stack alignContent: BottomStart 下的自含 margin）：
 *   bottom = floatingBarBottomMargin(safeBottom)（页签栏离底，与 Index 的
 *            barBottomMargin 同一函数，防漂移） + FLOATING_TAB_BAR_HEIGHT（页签栏高）
 *            + 间距（悬浮态 FLOATING_MINI_BAR_GAP / 吸附态 0）；
 *   left / right = FLOATING_MINI_BAR_SIDE_MARGIN（12，两态均保留）。
 *   safeBottom 变化（转屏 / 切三键与手势导航）由 @StorageLink 驱动自动重排。
 *
 * 内容复用 PlayBar（薄封装，不重写播放条逻辑）：
 *   唱片旋转动画、播放 / 暂停、geometryTransition 一镜到底进播放页、队列空不渲染
 *   全部来自 components/PlayBar.ets。悬浮沉浸样式下 Index 保证
 *   STORE_MINI_BAR_EXPANDED = true，PlayBar 恒按展开态（封面 + 歌名/歌手 + 播放键）渲染。
 *
 * 胶囊外壳（本组件自己的职责）：
 *   · 材质：THIN 沉浸材质 + interactive 按压弹性，经 MaterialCompat 兼容层创建
 *     （API 26+ 且设备支持才有；严禁静态 import uiMaterial，低版本启动崩溃，
 *     MaterialCompat 内部已 lazy + 双重守卫）；
 *   · 兜底：材质不可用时（API 23 / 运行时能力缺失）退系统卡片色 + 组件级厚模糊，
 *     深浅色由 sys 资源自动适配；
 *   · 边界：队列空 / 无在播曲目时整体不渲染 —— PlayBar 内部同条件不渲染，
 *     外壳若不守卫会剩一个空胶囊闪现。
 */

import { Track } from '../model/MusicModels';
import { PlayBar } from './PlayBar';
import { MaterialCompat, MaterialCompatStyle } from '../utils/MaterialCompat';
import {
  STORE_QUEUE,
  STORE_CURRENT_TRACK,
  STORE_SAFE_BOTTOM,
  STORE_MINI_BAR_COLLAPSED,
  FLOATING_MINI_BAR_HEIGHT,
  FLOATING_MINI_BAR_COLLAPSED_HEIGHT,
  FLOATING_MINI_BAR_RADIUS,
  FLOATING_MINI_BAR_COLLAPSED_OPACITY,
  FLOATING_MINI_BAR_SIDE_MARGIN,
  FLOATING_MINI_BAR_GAP,
  MINI_BAR_SNAP_DURATION,
  FLOATING_TAB_BAR_HEIGHT,
  floatingBarBottomMargin
} from '../common/Constants';

@Component
export struct MiniPlayerBar {
  /** 播放队列（歌单列表）：为空时胶囊整体不渲染 */
  @StorageLink(STORE_QUEUE) queue: Track[] = [];
  /** 在播曲目：null（无在播曲目）时胶囊整体不渲染 */
  @StorageLink(STORE_CURRENT_TRACK) currentTrack: Track | null = null;
  /**
   * 底部安全区高度（vp）：窗口全屏后系统不自动避让，底部让位的唯一依据。
   * 转屏 / 切三键与手势导航时由 Index 的 avoidAreaChange 动态更新，margin 跟随重排。
   */
  @StorageLink(STORE_SAFE_BOTTOM) safeBottom: number = 0;
  /**
   * 吸附翻转信号（页面侧 MiniBarSnapController 写入）。
   * @StorageProp 单向：本组件只读，动画态落地在 isCollapsed 上。
   */
  @StorageProp(STORE_MINI_BAR_COLLAPSED) @Watch('onCollapsedSignal') collapsedSignal: boolean = false;
  /** 当前落地态（动画作用域内被赋值，驱动全部双态属性）。 */
  @State isCollapsed: boolean = false;

  /**
   * 胶囊沉浸材质（THIN + interactive 按压弹性），构造期经 MaterialCompat 创建一次复用。
   * ⚠️ 不要显式标注 uiMaterial.ImmersiveMaterial 类型 —— 那需要静态 import
   * uiMaterial（API 23 模块加载即崩溃）；也不要写成 `= undefined` 再延迟赋值
   * （初始化表达式会把类型推断成 undefined，后续赋值报错）。MaterialCompat 返回
   * 类型含 lazy 模块类型，由本初始化表达式推断即可。API 26 以下 / 运行时能力
   * 缺失 → undefined，build 里走系统卡片色 + 模糊兜底。
   */
  private barMaterial = MaterialCompat.immersiveMaterial(MaterialCompatStyle.THIN, { interactive: true });

  aboutToAppear(): void {
    // 冷启动对齐：直接落地不动画（挂载时若已吸附，首帧就该是吸附形态）
    this.isCollapsed = this.collapsedSignal;
  }

  /**
   * 吸附信号 @Watch：本地 animateTo 驱动吸附/悬浮过渡。
   * 动画属性（height/borderRadius/opacity/margin）全部在本组件 build 里，
   * 必须在本地动画作用域内改 @State 才有过渡 —— 页面侧写 AppStorage 只当信号。
   */
  onCollapsedSignal(): void {
    if (this.isCollapsed === this.collapsedSignal) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: MINI_BAR_SNAP_DURATION, curve: Curve.EaseInOut },
      (): void => {
        this.isCollapsed = this.collapsedSignal;
      }
    );
  }

  build() {
    // 自带队列守卫（与 PlayBar 同条件）：否则队列清空时会剩一个空材质胶囊
    if (this.queue.length > 0 && this.currentTrack !== null) {
      Row() {
        // 恒展开态：悬浮沉浸样式下 Index 保证 STORE_MINI_BAR_EXPANDED = true
        PlayBar()
      }
      .width('100%')
      .height(this.isCollapsed ? FLOATING_MINI_BAR_COLLAPSED_HEIGHT : FLOATING_MINI_BAR_HEIGHT)
      .padding({ left: 8, right: 8 })
      // 吸附态圆角归零（与页签栏对齐成一体）；悬浮态 24 胶囊圆角
      .borderRadius(this.isCollapsed ? 0 : FLOATING_MINI_BAR_RADIUS)
      // 56→36 收缩时把超高的 PlayBar 内容裁进矮条，不让文字/唱片溢出边界
      .clip(true)
      // 吸附态降不透明度让位内容；悬浮态全不透明
      .opacity(this.isCollapsed ? FLOATING_MINI_BAR_COLLAPSED_OPACITY : 1)
      // 材质 / 兜底双通道：26+ 且支持 → systemMaterial 生效、背景透明；
      // 否则 systemMaterial(undefined) 被忽略，走系统卡片色 + 组件级厚模糊兜底
      .systemMaterial(this.barMaterial)
      .backgroundColor(this.barMaterial === undefined
        ? $r('sys.color.comp_background_list_card') : Color.Transparent)
      .backgroundBlurStyle(this.barMaterial === undefined
        ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE)
      // 常驻悬浮定位：bottom = 页签栏离底(动态) + 页签栏高 56 + 间距
      // （悬浮态 8vp / 吸附态归零贴住页签栏顶部），切 Tab 不消失
      .margin({
        left: FLOATING_MINI_BAR_SIDE_MARGIN,
        right: FLOATING_MINI_BAR_SIDE_MARGIN,
        bottom: floatingBarBottomMargin(this.safeBottom) + FLOATING_TAB_BAR_HEIGHT
          + (this.isCollapsed ? 0 : FLOATING_MINI_BAR_GAP)
      })
    }
  }
}
