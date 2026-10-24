/**
 * 二级页沉浸光感悬浮播放栏（2026-10-23 建栏，2026-10-24 改 HDS miniBar 官方通路）：
 * push 出的 NavDestination 盖住整个 HdsNavigation 内容区（含首页 HDS 悬浮胶囊），
 * 二级页此前底部无任何播放栏、也无法进播放页 —— 本组件补这个缺口。
 *
 * 架构：Index 根 Stack **全局单实例**挂载（在壳之后、播放页 overlay 之前），
 * 由 NavStackHolder 双写的 STORE_SUB_PAGE_ACTIVE 门控（任意 NavDestination
 * 在栈顶即 true，首页 navBar 为 false）+ 播放队列非空 —— 覆盖全部 9 个推送
 * 二级页（UpSpace / PlaylistDetail / Recent / Follows / WatchHistory /
 * CloudSync / PlaylistImport / About / Login），二级页互推链路（歌单详情 →
 * UP 主页等）标志恒 true、栏全程在场不闪。
 *
 * 互斥（geometryTransition id 全窗口唯一）：本栏挂载期间 Index 的
 * barFloatingStyle 不带 miniBar（首页胶囊退回纯页签）、tabletPlayBar 同步
 * 摘除 —— 全窗口同一时刻只有一套 GEOMETRY_ID_PLAYER_DISC / _SURFACE 锚点，
 * 摘除与挂载在同一次 Index 重渲染（同一帧）完成。
 *
 * 内容复用 PlayBar（standalone 模式）：切歌 / 进度 / 唱片旋转 / 封面
 * geometryTransition 飞行 / openPlayer 全部白拿，与首页胶囊同源。
 *
 * 视觉（A案：HDS miniBar 通路，2026-10-24）：二号 HdsTabs 挂根 Stack，
 * PlayBar 放唯一 TabContent 对应的 miniBar（恒 EXPAND），沉浸光感走
 * systemMaterialEffect（IMMERSIVE + EXQUISITE/ADAPTIVE）+ lightColor 主题色
 * 光晕 —— 与首页 HDS 胶囊完全同源的真机已验证通路。页签胶囊用
 * barOpacity:0 隐藏（唯一 TabContent 的 tabBar 为空内容、barWidth 压到 2vp
 * 缩小隐形死区）。
 * 方案沿革（根因存档，官方《沉浸光感常见问题》）：「其他组件」的
 * systemMaterial 仅在 Navigation/NavDestination 标题栏或横向 Tabs 底部
 * TabBar 生效 —— 初版自绘 Row 直接挂 .systemMaterial() 真机静默全透明；
 * B案普通 Tabs barFloatingStyle.systemMaterial 生效但观感不达预期；
 * 本版（A案）回到 HDS 内部材质通路，与首页视觉语言完全一致。
 * ⚠️ 已知风险（真机验证项）：HdsTabsMiniBar.enableMiniBarBackground 语义
 * 「迷你栏背景跟随页签栏」—— barOpacity:0 可能连带 miniBar 材质一起隐藏
 * （Index 曾实测 enableMiniBarBackground:false 会导致 IMMERSIVE 材质与
 * lightColor 均不渲染）；若真机复现，回退 B案或恢复毛玻璃版（备份可回）。
 *
 * 定位与避让：HdsTabs 全屏载体（barPosition End + barOverlap(true)），
 * 悬浮位置由 barFloatingStyle 唯一决定：barBottomMargin = 2 + (三键导航栏
 * > 0 ? 三键导航栏 : 手势指示条)（与旧版同公式同口径）；miniBar 宽 =
 * 一级页 miniBar 展开态实测槽位宽（Index.onBarStyleChange 经
 * STORE_MAIN_MINI_BAR_WIDTH 回传，2026-10-24 起 —— HDS 默认宽在编译产物
 * 里不可推导，实测是唯一可靠口径；未测量首帧回退自算「载体宽 − 50 封顶
 * 600」）；水平 barSideMargin = (载体宽 − miniBar宽) ÷ 2 精确居中
 * （2026-10-24 修「右缘离屏距 ≠ 左缘」，见 floatingStyle 内注释）。
 * 载体 hitTestBehavior
 * Transparent —— 栏外空白 TabContent 区点击穿透到下方页面，列表照常可点可
 * 可滚。挂载 / 卸载挂 250ms OPACITY transition 软化浮现。列表末条避让由
 * 既有 CONTENT_END_OFFSET=160 保证，页面零改动。
 */

