/**
 * ══════════ 顶栏渐变模糊「抛行丢遮罩」绕行 Demo（可运行示例）══════════
 *
 * 背景：主工程 HdsNavigation titleBar 的 HDS 内建滚动模糊
 * （GRADIENT_BLUR 与 IMMERSIVE_GRADIENT_BLUR 两种渐变管线均真机复现）在
 * 手指松手后的惯性滚动（ScrollState.Fling）阶段被系统渲染管线丢弃、
 * 渐变模糊消失，滚动停止后恢复；拖拽阶段始终正常。HDS 管线内无参数可
 * forcing（blurStrategy=ENABLE / thermoCtrl=false 已钉满），官方 FAQ
 * （faqs-arkui-1095）与「设置动态模糊样式」文档的全部可用样例仅在
 * COMMON_BLUR 上验证过滚动绑定链路，渐变类管线无任何官方滚动场景样例。
 *
 * 本 Demo 思路：放弃 HDS 内建渐变管线，改用**组件内容级**线性渐变模糊
 * （linearGradientBlur 通用属性，FAQ faqs-arkui-55 / faqs-arkui-850）：
 * 模糊直接渲染在滚动列表自身内容上 —— 列表视口顶部全模糊、向下渐隐，
 * 内容滚入渐变区即被模糊、滚出恢复清晰，视觉等价「滚动往上穿透到导航栏
 * 的渐变模糊」；且内容级渲染不属 HDS 动态材质合成通路，不受其抛行丢
 * pass 缺陷影响（旁证：主工程底部播放栏的元素级材质在同屏抛行时始终稳定）。
 * HDS 标题栏本体不被模糊（模糊只作用于 List 子树），标题文字始终清晰。
 *
 * ══════════ 三个可疑根因与本 Demo 对策 ══════════
 *
 * 1. 抛滑阶段业务代码主动禁用高开销模糊效果
 *    → onWillScroll 区分 Idle/Drag/Fling；Fling 阶段**只把
 *      模糊半径上限从 20 降到 12（性能降级），绝不移除/隐藏渐变效果**；
 *      onScrollStop 兜底校正偏移漂移并恢复全质量档。
 *
 * 2. Tabs / TabContent 默认 clip=true 裁剪掉越界的渐变遮罩
 *    → 本方案渐变渲染在 List 内容自身、无越界遮罩层，机制上已消除；
 *      仍按需求在 Tabs / TabContent / List 全部显式 clip(false) 防御
 *      （若未来叠加越界遮罩层则必须保留）。
 *
 * 3. 遮罩写在 Scroll 内部、BlendMode 未用 OFFSCREEN 合成丢失
 *    → ⚠️ 本 SDK（6.1.0 / API 23）mask() **没有渐变/Column 重载**
 *      （common.d.ts L21284-21309：仅 Circle/Ellipse/Path/Rect/ProgressMask），
 *      「外层 Stack 渐变遮罩 + BlendApplyType.OFFSCREEN」在本 SDK 无 API
 *      可实现；linearGradientBlur 是唯一官方渐变模糊通路（common.d.ts
 *      L19107，fractionStops + direction，API 12+）。渐变直接进列表内容，
 *      无独立遮罩层、无混合模式依赖 → 该根因从机制上消除。
 *
 * ══════════ 实测结论与本 Demo 对策 ══════════
 *
 * 内容级 linearGradientBlur 在默认抛行速度（惯性初速上限 9000 vp/s）下
 * 同样丢模糊 → HDS 两条渐变管线 + 内容级渐变三条渲染路径同症，而拖拽
 * 速度（约 2-3k vp/s）下三条路径全部存活；flingSpeedLimit 压到 2500
 * 仍丢 → 定论：丢模糊由 ScrollState.Fling **状态本身**触发，与速度/
 * 负载无关。SDK 状态语义（list.d.ts L29-71）：拖拽=Scroll；系统惯性/
 * 回弹/控制器**动画**方法=Fling；控制器**非动画**方法=**Idle**。
 * → 唯一不丢模糊的位移通道：Idle。
 *
 * 机制（自驱惯性，Idle 通道）：onWillScroll 对 Fling 帧返回 { offsetRemain: 0 } 整帧吃掉系统
 * 惯性（列表不再产生任何 Fling 态位移）→ Animator.onFrame 按二次减速
 * 曲线逐帧计算位移 → scroller.scrollBy（**非动画**，ScrollState.Idle）
 * 驱动惯性 → 抛行全程只有 Idle/Scroll 态，渐变模糊理论上全程在场
 * （待真机验证）。
 * 已知取舍：拖过底边缘松手的回弹动画同为 Fling 态、也被吃掉 → 不回弹，
 * 待下次触摸恢复（Demo 已知限制）。
 *
 * ══════════ 结构 ══════════
 *
 * 外层 Stack → HdsNavigation（titleBar 显式 enableScrollEffect:false 关闭
 * HDS 内建滚动模糊管线 = 绕开丢 pass 源头；不再 bindToScrollable）
 * → Tabs（底部双页签，每页签独立 Scroller，FAQ faqs-arkui-1095 场景二口径）
 * → TabContent → List（linearGradientBlur 渐变 + onWillScroll 状态机
 *   + onScrollStop 兜底）。
 *
 * ⚠️ 若你的 HdsNavigation 版本内容区让位标题栏（列表顶边在标题栏下方，
 * 内容不从栏下穿过），需让内容延伸到栏下（expandSafeArea /
 * ignoreLayoutSafeArea 口径）再谈渐变模糊。
 *
 * 运行方式：本页已注册进 main_pages.json（非首页，不影响启动路径），在
 * 工程内任一可执行处调用 router.pushUrl({ url: 'pages/GradientBlurDemoPage' })
 * 即可打开；或把本页临时调成 main_pages.json 的首项直接启动（验证后改回）。
 */

