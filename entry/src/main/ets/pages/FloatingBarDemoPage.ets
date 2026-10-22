/**
 * ══════════ 悬浮 HdsTabs 底部导航「视觉不居中」修复参考实现（可运行示例）══════════
 *
 * 背景（2026-10-22）：阔折叠 / 阔直板大屏展开态出现底部导航视觉不居中，根因两点：
 *   1. 系统手势指示条（导航规避区）高度随形态变化，代码用写死的 bottom padding /
 *      高度阈值（如旧实现「safeBottom > 36vp 猜三键」）→ 大屏上误判 → 偏移；
 *   2. 自定义 padding / margin 与 HdsTabs 悬浮避让逻辑（barBottomMargin +
 *      内置安全区处理）叠加冲突 → 双重避让 → 错位。
 *
 * 本页修复口径（与 pages/Index.ets 主实现同源）：
 *   · getWindowAvoidArea(TYPE_NAVIGATION_INDICATOR / TYPE_SYSTEM) 动态实测，
 *     avoidAreaChange 监听更新，UIContext.px2vp 换算，不写死任何 vp 阈值；
 *   · 悬浮模式 = barOverlap(true) + barFloatingStyle(barBottomMargin) +
 *     systemMaterialEffect 沉浸光感；底部避让**只由 barBottomMargin 一层承担**，
 *     根容器 / HdsTabs / 页签项不再叠任何 bottom padding；
 *   · 非悬浮模式 = barOverlap(false)：HdsTabs 内置安全区避让自动把页签栏抬到
 *     手势条上方 —— 此时**再设 barBottomMargin / 自加 padding 就是双重避让**。
 *     两种模式的居中逻辑不同，切换按钮可实时对比；
  *   · 水平居中（坑 B3/B4）：HDS 悬浮栏底左锚定，宽 ≥600vp 时反算
  *     barSideMargin=(容器宽−304)/2 居中，并用 barWidth 锁死胶囊宽
  *     （onAreaChange 实测宽度），<600vp 走默认。
 *
 * ══════════ 容易造成不居中的坑位清单（注释中 [坑N] 逐条对应）══════════
 *
 * 【问题 A：组件自身内部图标 / 文字不居中】—— 图标文字在页签胶囊里上下不均：
 *   A1. tabItem 根 Column 未设 alignItems(Center) / justifyContent(Center)，
 *       或高度没撑满页签栏（height('100%')），内容贴顶/贴底；
 *   A2. 页签栏高度被固定值锁死（barHeight 写死）后，内置安全区避让失效，
 *       出血样式（图标出血）叠加时更容易内部错位；
 *   A3. miniBar builder 内容高度与页签栏高度不一致（HDS 要求等高水平对齐）。
 *
 * 【问题 B：整个 Tab 栏容器在屏幕上位置偏移】—— 胶囊整体偏上/偏下/偏左偏右：
 *   B1.（垂直）barBottomMargin 没按导航模式动态折算：三键导航栏（TYPE_SYSTEM
 *       底部矩形 > 0）必须整条避让；手势指示条（TYPE_NAVIGATION_INDICATOR）只避
 *       一半。按固定高度阈值「猜」模式，在阔折叠 / 阔直板大屏（指示条高度与手机
 *       不同、密度不同、分屏会变）必猜错 → 偏移；
 *   B2.（垂直）双重避让：全屏布局（setWindowLayoutFullScreen）下 HdsTabs 底边 =
 *       物理屏幕底边，barBottomMargin 必须自带避让；但同时又给根容器 / HdsTabs
 *       叠了 padding.bottom（或非全屏布局下再设 barBottomMargin 含避让量）→
 *       离底留白翻倍。**避让只允许一层**；
 *   B3.（水平）HdsTabs 未占满父容器宽（width 100% 缺失 / 父容器不对称 padding）：
 *       HDS 悬浮页签栏**底左锚定**于 HdsTabs 容器（dumpLayout 实测：barSideMargin
 *       是胶囊左缘缩进，默认分档 16/24/32vp，单胶囊始终贴容器左缘），容器不正
 *       或缩进错算，胶囊必不居中；
  *   B4.（水平）⚠️ 实测纠偏（2026-10-22）：barSideMargin **不是**两侧对称边距 ——
  *       HDS 悬浮栏底左锚定，队列空时单胶囊只从左缘缩进，右侧空出（阔折叠 /
  *       阔直板大屏展开态「视觉不居中」的水平根因）。且不设 barWidth 时胶囊宽
  *       随边距漂移（dumpLayout 实测：默认→328、S=83→304、S=318→272），反算
  *       公式里的「宽」不可控。居中必须**锁宽 + 反算**两步：
  *       ① barWidth 锁死胶囊宽（HdsBarWidthRangeOptions，md/lg 两档同值）；
  *       ② sideMargin = (容器宽 − 锁定宽) ÷ 2（宽 ≥600vp 才需要；手机宽度
  *       胶囊近满宽，默认即视觉居中）。带 miniBar 时 HDS 自动两胶囊对称散开
  *       （整体居中），无需干预；
 *   B5.（动态）折叠开合 / 分屏 / 转屏 / 切导航模式后位置不重算：必须监听
 *       avoidAreaChange（本页 bindAvoidArea），样式输入（避让区高度）变化后
 *       barFloatingStyle 受控重建才生效；宽度同理走 onAreaChange 回写。
 *
 * 排查口诀：先截图量「胶囊相对屏幕底边 / 手势条」的距离（问题 B），再量「图标相对
 * 胶囊上下边」的留白（问题 A）—— 两类问题修法完全不同，别混在一起调。
 *
 * 运行方式：本页已注册进 main_pages.json（非首页，不影响启动路径），在工程内任一
 * 可执行处调用 router.pushUrl({ url: 'pages/FloatingBarDemoPage' }) 即可打开；
 * 或把本页临时调成 main_pages.json 的首项直接启动。
 */

