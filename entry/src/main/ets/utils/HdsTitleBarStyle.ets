/**
 * HDS 标题栏沉浸光感样式助手。
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
 * 生成 HdsNavDestination.titleBar({ style }) 的样式选项（材质 + 兜底样式）。
 *
 * 现状：渐进模糊由各页自绘 TopGradientBlurOverlay（backgroundEffect 通路）
 * 承担，多数页面传 scrollEffectEnabled=false 关闭 HDS 内置滚动效果让位自绘层
 * （防双重模糊）。原因：GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR 均在 fling
 * 惯性滚动阶段被渲染管线丢弃渐变 pass（真机实证，与帧负载无关），自绘层是
 * 唯一可用的渐进模糊方案（见 MaterialTokens.TITLE_SCROLL_EFFECT_TYPE 注释）。
 *
 * 现状两档：
 * - 沉浸档（supportsImmersiveMaterial() 为真）：滚动模糊叠加
 *   IMMERSIVE + EXQUISITE/ADAPTIVE 材质光感（与底部胶囊
 *   同源）—— originalStyle / scrollEffectStyle 均透明，让模糊与
 *   材质透出，可读性由模糊背板承担。
 * - 兜底档：滚动模糊 + 弱→标准玻璃色随偏移线性插值
 *   （header_glass_tint_weak → header_glass_tint）。
 *
 * blurStrategy: ENABLE（FAQ faqs-arkui-1095：部分设备默认 ADAPTIVE 下动态
 * 模糊不渲染，ENABLE 强制开启）；thermoCtrl: false = 不主动申请发热降级
 * （置 true 是连续播放后顶栏材质消失的隐性来源之一）。
 *
 * ===== ScrollEffectType 速查（@hms.hds.hdsBaseComponent.d.ets）=====
 * - COMMON_BLUR = 0（5.1.0(18)+，SDK 默认）：均匀模糊，无渐变过渡。
 *   适用：不需要渐变观感的普通页（blurRadius / maskExtraHeight 对它不生效）。
 *   全站现用（MaterialTokens.TITLE_SCROLL_EFFECT_TYPE）；GRADUAL_BLUR 未测。
 * - GRADUAL_BLUR = 1（6.0.0(20)+）：渐进模糊。
 * - GRADIENT_BLUR = 2（6.0.0(20)+）：渐变毛玻璃 —— ⚠️ fling 抛行阶段渐变
 *   遮罩 pass 被渲染管线丢弃，已弃用（回退值）。
 * - IMMERSIVE_GRADIENT_BLUR = 3（6.1.0(23)+）：沉浸渐变 —— ⚠️ fling 抛行
 *   阶段渐变 pass 同样被丢弃，已弃用。
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
 * linearGradientBlur / backgroundBlurStyle —— 与自绘层 / HDS 内置模糊管线
 * 冲突，快滑时闪烁。
 */
export class HdsTitleBarStyle {
  /**
   * 材质档位枚举 → 日志名（档位随 MaterialTokens.materialLevel() 动态
   * 求值，日志必须打实际值而非字面量）。⚠️ 禁真值判断：EXQUISITE = 0，
   * `if (level)` 会把最贵档当 false，一律显式比较。
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
   * 滚动效果类型枚举 → 日志名（类型经令牌可切，日志必须打实际值
   * 而非字面量，否则与实况不符）。
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
   * 样式对象**内容键缓存**（与 Index.barFloatingStyle 同一套路）。
   *
   * titleBar({ style }) 是 HDS 的**受控样式**，按对象引用判等。每次调用
   * 都 new 一个 TitleBarStyleOptions —— 本页任何一个 @StorageLink 变化
   * （切主题 / 折叠开合改宽度 / 安全区变 / 队列变空变满）都会重渲染 →
   * style 换新对象 → HDS 认为样式变了 → **销毁重建材质层** → 肉眼一帧空白。
   *
   * 语义输入：是否沉浸档 + 起糊/完糊区间 + 是否开滚动效果。键不变就返回
   * 同一个对象，HDS 不会重建；只有真的换样式才重建。顺带副作用：
   * 档位日志只在真正换样式时打一次。
   *
   * ⚠️ 保留 Map 而非单槽位：沉浸 / 兜底两档是不同的键，转场期间根栏与各子页
   * 交替求值，且各子页传参不同。键总数只有十几个，无需淘汰策略。
   */
  private static readonly styleCache: Map<string, TitleBarStyleOptions> = new Map<string, TitleBarStyleOptions>();