import { HdsNavigation, HdsNavigationTitleMode, DividerShowType } from '@kit.UIDesignKit';
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { STORE_SAFE_TOP } from '../common/Constants';

/** 渐变模糊全质量档半径上限（vp）：Idle / Drag 阶段生效 */
const DEMO_FULL_BLUR_RADIUS: number = 20;

/** 惯性滚动（Fling）性能降级档半径上限（vp）：只降档、绝不移除 */
const DEMO_FLING_BLUR_RADIUS: number = 12;

/** 偏移→模糊强度线性过渡区间（vp）：对齐主工程 0→20 口径，滚过 20vp 封顶 */
const DEMO_BLUR_END_OFFSET: number = 20;

/**
 * 惯性滚动初速上限（vp/s，flingSpeedLimit，系统默认 9000）。
 * 实测 2500 下抛行仍丢模糊 → 速度不是触发因子（Fling 状态才是）。
 * 系统惯性帧被 onWillScroll 整帧吃掉，本属性退化为冗余保险
 * （若吃帧机制失效，系统抛行至少仍被限速）。
 */
const DEMO_FLING_SPEED_LIMIT: number = 2500;

/** 自驱惯性动画时长（ms）：Animator 驱动，二次减速到停 */
const DEMO_INERTIA_DURATION_MS: number = 600;

/** 拖拽速度采样窗口（ms）：仅取窗口内帧估算松手初速 v0 */
const DEMO_VELOCITY_SAMPLE_WINDOW_MS: number = 120;

/** 接管阈值（vp/s）：|v0| 低于此值不启动自驱惯性（微抛自然停住） */
const DEMO_MIN_FLING_VELOCITY: number = 50;

/** HDS MINI 标题栏高度近似值（vp）：内容起始让位量 = safeTop + 本值 */
const DEMO_TITLE_BAR_HEIGHT: number = 56;

/**
 * 渐变模糊空间分布（fractionStops：[模糊程度 0-1, 位置 0-1] 组，位置严格
 * 递增；direction: Bottom = 渐变轴从上到下）：视口顶部全模糊 → 12% 高度
 * 后开始渐隐 → 24% 高度归零。位置是**组件视口比例**、不随内容滚动 ——
 * 内容滚进顶部区域才被模糊、滚出渐变区恢复清晰，即「滚动往上穿透到
 * 导航栏」的空间形态。位置按视口高度取比例，大屏设备渐变区相应变宽。
 */