import { PlayBar } from './PlayBar';
import { MaterialCompat } from '../utils/MaterialCompat';
import { MaterialTokens } from '../common/style/MaterialTokens';
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsTabsMiniBar,
  HdsTabsBarChangeMode,
  HdsBarStyle
} from '@kit.UIDesignKit';
import {
  STORE_NAV_BAR_BOTTOM,
  STORE_NAV_INDICATOR_BOTTOM,
  STORE_THEME_PRIMARY,
  STORE_MAIN_MINI_BAR_WIDTH,
  GLOW_ALPHA
} from '../common/Constants';

/**
 * miniBar 宽度预算里的左右边距分量（vp，对齐首页内容区 NAV_H_PADDING 口径）。
 * ⚠️ 2026-10-24 起不再是「可见边距」：可见胶囊由 barSideMargin 精确居中
 * （见 floatingStyle 内注释），实际左右离屏距 = 本值 + (隐藏页签宽 + 间距
 * 预算) ÷ 2 = 16 + 9 = 25vp —— 对称优先于精确 16。
 */
const SUB_PAGE_BAR_SIDE_MARGIN_VP: number = 16;
/** 胶囊净离底间距（vp）：与旧版悬浮胶囊同值（HDS 版净距沿用，别叠第二层 padding） */
const SUB_PAGE_BAR_BOTTOM_MARGIN_VP: number = 2;
/** 宽屏下 miniBar 最大宽度（vp）：收窄居中，防阔折叠 / 平板上横贯过宽（仅未测量回退分支用） */
const SUB_PAGE_BAR_MAX_WIDTH_VP: number = 600;
/** 挂载 / 卸载淡入淡出时长（ms）：栏不随页面转场滑入（单实例取舍），用淡入软化 */
const SUB_PAGE_BAR_FADE_MS: number = 250;
/**
 * 载体宽回写前占位值（vp）：onAreaChange 首帧布局即回写真实宽，0 只存在于
 * 首次测量前的瞬时；按手机竖屏基准占位，避免首帧宽度算出 0/负值。
 */
const SUB_PAGE_BAR_WIDTH_FALLBACK_VP: number = 360;
/**
 * 隐藏页签胶囊宽度（vp，标定值）：barOpacity:0 只藏渲染不除命中区，
 * 宽度压到最小（2vp）把隐形死区缩到可忽略；过小可能被 HDS 内部钳制 ——
 * 真机观察 miniBar 实际宽度后可再调。
 */
const SUB_PAGE_HIDDEN_TAB_WIDTH_VP: number = 2;
/**
 * miniBar 与页签胶囊的间距预算（vp，标定值）：miniBarWidth 计算里预留，
 * 防「miniBar 宽 + 隐藏页签宽 + 间距」超过载体宽被 HDS 压缩 / 溢出。
 * 真机量出实际间距后可精调。
 */
const SUB_PAGE_BAR_GAP_BUDGET_VP: number = 16;

@Component
export struct SubPagePlayBar {
  /** 三键导航栏避让区高度（vp，TYPE_SYSTEM.bottomRect）：>0 即三键导航，完整避让 */
  @StorageLink(STORE_NAV_BAR_BOTTOM) navBarBottom: number = 0;
  /** 手势指示条避让区高度（vp）：手势导航下完整避开指示条 */
  @StorageLink(STORE_NAV_INDICATOR_BOTTOM) navIndicatorBottom: number = 0;
  /** 主题色主色（hex 字符串，ThemeColors 发布）：lightColor 光晕用色，切主题即时跟随 */
  @StorageProp(STORE_THEME_PRIMARY) themePrimary: string = '#FB7299';

  /**
   * 一级页 miniBar 展开态槽位实测宽（vp，0 = 尚未测量，见 Constants 键注释）：
   * Index.onBarStyleChange 回写。宽度直接采用该值 —— 与一级页底栏恒同宽
   * （2026-10-24 修「二级页播放栏宽 ≠ 一级页底栏宽」：此前自算
   * 「载体宽 − 50 封顶 600」与一级页 HDS 默认宽天然不等）。
   */
  @StorageProp(STORE_MAIN_MINI_BAR_WIDTH) mainMiniBarWidthVp: number = 0;

  /** 载体实铺宽度（vp，onAreaChange 回写）：折叠开合 / 分屏 / 转屏自动更新 */
  @State hostWidthVp: number = 0;

  /** HDS 控制器：onBarStyleChange 里把意外收起的 miniBar 拉回 EXPAND */
  private tabController: HdsTabsController = new HdsTabsController();

  /** 设备是否支持 HDS IMMERSIVE 精美档（不支持回落 ADAPTIVE 自适应，防低配卡顿） */
  private useExquisiteMaterial: boolean = false;

