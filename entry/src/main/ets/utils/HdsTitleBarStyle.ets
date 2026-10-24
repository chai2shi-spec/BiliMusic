/**
 * HDS 标题栏沉浸光感样式助手（HdsNavigation 迁移批 1 建立，批 2 各子页复用）。
 *
 * 职责：把「滚动联动渐进模糊 + 材质 + 兜底」收敛到一处，所有迁移到
 * HdsNavDestination.titleBar 的页面统一从这里取 TitleBarStyleOptions，
 * 保证全站顶栏与底部悬浮胶囊（Index.barFloatingStyle）材质观感一致。
 *
 * ⚠️ 本文件必须是 .ets：HDS 类型只能在 .ets 里 import（.ts 报 10311005）。
 */

import { TitleBarStyleOptions, ScrollEffectOptions, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { MaterialCompat } from './MaterialCompat';
import { MaterialTokens } from '../common/style/MaterialTokens';

/**
 * ===== 顶栏样式简史（2026-10-22 四次变更 + 2026-10-23 规格落地）=====
 * ① GRADIENT_BLUR 渐变毛玻璃：快滑时渐变遮罩 pass 被系统丢弃 → 毛玻璃
 *    「闪一下消失」；② 换 COMMON_BLUR 防闪烁 + 材质类型恢复 IMMERSIVE 找回
 *    光感；③ 滚动模糊背板整体取消（用户拍板「要光感、不要毛玻璃」）——
 *    enableScrollEffect: false，恒为静态样式；④ 材质档位调整：类型
 *    IMMERSIVE → ADAPTIVE（自适应系统材质，本机默认解析为沉浸式材质），
 *    档位 GENTLE → SMOOTH（平滑质感）。
 * ⑤（2026-10-22 用户指定重开）：按 UI Design Kit 规范重开顶部导航栏滚动
 *    联动渐进模糊 —— GRADIENT_BLUR 渐变模糊类型 + 起止偏移区间
 *    （blurStartVp → blurEndVp 线性过渡）+ ADAPTIVE/SMOOTH 材质。组件内部
 *    自动监听滚动偏移驱动毛玻璃 / 透明度平滑过渡，无需手动监听滚动事件；
 *    绑定链（各页 List scroller → 根/子页 bindToScrollable）③期间全程未拆，
 *    本次零重查直接生效。
 * ⑥（2026-10-23 规格落地）：区间全站统一归一 blurStart=0 →
 *    blurEnd=20（缩短插值区间减轻快滚断层感；原根栏 0→8 / 九个子页 30→80，
 *    各页常量已删、调用点全部改无参走本方法默认值）；材质档位 SMOOTH →
 *    GENTLE（最便宜具名档，防系统降级清空材质）；两档 scrollEffectStyle.
 *    backgroundStyle 显式补 maskExtraHeight: 32 + blurRadius: 20。
 *    回退依据（旧值全录）：SMOOTH / 根栏 0→8 / 子页 30→80。
 *    ⚠️ 闪烁观察点：①的快滑闪烁发生在旧管线（无 blurStrategy: ENABLE /
 *    thermoCtrl 显式压制）时代，⑤起两项压制齐备；若真机复现「毛玻璃闪一
 *    下消失」，退路是 scrollEffectType 换回 COMMON_BLUR（枚举仍可用）。
 * ⑦ **现状（2026-10-24 沉浸光感改造 P0+P1，规格第 5 节）**：P0 把散落
 *    4 文件的材质参数抽入 common/style/MaterialTokens 令牌（本类只引用，
 *    零观感变化）；P1 顶栏档位对齐底部胶囊 —— materialType ADAPTIVE →
 *    IMMERSIVE（MaterialTokens.TITLE_MATERIAL_TYPE）、materialLevel
 *    GENTLE → MaterialTokens.materialLevel()（与底部同一表达式：
 *    supportsImmersiveMaterial() ? EXQUISITE : ADAPTIVE，保证顶底玻璃
 *    厚薄同源）。回退依据（旧值全录）：materialType=ADAPTIVE +
 *    materialLevel=GENTLE（改 MaterialTokens 令牌值即可，不动结构）。
 *    P1-0 前置观察（2026-10-24 真机）：二级页滚动到顶返回键无黑圆 ——
 *    现透明背板已规避知乎++记录的「手动挡原始态黑圆」bug，P1 放心改。
 * ⑧ **现状（2026-10-24 修「松手抛行渐变模糊消失」）**：真机复现①的精确
 *    症状 —— 拖拽跟手（手势帧）时渐变模糊在场，松手抛行（fling 惯性帧）
 *    阶段 GRADIENT_BLUR 渐变遮罩 pass 被系统渲染管线丢弃；blurStrategy=
 *    ENABLE 已是枚举最强档、thermoCtrl=false 已钉，ScrollEffectOptions 无
 *    其它参数可 forcing 抛行期渲染 → GRADIENT_BLUR 管线内无参数级修法。
 *    修法：scrollEffectType 经 MaterialTokens.TITLE_SCROLL_EFFECT_TYPE 切
 *    IMMERSIVE_GRADIENT_BLUR 沉浸渐变（知乎++ API 26 真机验证主路径，其
 *    渲染坑位记录中无抛行丢 pass）。回退链（单令牌值翻转）：GRADIENT_BLUR
 *    （回到本 bug）→ COMMON_BLUR（均匀模糊稳态，无渐变、blurRadius /
 *    maskExtraHeight 均不生效，观感降级需用户拍板）。区间保持 0→20 不与
 *    类型切换混变量（知乎++ 用 0→10，留作后续观感微调项）。
 *    ⚠️ 黑圆观察项（知乎++ 记录，未了结）：IMMERSIVE_GRADIENT_BLUR + 手动
 *    挡（EXQUISITE）+ 滚动模糊未激活原始态 → 返回键区材质高光可能渲染成
 *    黑色圆（SystemMaterialParams 无颜色参数可控）。本工程 P1-0 观察是在
 *    GRADIENT_BLUR 管线下做的（无黑圆），切换后需真机复查二级页滚动到顶
 *    原始态；命中则回退并另行决策（勿叠加修法）。
 * ⑩ **现状（2026-10-24 自绘原型）**：用户否决 COMMON_BLUR 观感（无渐变软边，
 *    硬边不符「沉浸光感」）→ 新方案 = 页面内自绘渐变模糊层
 *    （TopGradientBlurOverlay：均匀模糊 + DST_IN 渐变打孔 + AttributeUpdater
 *    命令式驱动，见组件头）。根栏经本方法第三参 scrollEffectEnabled=false
 *    关 HDS 滚动效果（让位自绘层，防双重模糊）；仅 SearchPage 原型先行，
 *    其余三页签滚动模糊随之暂缺（原型期已知代价，验收后推广自绘层补齐）；
 *    九个子页仍走默认参（scrollEffect=on）不动。
 * ⑪ **（2026-10-24 验收⑥尝试后整体回退）**：曾按「控件背后透明背板」把
 *    根栏分支（effectOn=false）省略 systemMaterialEffect 材质板 + 自绘层
 *    行区透明（状态栏封盖 + 85% 起点尾带，见 TopGradientBlurOverlay
 *    gradientStops ⑥ 注）——真机实测状态栏封盖与栏下渐隐软边不可见，
 *    用户拍板整体回退到 ⑤（全栏模糊 + 材质板保留）。回退后本文件与 ⑤
 *    版逐字一致。若重试「透明背板」需先查明 ⑥ 三层（自绘层渐变 / 材质板
 *    移除 / HDS 默认背板）谁吞了封盖与尾带，勿盲改。
 *
 * 现状两档：
 * - 沉浸档（supportsImmersiveMaterial() 为真）：IMMERSIVE_GRADIENT_BLUR
 *   沉浸渐变叠加 IMMERSIVE + EXQUISITE/ADAPTIVE 材质光感（与底部胶囊
 *   同源）—— originalStyle / scrollEffectStyle 均透明，让系统渐变模糊与
 *   材质透出，可读性由模糊背板承担。
 * - 兜底档：沉浸渐变 + 弱→标准玻璃色随偏移线性插值
 *   （header_glass_tint_weak → header_glass_tint）。
 *
 * blurStrategy: ENABLE（FAQ faqs-arkui-1095：部分设备默认 ADAPTIVE 下动态
 * 模糊不渲染，ENABLE 强制开启）；thermoCtrl: false = 不主动申请发热降级
 * （置 true 是连续播放后顶栏材质消失的隐性来源之一）。
 *
 * ===== ScrollEffectType 速查（@hms.hds.hdsBaseComponent.d.ets）=====
 * - COMMON_BLUR = 0（5.1.0(18)+，SDK 默认）：均匀模糊，无渐变过渡。适用：
 *   不需要渐变观感的普通页；GRADIENT_BLUR 快滑闪烁时的退路（blurRadius /
 *   maskExtraHeight 对它不生效）。
 * - GRADUAL_BLUR = 1（6.0.0(20)+）：渐进模糊。
 * - GRADIENT_BLUR = 2（6.0.0(20)+）：渐变毛玻璃 —— 顶栏在 blurEffective
 *   区间（blurEffectiveStartOffset → blurEffectiveEndOffset，vp 滚动偏移）
 *   内从 originalStyle 线性过渡到 scrollEffectStyle；背板高度 = 标题栏高 +
 *   maskExtraHeight。⚠️ 简史⑧实证：fling 抛行阶段渐变遮罩 pass 被丢弃，
 *   已弃用（回退值）。
  * - IMMERSIVE_GRADIENT_BLUR = 3（6.1.0(23)+）：沉浸渐变 —— 面向沉浸图文页
  *   （封面/大图穿透标题栏、标题白→黑随滚动联动）。since 6.1.0(23) 与本
  *   工程 compatibleSdkVersion 持平，全设备可用。⚠️ 简史⑧实证：fling 抛行
  *   阶段渐变 pass 同样被丢弃，与 GRADIENT_BLUR 同症，已弃用。
  * - ⑨终版（2026-10-24 用户真机验收）：全站选用 COMMON_BLUR
  *   （MaterialTokens.TITLE_SCROLL_EFFECT_TYPE）—— 唯一在 fling 抛行中
  *   不丢模糊的滚动效果类型；GRADUAL_BLUR 未测。
 * 单位区别：blurEffectiveStartOffset / blurEffectiveEndOffset = LengthMetrics
 * （vp，滚动偏移量）；blurRadius = number（vp，0~128，模糊半径，仅
 * GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR 生效）；maskExtraHeight = number
 * （vp，渐变层高出标题栏的高度，仅渐变模糊类型生效）。
 *
 * ===== 页面接线骨架（各页现状即此模式，新页照抄）=====
 *   private listScroller: Scroller = new Scroller();
 *   build() {
 *     HdsNavDestination() {
 *       List({ scroller: this.listScroller }) { （内容穿透标题栏） }
 *     }
 *     .titleBar({ style: HdsTitleBarStyle.styleOptions() })
 *     .bindToScrollable([this.listScroller]) // HDS 内部监听滚动偏移
 *   }
 * 禁止事项：不写 onScroll 手动算进度；不叠加第二层 backdropBlur /
 * linearGradientBlur / backgroundBlurStyle —— 与 HDS 内置渐变模糊管线
 * 冲突，快滑时闪烁。
 */
export class HdsTitleBarStyle {
  /**
   * 材质档位枚举 → 日志名（P1 起档位随 MaterialTokens.materialLevel() 动态
   * 求值，日志必须打实际值而非字面量）。⚠️ 禁真值判断：EXQUISITE = 0，
   * `if (level)` 会把最贵档当 false（规格禁忌 2），一律显式比较。
   */
  private static levelName(level: hdsMaterial.MaterialLevel): string {
    if (level === hdsMaterial.MaterialLevel.EXQUISITE) {
      return 'EXQUISITE';
    }
    if (level === hdsMaterial.MaterialLevel.GENTLE) {
      return 'GENTLE';
    }
    if (level === hdsMaterial.MaterialLevel.SMOOTH) {
      return 'SMOOTH';
    }
    return 'ADAPTIVE';
  }

  /**
   * 材质类型枚举 → 日志名（与 levelName 同理：类型来自令牌，日志打实际值）。
   */
  private static typeName(t: hdsMaterial.MaterialType): string {
    if (t === hdsMaterial.MaterialType.IMMERSIVE) {
      return 'IMMERSIVE';
    }
    if (t === hdsMaterial.MaterialType.ADAPTIVE) {
      return 'ADAPTIVE';
    }
    return 'NONE';
  }

  /**
   * 滚动效果类型枚举 → 日志名（简史 ⑧：类型经令牌可切，日志必须打实际值
   * 而非字面量，否则回退后日志与实况不符）。
   */
  private static scrollEffectName(t: ScrollEffectType): string {
    if (t === ScrollEffectType.COMMON_BLUR) {
      return 'COMMON_BLUR';
    }
    if (t === ScrollEffectType.GRADUAL_BLUR) {
      return 'GRADUAL_BLUR';
    }
    if (t === ScrollEffectType.GRADIENT_BLUR) {
      return 'GRADIENT_BLUR';
    }
    return 'IMMERSIVE_GRADIENT_BLUR';
  }

  /**
   * 样式对象**内容键缓存**（2026-10-22，与 Index.barFloatingStyle 同一套路）。
   *
   * 背景：titleBar({ style }) 是 HDS 的**受控样式**，按对象引用判等。每次调用
   * 都 new 一个 TitleBarStyleOptions —— 本页任何一个 @StorageLink 变化
   * （切主题 / 折叠开合改宽度 / 安全区变 / 队列变空变满）都会重渲染 →
   * style 换新对象 → HDS 认为样式变了 → **销毁重建材质层** → 肉眼一帧空白。
   *
   * 语义输入：是否沉浸档 + 起糊/完糊区间（GRADIENT_BLUR 重开后各页传参
   * 重新成为键的一部分，见类头简史 ⑤）。键不变就返回同一个对象，HDS 不会
   * 重建；只有真的换样式才重建（原有的「重建即生效」不回退）。顺带副作用：
   * 档位日志只在真正换样式时打一次。
   *
   * ⚠️ 保留 Map 而非单槽位：沉浸 / 兜底两档是不同的键，转场期间根栏与各子页
   * 交替求值，且各子页 blurStartVp/blurEndVp 传参不同。键总数只有十几个，
   * 无需淘汰策略。
   */
  private static readonly styleCache: Map<string, TitleBarStyleOptions> = new Map<string, TitleBarStyleOptions>();

  /**
   * 生成 HdsNavDestination.titleBar({ style }) 的样式选项。
   *
   * 滚动联动渐进模糊（简史 ⑥⑦）：GRADIENT_BLUR 渐变模糊 + 起止偏移线性
   * 过渡，搭配 IMMERSIVE 材质（P1 起与底部胶囊同源，档位由
   * MaterialTokens.materialLevel() 统一求值）。全站调用点均已
   * 归一无参（走默认 0→20）；签名保留可选参备未来单页特殊化。
   * 每次真正换样式（缓存未命中）会打一条 [TopBar] 日志，真机验收时用
   * `hdc shell hilog | grep TopBar` 检索档位决策。
   *
   * @param blurStartVp 起糊偏移（vp）：滚动量低于此值时顶栏保持 originalStyle。
   * @param blurEndVp 完糊偏移（vp）：滚动量超过此值时动态样式过渡完成，停在
   *   scrollEffectStyle；设小于 blurStartVp 时 SDK 按默认值处理。
   * @param scrollEffectEnabled 是否开 HDS 滚动联动效果（默认 true）。仅根栏
   *   传 false（⑩ 自绘原型让位）；传 false 时 enableScrollEffect=false 且
   *   键 / 日志带 off 标记，与子页样式分缓存互不干扰。
   */
  static styleOptions(blurStartVp?: number, blurEndVp?: number, scrollEffectEnabled?: boolean): TitleBarStyleOptions {
    const immersive: boolean = MaterialCompat.supportsImmersiveMaterial();
    const effectOn: boolean = scrollEffectEnabled !== false;
    // 滚动联动渐进模糊（简史 ⑧）：滚动效果类型经 MaterialTokens 令牌
    //（IMMERSIVE_GRADIENT_BLUR 沉浸渐变，修「松手抛行阶段渐变模糊消失」），
    // 起止偏移默认 0 → 20（全站归一）；enableScrollEffect 显式写 true
    //（= 默认值），防 SDK 默认值变化时静默关掉滚动效果。
    const opts: ScrollEffectOptions = {
      enableScrollEffect: effectOn,
      scrollEffectType: MaterialTokens.TITLE_SCROLL_EFFECT_TYPE,
      blurEffectiveStartOffset: LengthMetrics.vp(blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP),
      blurEffectiveEndOffset: LengthMetrics.vp(blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP)
    };
    // 内容键（见 styleCache 注释）：是否沉浸档 + 起糊/完糊区间（归一化后）
    // + 是否开滚动效果（⑩：根栏关 / 子页开两档分缓存）。
    const key: string = `gb|${blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP}` +
      `|${blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP}|${immersive ? 1 : 0}|${effectOn ? 1 : 0}`;
    const hit: TitleBarStyleOptions | undefined = HdsTitleBarStyle.styleCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    if (immersive) {
      // P1（2026-10-24 沉浸光感改造）：档位与底部胶囊同一表达式求值
      //（MaterialTokens.materialLevel()），保证顶底玻璃厚薄同源。
      const level: hdsMaterial.MaterialLevel = MaterialTokens.materialLevel();
      console.info(`[TopBar] material=immersive ` +
        `materialType=${HdsTitleBarStyle.typeName(MaterialTokens.TITLE_MATERIAL_TYPE)} scrollEffect=${effectOn ? 'on' : 'off'} ` +
        `type=${HdsTitleBarStyle.scrollEffectName(MaterialTokens.TITLE_SCROLL_EFFECT_TYPE)}` +
        ` blurStart=${blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP}` +
        ` blurEnd=${blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP} ` +
        `level=${HdsTitleBarStyle.levelName(level)} ` +
        `mask=${MaterialTokens.TITLE_MASK_EXTRA_VP} blur=${MaterialTokens.TITLE_BLUR_RADIUS_VP} thermoCtrl=false`);
      // 沉浸档：IMMERSIVE_GRADIENT_BLUR 沉浸渐变 + IMMERSIVE 材质光感（P1 对齐底部）。
      // - originalStyle（滚动起点）/ scrollEffectStyle（滚动终点）均透明：
      //   让系统渐变模糊背板与材质透出，可读性由模糊承担。
      const builtImmersive: TitleBarStyleOptions = {
        scrollEffectOpts: opts,
        blurStrategy: BlurStrategy.ENABLE,
        // thermoCtrl 显式写 false（= 默认值）：语义是「样式是否受系统温控接管」。
        // 置 true 等于主动申请「发热时降级」，是连续播放后顶栏材质消失的
        // 隐性来源之一。写出来是为了防止后人再「顺手打开」。
        thermoCtrl: false,
        systemMaterialEffect: {
          // P1（2026-10-24）：materialType ADAPTIVE → IMMERSIVE（强制沉浸
          // 材质，与底部同源，不被系统策略解析成非沉浸）；materialLevel
          // GENTLE → MaterialTokens.materialLevel()（supportsImmersiveMaterial
          // ? EXQUISITE : ADAPTIVE，与底部同一表达式）。回退值：ADAPTIVE +
          // GENTLE（简史 ⑦）。⚠️ 这里的 MaterialLevel.ADAPTIVE 是**显式
          // 探测后的兜底档**（设备不支持 EXQUISITE 时交给系统自适应），
          // 与「没探测就随手写 ADAPTIVE」不同（规格禁忌 1 说的是后者）。
          materialType: MaterialTokens.TITLE_MATERIAL_TYPE,
          materialLevel: level
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.ohos_id_color_background_transparent')
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
            // maskExtraHeight（vp）：渐变模糊层高出标题栏的高度，仅渐变
            // 模糊类型生效（与 SDK 默认 32 同值，显式写防默认漂移）。
            maskExtraHeight: MaterialTokens.TITLE_MASK_EXTRA_VP,
            // blurRadius（vp，0~128）：完糊态模糊半径，仅 GRADIENT_BLUR /
            // IMMERSIVE_GRADIENT_BLUR 生效（简史 ⑥ 规格落地）。
            blurRadius: MaterialTokens.TITLE_BLUR_RADIUS_VP
          }
        }
      };
      HdsTitleBarStyle.styleCache.set(key, builtImmersive);
      return builtImmersive;
    }
    // 兜底档：沉浸渐变 + 弱→标准玻璃色随偏移线性插值。
    console.info(`[TopBar] material=fallback scrollEffect=${effectOn ? 'on' : 'off'} ` +
      `type=${HdsTitleBarStyle.scrollEffectName(MaterialTokens.TITLE_SCROLL_EFFECT_TYPE)} ` +
      `blurStart=${blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP}` +
      ` blurEnd=${blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP} ` +
      `mask=${MaterialTokens.TITLE_MASK_EXTRA_VP} blur=${MaterialTokens.TITLE_BLUR_RADIUS_VP} thermoCtrl=false`);
    const builtFallback: TitleBarStyleOptions = {
      scrollEffectOpts: opts,
      blurStrategy: BlurStrategy.ENABLE,
      thermoCtrl: false,
      originalStyle: {
        backgroundStyle: {
          backgroundColor: $r('app.color.header_glass_tint_weak')
        }
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: $r('app.color.header_glass_tint'),
          // 与沉浸档同款（简史 ⑥）：渐变层高度 / 完糊态模糊半径显式钉住。
          maskExtraHeight: MaterialTokens.TITLE_MASK_EXTRA_VP,
          blurRadius: MaterialTokens.TITLE_BLUR_RADIUS_VP
        }
      }
    };
    HdsTitleBarStyle.styleCache.set(key, builtFallback);
    return builtFallback;
  }
}