const DEMO_FRACTION_STOPS: FractionStop[] = [[1, 0], [1, 0.12], [0, 0.24]];

/** 演示列表内容：卡片面积大，模糊渐变肉眼可辨 */
const DEMO_ITEMS: string[] = [
  '演示条目 01', '演示条目 02', '演示条目 03', '演示条目 04',
  '演示条目 05', '演示条目 06', '演示条目 07', '演示条目 08',
  '演示条目 09', '演示条目 10', '演示条目 11', '演示条目 12',
  '演示条目 13', '演示条目 14'
];

/** 卡片配色（循环取用） */
const DEMO_CARD_COLORS: string[] = ['#66A6F1', '#82C8A0', '#F2B866', '#C9A0DC', '#7FB8D8'];

/**
 * 每页签独立的滚动上下文（FAQ faqs-arkui-1095 场景二：页签间严禁共用
 * Scroller，否则滚动模糊互相干扰丢失）。
 */
class DemoTab {
  label: string;
  scroller: Scroller = new Scroller();
  offsetY: number = 0;
  /** 拖拽速度采样（时间戳 ms / 本帧位移 vp，同下标对应） */
  sampleTimes: number[] = [];
  sampleOffsets: number[] = [];
  /** 自驱惯性进行中标记 */
  inertiaDriving: boolean = false;
  /** 自驱惯性动画器（进行中非空） */
  inertiaAnimator: AnimatorResult | null = null;

  constructor(label: string) {
    this.label = label;
  }
}

@Entry
@Component
struct GradientBlurDemoPage {
  /** 状态栏高度（vp）：EntryAbility 全屏布局下首帧前已发布，内容让位用 */
  @StorageLink(STORE_SAFE_TOP) safeTop: number = 0;

  /** 当前页签下标 */
  @State currentTabIndex: number = 0;

  /** 渐变模糊强度 0..1：当前页签滚动偏移线性映射（0→DEMO_BLUR_END_OFFSET vp） */
  @State maskOpacity: number = 0;

  /** 惯性滚动中标记：true = 半径降级到 DEMO_FLING_BLUR_RADIUS（性能降级，不移除） */
  @State isFling: boolean = false;

  private tabs: DemoTab[] = [new DemoTab('列表 A'), new DemoTab('列表 B')];

  /**
   * 当前生效的渐变模糊半径（vp）。
   * · 顶部原始态（强度 0）不模糊，保持干净原始观感；
   * · Fling 只降**上限**（20→12）做性能降级，效果本体永不下线；
   * · 半径随强度线性进入，等价 HDS blurEffectiveStart/EndOffset 的过渡语义。
   */
  private currentBlurRadius(): number {
    if (this.maskOpacity <= 0) {
      return 0;
    }
    const ceiling: number = this.isFling ? DEMO_FLING_BLUR_RADIUS : DEMO_FULL_BLUR_RADIUS;
    return ceiling * this.maskOpacity;
  }

  /** 偏移→强度映射 + Fling 降级标记的唯一写入口 */
  private applyMask(offset: number, fling: boolean): void {
    this.isFling = fling;
    this.maskOpacity = Math.min(1, Math.max(0, offset / DEMO_BLUR_END_OFFSET));
  }

  /**
   * onWillScroll 分发（滚动发生前回调）：
   * · Fling 帧（系统惯性/回弹）：返回 { offsetRemain: 0 } **整帧吃掉**，
   *   列表不再产生任何 Fling 态位移；首次 Fling 帧启动自驱惯性接管。
   * · Scroll 帧（拖拽）：累计偏移 + 采样速度；若自驱惯性仍在跑先取消
   *   （惯性中用户按下手指即接管）。
   * · Idle 帧（自驱 scrollBy 回流）：只累计偏移并更新遮罩，全质量档。
   * 非当前页签的残余滚动不回写（快速抛行中切页签的边缘场景）。
   */
  private handleWillScroll(tab: DemoTab, yOffset: number, scrollState: ScrollState): ScrollResult | void {
    if (scrollState === ScrollState.Fling) {
      if (!tab.inertiaDriving) {
        this.startDrivenInertia(tab);
      }
      const consumed: ScrollResult = { offsetRemain: 0 };
      return consumed;
    }
    if (scrollState === ScrollState.Scroll) {
      if (tab.inertiaDriving) {
        this.stopInertia(tab);
      }
      tab.sampleTimes.push(Date.now());
      tab.sampleOffsets.push(yOffset);
      if (tab.sampleTimes.length > 16) {
        tab.sampleTimes.shift();
        tab.sampleOffsets.shift();
      }
    }
    tab.offsetY = Math.max(0, tab.offsetY + yOffset);
    if (this.tabs[this.currentTabIndex] === tab) {
      this.applyMask(tab.offsetY, false);
    }
    return;
  }