  /**
   * 生成 HdsNavDestination.titleBar({ style }) 的样式选项。
   *
   * 材质与档位经 MaterialTokens 令牌取值（与底部胶囊同源，档位由
   * MaterialTokens.materialLevel() 统一求值）；滚动效果起止偏移全站
   * 归一默认 0→20，签名保留可选参备单页特殊化。
   * 每次真正换样式（缓存未命中）会打一条 [TopBar] 日志，真机验收时用
   * `hdc shell hilog | grep TopBar` 检索档位决策。
   *
   * @param blurStartVp 起糊偏移（vp）：滚动量低于此值时顶栏保持 originalStyle。
   * @param blurEndVp 完糊偏移（vp）：滚动量超过此值时动态样式过渡完成，停在
   *   scrollEffectStyle；设小于 blurStartVp 时 SDK 按默认值处理。
   * @param scrollEffectEnabled 是否开 HDS 滚动联动效果（默认 true）。传 false
   *   时让位自绘渐变模糊层（防双重模糊）；enableScrollEffect=false 且
   *   键 / 日志带 off 标记，与滚动效果开启的样式分缓存互不干扰。
   */
  static styleOptions(blurStartVp?: number, blurEndVp?: number, scrollEffectEnabled?: boolean): TitleBarStyleOptions {
    const immersive: boolean = MaterialCompat.supportsImmersiveMaterial();
    const effectOn: boolean = scrollEffectEnabled !== false;
    // 滚动联动模糊：滚动效果类型经 MaterialTokens 令牌（COMMON_BLUR，
    // 见令牌注释即回退依据），起止偏移默认 0 → 20（全站归一）；
    // enableScrollEffect 显式写 true（= 默认值），防 SDK 默认值变化时
    // 静默关掉滚动效果。
    const opts: ScrollEffectOptions = {
      enableScrollEffect: effectOn,
      scrollEffectType: MaterialTokens.TITLE_SCROLL_EFFECT_TYPE,
      blurEffectiveStartOffset: LengthMetrics.vp(blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP),
      blurEffectiveEndOffset: LengthMetrics.vp(blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP)
    };
    // 内容键（见 styleCache 注释）：是否沉浸档 + 起糊/完糊区间（归一化后）
    // + 是否开滚动效果（关 / 开两档分缓存）。
    const key: string = `gb|${blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP}` +
      `|${blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP}|${immersive ? 1 : 0}|${effectOn ? 1 : 0}`;
    const hit: TitleBarStyleOptions | undefined = HdsTitleBarStyle.styleCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    if (immersive) {
      // 档位与底部胶囊同一表达式求值（MaterialTokens.materialLevel()），
      // 保证顶底玻璃厚薄同源。
      const level: hdsMaterial.MaterialLevel = MaterialTokens.materialLevel();
      console.info(`[TopBar] material=immersive ` +
        `materialType=${HdsTitleBarStyle.typeName(MaterialTokens.TITLE_MATERIAL_TYPE)} scrollEffect=${effectOn ? 'on' : 'off'} ` +
        `type=${HdsTitleBarStyle.scrollEffectName(MaterialTokens.TITLE_SCROLL_EFFECT_TYPE)}` +
        ` blurStart=${blurStartVp ?? MaterialTokens.TITLE_BLUR_START_VP}` +
        ` blurEnd=${blurEndVp ?? MaterialTokens.TITLE_BLUR_END_VP} ` +
        `level=${HdsTitleBarStyle.levelName(level)} ` +
        `mask=${MaterialTokens.TITLE_MASK_EXTRA_VP} blur=${MaterialTokens.TITLE_BLUR_RADIUS_VP} thermoCtrl=false`);
      // 沉浸档：滚动模糊 + IMMERSIVE 材质光感（与底部对齐）。
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
          // materialType 用 IMMERSIVE（强制沉浸材质，与底部同源，不被
          // 系统策略解析成非沉浸）；materialLevel 用
          // MaterialTokens.materialLevel()（supportsImmersiveMaterial
          // ? EXQUISITE : ADAPTIVE，与底部同一表达式）。⚠️ 这里的
          // MaterialLevel.ADAPTIVE 是**显式探测后的兜底档**（设备不支持
          // EXQUISITE 时交给系统自适应），与「没探测就随手写 ADAPTIVE」不同。
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
            // IMMERSIVE_GRADIENT_BLUR 生效。
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
          // 与沉浸档同款：渐变层高度 / 完糊态模糊半径显式钉住。
          maskExtraHeight: MaterialTokens.TITLE_MASK_EXTRA_VP,
          blurRadius: MaterialTokens.TITLE_BLUR_RADIUS_VP
        }
      }
    };
    HdsTitleBarStyle.styleCache.set(key, builtFallback);
    return builtFallback;
  }
}