import { UIContext } from '@kit.ArkUI';
import { HdsTabs, HdsTabsFloatingStyle, HdsBarWidthRangeOptions, hdsMaterial } from '@kit.UIDesignKit';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';

/**
 * 悬浮页签栏离屏幕底边的净间距（vp，**不含**避让区 —— 避让量按导航模式动态叠加）。
 * 这是「设计留白」，不是避让值：避让值永远来自 getWindowAvoidArea 实测。
 */
const DEMO_BAR_NET_BOTTOM_MARGIN: number = 6;

/**
 * 悬浮页签胶囊**锁定**宽度（vp，4 页签）：barFloatingStyle.barWidth 显设值，
 * 居中公式 sideMargin=(容器宽−本值)/2 的被减数。选 304（= 76×4）与「队列非空
 * lg 双胶囊散开」时 HDS 的实测宽度一致，跨状态切换宽度不跳变。
 * ⚠️ 不锁宽时 HDS 宽度随边距漂移（dumpLayout 实测：默认→328、S=83→304、
 * S=318→272），公式里的「宽」不可控，必须配 barWidth 一起设（坑 B4）。
 * 若 HDS 版本升级导致宽度漂移，用 uitest dumpLayout 重测本校准。
 */
const DEMO_BAR_FLOATING_WIDTH: number = 304;

@Entry
@Component
struct FloatingBarDemoPage {
  /**
   * 三键导航栏避让区高度（vp，TYPE_SYSTEM 底部矩形）：>0 即三键导航 ——
   * 模式判据 = 避让区**来源**，不写死高度阈值（坑 B1）。
   */
  @State navBarBottomVp: number = 0;

  /** 手势指示条避让区高度（vp，TYPE_NAVIGATION_INDICATOR 底部矩形）：手势导航非 0 */
  @State indicatorBottomVp: number = 0;