  /** 由拖拽速度采样估算松手初速（vp/s，带方向）：窗口内总位移 / 时间跨度 */
  private estimateVelocity(tab: DemoTab): number {
    const n: number = tab.sampleTimes.length;
    if (n === 0) {
      return 0;
    }
    const newest: number = tab.sampleTimes[n - 1];
    let sum: number = 0;
    let count: number = 0;
    for (let i: number = n - 1; i >= 0; i--) {
      if (newest - tab.sampleTimes[i] > DEMO_VELOCITY_SAMPLE_WINDOW_MS) {
        break;
      }
      sum += tab.sampleOffsets[i];
      count++;
    }
    if (count <= 1) {
      return tab.sampleOffsets[n - 1] / 16 * 1000;
    }
    const span: number = tab.sampleTimes[n - 1] - tab.sampleTimes[n - count];
    if (span <= 0) {
      return tab.sampleOffsets[n - 1] / 16 * 1000;
    }
    return sum / span * 1000;
  }

  /**
   * 自驱惯性：Animator.onFrame 按二次减速曲线 s(p)=D·(1-(1-p)²)
   * 逐帧取位移增量，经**非动画** scroller.scrollBy（ScrollState.Idle 通道）
   * 驱动 → 惯性全程无 Fling 态。初速 v0 由拖拽采样估算，D = v0·T/2000
   * （二次减速下初始速度 2D/T = v0）。
   */
  private startDrivenInertia(tab: DemoTab): void {
    const v0: number = this.estimateVelocity(tab);
    if (Math.abs(v0) < DEMO_MIN_FLING_VELOCITY) {
      return;
    }
    tab.inertiaDriving = true;
    const distance: number = v0 * DEMO_INERTIA_DURATION_MS / 2000;
    const options: AnimatorOptions = {
      duration: DEMO_INERTIA_DURATION_MS,
      easing: 'linear',
      delay: 0,
      fill: 'none',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    };
    const animatorResult: AnimatorResult = this.getUIContext().createAnimator(options);
    tab.inertiaAnimator = animatorResult;
    let lastProgress: number = 0;
    animatorResult.onFrame = (progress: number) => {
      const pos: number = distance * (1 - (1 - progress) * (1 - progress));
      const lastPos: number = distance * (1 - (1 - lastProgress) * (1 - lastProgress));
      lastProgress = progress;
      const delta: number = pos - lastPos;
      if (delta !== 0) {
        tab.scroller.scrollBy(0, delta);
      }
    };
    animatorResult.onFinish = () => {
      tab.inertiaDriving = false;
      tab.inertiaAnimator = null;
      tab.offsetY = Math.max(0, tab.scroller.currentOffset().yOffset);
      if (this.tabs[this.currentTabIndex] === tab) {
        this.applyMask(tab.offsetY, false);
      }
    };
    animatorResult.play();
    hilog.info(0x0000, 'GradientBlurDemo',
      `startDrivenInertia v0=${v0.toFixed(0)}vp/s D=${distance.toFixed(0)}vp T=${DEMO_INERTIA_DURATION_MS}ms`);
  }

  /** 取消自驱惯性（惯性中用户按下手指接管 / 页面销毁） */
  private stopInertia(tab: DemoTab): void {
    if (tab.inertiaAnimator !== null) {
      tab.inertiaAnimator.cancel();
      tab.inertiaAnimator = null;
    }
    tab.inertiaDriving = false;
  }