  /** 悬浮样式缓存（键不变直接复用，避免每次重渲染重放配置触发 HDS 内部重建） */
  private cachedStyle: HdsTabsFloatingStyle | null = null;
  /** 样式缓存的内容键（见 cachedStyle 注释） */
  private cachedStyleKey: string = '';

  aboutToAppear(): void {
    this.useExquisiteMaterial = MaterialCompat.supportsImmersiveMaterial();
  }

  /** 载体有效宽（vp）：onAreaChange 首帧即回写真实值，占位值仅首测前生效 */
  private hostWidthOrFallback(): number {
    return this.hostWidthVp > 0 ? this.hostWidthVp : SUB_PAGE_BAR_WIDTH_FALLBACK_VP;
  }

  /**
   * miniBar 宽（vp）：一级页实测宽优先 —— 直接采用 Index.onBarStyleChange
   * 发布的一级页 miniBar 展开态槽位宽（2026-10-24 修「二级页播放栏宽 ≠
   * 一级页底栏宽」，HDS 默认宽不可从源码推导，实测回传唯一可靠口径），
   * 仅在超出载体宽时分屏极端场景夹取；barSideMargin 居中公式自动还原
   * 一级页同款左右边距。未测量（0，理论仅首帧 / 首次进二级页）回退自算
   * 公式：载体宽扣边距、隐藏页签宽与间距预算后取值，宽屏收窄 600。
   */
  private floatingBarWidthVp(): number {
    const host: number = this.hostWidthOrFallback();
    if (this.mainMiniBarWidthVp > 0) {
      return Math.min(this.mainMiniBarWidthVp, host);
    }
    const inner: number = host
      - SUB_PAGE_BAR_SIDE_MARGIN_VP * 2
      - SUB_PAGE_HIDDEN_TAB_WIDTH_VP
      - SUB_PAGE_BAR_GAP_BUDGET_VP;
    return Math.min(Math.max(inner, 0), SUB_PAGE_BAR_MAX_WIDTH_VP);
  }