  /** 模式开关：true = 悬浮（barOverlap=true），false = 非悬浮（barOverlap=false） */
  @State floatingMode: boolean = true;

  /** HdsTabs 实铺宽度（vp，onAreaChange 回写）：折叠开合 / 分屏 / 转屏自动更新 */
  @State hdsTabsWidthVp: number = 0;

  /** 主窗口句柄，仅用于注销 avoidAreaChange 监听（防回调泄漏） */
  private mainWindow: window.Window | null = null;

  aboutToAppear(): void {
    this.bindAvoidArea();
  }

  aboutToDisappear(): void {
    this.unbindAvoidArea();
  }

  /**
   * [坑 B5] 取主窗口 → 主动读一次避让区 → 注册 avoidAreaChange。
   * 折叠开合 / 分屏 / 转屏 / 三键与手势导航切换都会改变避让区高度，不监听就会
   * 一直沿用旧值（胶囊位置错）。全工程只注册这一处，避免多处重复写同一份数据。
   */
  private bindAvoidArea(): void {
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx)
      .then((win: window.Window): void => {
        this.mainWindow = win;
        this.readAvoidArea(win);
        win.on('avoidAreaChange', (): void => {
          this.readAvoidArea(win);
        });
      })
      .catch((err: BusinessError): void => {
        console.error(`[FloatingBarDemo] getLastWindow failed: ${err.code} ${err.message}`);
      });
  }

  private unbindAvoidArea(): void {
    const win: window.Window | null = this.mainWindow;
    if (win !== null) {
      try {
        win.off('avoidAreaChange');
      } catch (e) {
        const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
        console.error(`[FloatingBarDemo] unbindAvoidArea failed: ${msg}`);
      }
      this.mainWindow = null;
    }
  }

  /**
   * [坑 B1] 读窗口避让区 → px 转 vp → 分来源存 @State。
   * 两个来源分开读，不能用 max 合并成单值再猜模式：
   *   TYPE_SYSTEM 底部矩形          = 三键导航栏（可点击系统控件，整条避让）
   *   TYPE_NAVIGATION_INDICATOR 底部 = 手势指示条（只避一半，胶囊下沉贴近底边）
   * px→vp 必须用 UIContext.px2vp（本页在 UI 上下文内）；EntryAbility 等非 UI
   * 上下文里用 display.densityPixels 手算 —— 两种换算结果一致，混用 px/vp 不换算
   * 是大屏偏移的另一高发来源（大屏密度普遍 3.0+，1px 误差被放大 3 倍）。
   */
  private readAvoidArea(win: window.Window): void {
    try {
      const ui: UIContext = this.getUIContext();
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.navBarBottomVp = ui.px2vp(sys.bottomRect.height);
      this.indicatorBottomVp = ui.px2vp(indicator.bottomRect.height);
      console.info(`[FloatingBarDemo] avoidArea: navBar=${this.navBarBottomVp}vp indicator=${this.indicatorBottomVp}vp`);
    } catch (e) {
      const msg: string = e instanceof Error ? `${e.name}: ${e.message}` : JSON.stringify(e);
      console.error(`[FloatingBarDemo] readAvoidArea failed: ${msg}`);
    }
  }

  /**
   * [坑 B1/B2] 悬浮模式 barBottomMargin 折算（唯一一层避让，别处不得再叠）：
   *   三键导航（navBarBottomVp > 0）→ 6 + 整条导航栏高度（完整避让）
   *   手势导航（否则）            → 6 + 指示条避让区 × 0.5（避一半，贴近底边）
   * 全部动态实测值，无任何写死 vp 阈值。@State 变化 → 本方法返回值变化 →
   * barFloatingStyle 受控重建 → 位置自动重算（坑 B5 的另一半）。
   */
  private barBottomMarginVp(): number {
    return DEMO_BAR_NET_BOTTOM_MARGIN + (this.navBarBottomVp > 0
      ? this.navBarBottomVp
      : this.indicatorBottomVp * 0.5);
  }

  /**
   * 悬浮样式：systemMaterialEffect 沉浸光感（IMMERSIVE + ADAPTIVE 自适应档；
   * 换 EXQUISITE 前必须先查设备材质能力，不支持会卡顿发热）。
   * [坑 B4] barSideMargin 水平锚定：HDS 底左锚定，宽 ≥600vp（阔折叠 / 阔直板
   * 大屏展开）时单胶囊贴左不居中 —— 反算 sideMargin=(宽−304)/2 居中，并用
   * barWidth 锁死胶囊宽（显设边距时 HDS 宽度会漂移：实测默认→328、S=83→304、
   * S=318→272，不锁宽则公式里的「宽」不可控）；<600vp（手机）胶囊近满宽，
   * 不设置走 HDS 分档默认（16/24/32vp）即视觉居中。
   */
  private centeredSideMargin(): number | undefined {
    if (this.hdsTabsWidthVp < 600) {
      return undefined;
    }
    return Math.max(0, (this.hdsTabsWidthVp - DEMO_BAR_FLOATING_WIDTH) / 2);
  }

  /** 居中分支的 barWidth 锁宽（md/lg 两档同值，覆盖 ≥600vp 全部 HDS 分档） */
  private centeredBarWidth(): HdsBarWidthRangeOptions | undefined {
    if (this.hdsTabsWidthVp < 600) {
      return undefined;
    }
    return {
      mediumWidth: DEMO_BAR_FLOATING_WIDTH,
      largeWidth: DEMO_BAR_FLOATING_WIDTH
    };
  }

  /** 面板展示用：居中 sideMargin 的可读文本（build 体内不能声明局部变量） */
  private centeredSideMarginText(): string {
    const m: number | undefined = this.centeredSideMargin();
    if (m === undefined) {
      return '默认（<600vp）';
    }
    return `${m.toFixed(1)}vp`;
  }

  private floatingStyle(): HdsTabsFloatingStyle {
    return {
      barBottomMargin: this.barBottomMarginVp(),
      barSideMargin: this.centeredSideMargin(),
      barWidth: this.centeredBarWidth(),
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
  }

  /**
   * [坑 A1] 页签项：根 Column 必须 alignItems + justifyContent 双居中且
   * height('100%') 撑满页签栏高度 —— 缺哪个，图标文字就在胶囊里偏哪边。
   * （这是「组件内部不居中」问题的修法，与整栏位置无关。）
   */
  @Builder
  demoTabItem(label: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([$r('sys.color.font_secondary')])
      Text(label)
        .fontSize(11)
        .fontColor($r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }

  @Builder
  demoContent(text: string) {
    Scroll() {
      Column() {
        Text(text)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 24, bottom: 12 })
        // 长列表：悬浮模式下内容从胶囊材质下透出（barOverlap 的意义所在）
        ForEach([
          '列表项 01 —— 内容延伸到底部手势条下方', '列表项 02', '列表项 03', '列表项 04',
          '列表项 05', '列表项 06', '列表项 07', '列表项 08', '列表项 09', '列表项 10',
          '列表项 11', '列表项 12', '列表项 13', '列表项 14', '列表项 15', '列表项 16',
          '列表项 17', '列表项 18', '列表项 19', '列表项 20'
        ], (item: string) => {
          Text(item)
            .fontSize(14)
            .padding(16)
            .width('100%')
        }, (item: string) => item)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 四个页签（两个 HdsTabs 分支共用一份内容 Builder） */
  @Builder
  demoTabContents() {
    TabContent() {
      this.demoContent('页签一（悬浮模式对比演示）')
    }.tabBar(this.demoTabItem('页签一', $r('sys.symbol.house')))

    TabContent() {
      this.demoContent('页签二')
    }.tabBar(this.demoTabItem('页签二', $r('sys.symbol.list_bullet')))

    TabContent() {
      this.demoContent('页签三')
    }.tabBar(this.demoTabItem('页签三', $r('sys.symbol.circle_and_arrow_down')))

    TabContent() {
      this.demoContent('页签四')
    }.tabBar(this.demoTabItem('页签四', $r('sys.symbol.gearshape')))
  }

  build() {
    Column() {
      // 顶部实时数据面板：避让区实测值 / 折算结果 / 模式切换
      Column({ space: 4 }) {
        Text('悬浮 HdsTabs 底部导航居中参考实现')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
        Text(`三键导航栏 ${this.navBarBottomVp.toFixed(1)}vp / 手势指示条 ${this.indicatorBottomVp.toFixed(1)}vp（avoidAreaChange 动态实测）`)
          .fontSize(11)
        Text(`barBottomMargin = ${this.barBottomMarginVp().toFixed(1)}vp（${this.navBarBottomVp > 0 ? '三键 · 整条避让' : '手势 · 避一半指示条'}）`)
          .fontSize(11)
        Text(`HdsTabs 宽 ${this.hdsTabsWidthVp.toFixed(0)}vp → 居中 sideMargin = ${this.centeredSideMarginText()}`)
          .fontSize(11)
        Button(this.floatingMode
          ? '当前：悬浮模式 → 点切非悬浮 barOverlap=false'
          : '当前：非悬浮模式 → 点切悬浮 barOverlap=true')
          .fontSize(13)
          .margin({ top: 4 })
          .onClick((): void => {
            this.floatingMode = !this.floatingMode;
          })
      }
      .width('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Center)

      // [坑 B3] 两种模式互斥挂载。HdsTabs 占满剩余宽高（width 100% +
      // layoutWeight），其底边 = 物理屏幕底边（窗口全屏布局下）—— 组件在父容器
      // 水平居中 / 占满，是 HDS 内部「胶囊居中」成立的前提。
      if (this.floatingMode) {
        // 悬浮模式（barOverlap=true）：页签栏浮在内容之上，位置由
        // barFloatingStyle.barBottomMargin 唯一决定 —— 避让量折算在
        // barBottomMarginVp() 里，**本分支不得再给任何容器加 bottom padding**（坑 B2）。
        HdsTabs() {
          this.demoTabContents()
        }
        .vertical(false)
        .barPosition(BarPosition.End)
        .barMode(BarMode.Fixed)
        .barOverlap(true)
        .barFloatingStyle(this.floatingStyle())
        .width('100%')
        .layoutWeight(1)
        // [坑 B5] 宽度持续实测：折叠开合 / 分屏 / 转屏后重排即回写，
        // 居中 sideMargin 随之自动重算（barFloatingStyle 受控重建生效）
        .onAreaChange((_old: Area, cur: Area): void => {
          const w: Length = cur.width;
          if (typeof w === 'number' && w > 0) {
            this.hdsTabsWidthVp = w;
          }
        })
      } else {
        // 非悬浮模式（barOverlap=false）：HdsTabs 内置安全区避让自动把页签栏
        // 抬到指示条 / 导航栏上方 —— **不设 barFloatingStyle、不加任何 bottom
        // padding**，加了就是与内置避让双重叠加（坑 B2），离底留白翻倍。
        // 居中逻辑与悬浮模式不同：它不需要（也不认）barBottomMargin。
        HdsTabs() {
          this.demoTabContents()
        }
        .vertical(false)
        .barPosition(BarPosition.End)
        .barMode(BarMode.Fixed)
        .barOverlap(false)
        .width('100%')
        .layoutWeight(1)
      }
    }
    // [坑 B2] 根容器严禁 padding.bottom：全屏布局下它会整体截短内容区（列表
    // 铺不到屏幕最底），且与悬浮避让 / 内置避让叠加成双重避让。
    .width('100%')
    .height('100%')
  }
}