  /** 页面销毁：释放两个页签的自驱惯性动画器 */
  aboutToDisappear(): void {
    for (let i: number = 0; i < this.tabs.length; i++) {
      this.stopInertia(this.tabs[i]);
    }
  }

  /**
   * onScrollStop：滚动停止时以 Scroller 实测偏移**校正** onWillScroll
   * 增量累加的漂移（回弹、动画滚动等场景），清空速度采样并恢复全质量档。
   */
  private handleScrollStop(tab: DemoTab): void {
    tab.offsetY = Math.max(0, tab.scroller.currentOffset().yOffset);
    tab.sampleTimes = [];
    tab.sampleOffsets = [];
    if (this.tabs[this.currentTabIndex] === tab) {
      this.applyMask(tab.offsetY, false);
    }
  }

  /** 切页签：模糊强度立即对齐新页签已记录的偏移（页签各自独立 Scroller/偏移） */
  private handleTabChange(index: number): void {
    this.currentTabIndex = index;
    const tab: DemoTab = this.tabs[index];
    this.applyMask(tab.offsetY, false);
  }

  @Builder
  DemoCard(item: string, index: number) {
    Column({ space: 8 }) {
      Text(item)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FF222222')
      Row()
        .width('100%')
        .height(88)
        .borderRadius(14)
        .backgroundColor(DEMO_CARD_COLORS[index % DEMO_CARD_COLORS.length])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  DemoList(tab: DemoTab) {
    List({ scroller: tab.scroller, space: 8 }) {
      ForEach(DEMO_ITEMS, (item: string, index: number) => {
        ListItem() {
          this.DemoCard(item, index)
        }
      }, (item: string) => item)
    }
    .width('100%')
    .height('100%')
    .clip(false)                                              // 防御性：显式关闭默认裁剪
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .flingSpeedLimit(DEMO_FLING_SPEED_LIMIT)                  // 冗余保险：系统惯性已被吃帧，此属性仅兜底限速
    .contentStartOffset(this.safeTop + DEMO_TITLE_BAR_HEIGHT) // 内容起始让位状态栏+标题栏；滚动时内容仍从栏下穿过
    .linearGradientBlur(this.currentBlurRadius(), {           // 内容级线性渐变模糊（本 SDK 唯一官方渐变模糊通路）
      fractionStops: DEMO_FRACTION_STOPS,                     //   顶部全模糊 → 24% 视口高度渐隐归零
      direction: GradientDirection.Bottom                     //   渐变轴从上到下
    })
    .onWillScroll((scrollOffset: number, scrollState: ScrollState, scrollSource: ScrollSource) => {
      return this.handleWillScroll(tab, scrollOffset, scrollState)   // Fling 帧吃掉 + 拖拽采样 + 偏移累计
    })
    .onScrollStop(() => {
      this.handleScrollStop(tab)                              // 停止校正 + 恢复全质量
    })
  }

  build() {
    Stack() {
      HdsNavigation() {
        Tabs({ barPosition: BarPosition.End }) {
          ForEach(this.tabs, (tab: DemoTab) => {
            TabContent() {
              this.DemoList(tab)
            }
            .tabBar(tab.label)
            .clip(false)
          }, (tab: DemoTab) => tab.label)
        }
        .clip(false)
        .onChange((index: number) => {
          this.handleTabChange(index)
        })
      }
      .titleBar({
        style: {
          // [关键点] 显式关闭 HDS 内建滚动模糊管线（抛行丢 pass 的源头），
          // 渐变模糊全部由列表内容级 linearGradientBlur 承担；不 bindToScrollable。
          scrollEffectOpts: {
            enableScrollEffect: false
          },
          // 标题栏背景全透明：内容从栏下穿过，由列表自身的渐变模糊呈现
          originalStyle: {
            backgroundStyle: {
              backgroundColor: '#00FFFFFF'
            }
          }
        },
        content: {
          title: {
            mainTitle: '渐变模糊 Demo'
          },
          divider: {
            showType: DividerShowType.OFF
          }
        }
      })
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(true)
      .hideToolBar(true)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