  /**
   * HDS 悬浮样式（受控重建 + 内容键缓存，同 Index.barFloatingStyle 手法）：
   * @State（载体宽 / 避让量 / 主题色）变化 → 键变化 → 新样式对象 → HdsTabs
   * 受控重建，位置 / 宽度 / 光晕自动重算；键不变时复用旧对象，不触发重建。
   */
  private floatingStyle(): HdsTabsFloatingStyle {
    const key: string = `${this.navBarBottom}|${this.navIndicatorBottom}`
      + `|${this.themePrimary}|${this.hostWidthVp}`
      + `|${this.useExquisiteMaterial ? 1 : 0}`
      + `|${this.mainMiniBarWidthVp}`;
    if (this.cachedStyle !== null && this.cachedStyleKey === key) {
      return this.cachedStyle;
    }
    const barW: number = this.floatingBarWidthVp();
    // 可见 miniBar 的水平居中边距（vp）：推导见下方 barSideMargin 注释。
    const sideMargin: number = Math.max(0, (this.hostWidthOrFallback() - barW) / 2);
    const mini: HdsTabsMiniBar = {
      miniBarBuilder: (): void => {
        this.subPageBarHost();
      },
      // ⚠️ 必须显式 true（Index 同款结论）：关成 false 会让 miniBar 段失去
      // IMMERSIVE 材质背景与 lightColor 光晕（「迷你栏沉浸光感消失」根因）。
      enableMiniBarBackground: true,
      // 恒展开：standalone PlayBar 没有收起交互，本栏语义就是常驻整行。
      // 若被 HDS 系统重排（NORMAL）意外收起，onBarStyleChange 里拉回。
      miniBarStyle: HdsBarStyle.EXPAND,
      miniBarWidth: { smallWidth: barW, mediumWidth: barW, largeWidth: barW },
      onBarStyleChange: (miniBarStyle: HdsBarStyle, _tabBarStyle: HdsBarStyle,
        _miniBarWidth: number, _tabBarWidth: number, _mode: HdsTabsBarChangeMode): void => {
        // 任何来源（系统重排 / 用户误触）把 miniBar 收起都拉回 EXPAND：
        // 本栏无收起语义。applyMiniBarStyle 会再触发本回调，EXPAND 时为 no-op，无环。
        if (miniBarStyle !== HdsBarStyle.EXPAND) {
          console.info(`[SubPagePlayBar] miniBar collapsed (${miniBarStyle}, mode=${_mode}) -> force EXPAND`);
          this.tabController.applyMiniBarStyle(HdsBarStyle.EXPAND);
        }
      }
    };
    const style: HdsTabsFloatingStyle = {
      // 隐藏页签胶囊（A案核心手段）：唯一 TabContent 的页签项只当占位，
      // 渲染上整体透明；barWidth 压到 2vp 缩小隐形命中死区。
      barOpacity: 0,
      barWidth: {
        smallWidth: SUB_PAGE_HIDDEN_TAB_WIDTH_VP,
        mediumWidth: SUB_PAGE_HIDDEN_TAB_WIDTH_VP,
        largeWidth: SUB_PAGE_HIDDEN_TAB_WIDTH_VP
      },
      miniBar: mini,
      // 底部避让（与旧版同公式同口径）：净距 2 + (三键导航栏 > 0 ? 三键导航栏
      // : 手势指示条)。⚠️ 全屏布局下 HdsTabs 底边 = 物理屏幕底边，避让必须
      // 全部折在这一个值里，别在容器再叠 padding.bottom（双重避让坑）。
      barBottomMargin: SUB_PAGE_BAR_BOTTOM_MARGIN_VP + (this.navBarBottom > 0
        ? this.navBarBottom
        : this.navIndicatorBottom),
      // 水平居中（2026-10-24 修「播放栏右缘离屏距 ≠ 左缘」）：悬浮行里可见
      // miniBar 旁还排着 2vp 隐藏页签 + HDS 内部间距（预算 16vp），默认布局
      // 把整行当组处理 → 可见胶囊左右离屏距相差「隐藏页签宽 + 间距」≈18vp
      // （方向取决于 HDS 把 miniBar 排在行首还是行尾，真机目视两边不等宽）。
      // 显设 barSideMargin 精确居中：可见左缘 = sideMargin、右缘 = 载体宽 −
      // sideMargin − barW，两者相等 ⇔ sideMargin = (载体宽 − barW) ÷ 2
      // （= 16 + (2 + 16) ÷ 2 = 25vp，与 HDS 内部把边距折在行哪一侧无关，
      // 两种模型同解）。宽屏 600 收窄后公式自动给出对称大边距，无需分支。
      barSideMargin: sideMargin,
      // 沉浸光感（与首页胶囊完全同源的真机已验证配方）
      // P0（2026-10-24 沉浸光感改造）：材质类型/档位抽入 MaterialTokens 令牌，
      // 与 Index.barFloatingStyle 同源（本步零观感变化，值不变）。
      systemMaterialEffect: {
        materialType: MaterialTokens.BAR_MATERIAL_TYPE,
        materialLevel: MaterialTokens.materialLevel()
      },
      lightColor: MaterialCompat.withAlpha(this.themePrimary, GLOW_ALPHA)
    };
    this.cachedStyle = style;
    this.cachedStyleKey = key;
    return style;
  }

  /**
   * miniBar 槽位内容（HDS 会缓存 builder 内容，PlayBar 自订阅 AppStorage，
   * 切歌 / 播放态实时刷新不受缓存影响 —— 首页 PlayBarHost 同款结论）。
   * 胶囊外形 / 材质 / 光晕全部由 HDS 施加，builder 内不画任何背景。
   */
  @Builder
  subPageBarHost() {
    PlayBar({ standalone: true })
  }

  /** 隐藏页签项内容：空占位（整条页签胶囊被 barOpacity:0 透明化） */
  @Builder
  hiddenTabItem() {
    Column()
  }

  build() {
    // HDS 全屏载体（barPosition End + barOverlap(true) 悬浮模式）：悬浮行
    // 位置由 barFloatingStyle 唯一决定；空 TabContent 只做占位，载体
    // Transparent 让栏外点击穿透到下方页面。
    HdsTabs({ controller: this.tabController }) {
      TabContent() {
        Column()
          .width('100%')
          .height('100%')
      }
      .tabBar(this.hiddenTabItem)
    }
    .vertical(false)
    .barPosition(BarPosition.End)
    .barMode(BarMode.Fixed)
    .barOverlap(true)
    .barFloatingStyle(this.floatingStyle())
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    // 载体宽持续实测：折叠开合 / 分屏 / 转屏后重排即回写，
    // miniBar 宽随之自动重算（键变化 → 受控重建生效）
    .onAreaChange((_old: Area, cur: Area): void => {
      const w: Length = cur.width;
      if (typeof w === 'number' && w > 0) {
        this.hostWidthVp = w;
      }
    })
    // 挂载 / 卸载淡入淡出（push/pop 转场期间栏以淡入浮现，不随页面横移）
    .transition(TransitionEffect.OPACITY.animation({ duration: SUB_PAGE_BAR_FADE_MS, curve: Curve.EaseInOut }))
  }
}
