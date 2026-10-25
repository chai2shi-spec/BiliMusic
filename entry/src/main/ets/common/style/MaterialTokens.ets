/**
 * 沉浸光感材质令牌。
 *
 * 本文件把散落各处的材质参数收成唯一出处，各处只引用不写值，
 * 避免顶底材质参数漂移；回退只回退值、不回退结构。
 *
 * 主题色光晕 alpha（GLOW_ALPHA=0.12）已集中定义在 common/Constants.ts，
 * 不在此重复声明（避免双源漂移）。
 *
 * ⚠️ 本文件必须是 .ets：hdsMaterial 类型只能在 .ets 里 import（.ts 报 10311005）。
 * ⚠️ 禁忌：MaterialLevel.ADAPTIVE（=10）语义是「跟随系统策略」，
 *    会被策略降级清空材质，不当默认值随手用；MaterialLevel.EXQUISITE（=0）
 *    是最贵档，禁止真值判断枚举。
 */
import { hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { MaterialCompat } from '../../utils/MaterialCompat';

export class MaterialTokens {
  /**
   * 顶栏（HdsTitleBarStyle.styleOptions）材质类型：强制沉浸材质，
   * 不被系统策略解析成非沉浸。回退值 = ADAPTIVE。
   */
  static readonly TITLE_MATERIAL_TYPE: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
  /** 底部胶囊（Index.barFloatingStyle / SubPagePlayBar）材质类型，两处同源 */
  static readonly BAR_MATERIAL_TYPE: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
  /** 顶栏滚动模糊起糊偏移（vp）：滚动量低于此值保持 originalStyle */
  static readonly TITLE_BLUR_START_VP: number = 0;
  /** 顶栏滚动模糊完糊偏移（vp）：滚动量超过此值过渡完成停在 scrollEffectStyle */
  static readonly TITLE_BLUR_END_VP: number = 20;
  /** 渐变模糊层高出标题栏的高度（vp），仅渐变模糊类型生效 */
  static readonly TITLE_MASK_EXTRA_VP: number = 32;
  /** 完糊态模糊半径（vp，0~128），仅 GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR 生效 */
  static readonly TITLE_BLUR_RADIUS_VP: number = 20;
  /** 兜底通路 backgroundEffect 半径（HeaderBarMaterialModifier 真高斯模糊） */
  static readonly FROST_RADIUS: number = 40;
  /**
   * 顶栏滚动效果类型：
   * ⚠️ GRADIENT_BLUR 与 IMMERSIVE_GRADIENT_BLUR **均**在 fling 惯性滚动阶段
   * 被渲染管线丢弃渐变 pass —— 与帧负载无关，是 ScrollState.Fling 状态本身
   * 触发，本设备无解（全透明与垫底色两种消费结构均真机实证失败）。
   * COMMON_BLUR 抛行中不消失：均匀模糊通路不受渐变 pass 丢弃影响，
   * 无渐变边缘、blurRadius / maskExtraHeight 对它不生效，模糊背景
   * 随滚动透明渐变出现/消失（仍与滚动联动）；since 5.1.0(18) 全设备可用。
   * ⚠️ 不要再切回渐变类滚动效果（fling 期必丢，本注释即回退依据）；
   * 自绘 TopGradientBlurOverlay（backgroundEffect 通路）是唯一可用的
   * 渐进模糊方案，现状即终版。
   */
  static readonly TITLE_SCROLL_EFFECT_TYPE: ScrollEffectType = ScrollEffectType.COMMON_BLUR;

  /**
   * 统一材质档位：与底部胶囊同一表达式求值
   * （MaterialCompat.supportsImmersiveMaterial() 即 Index/SubPagePlayBar 的
   * useExquisiteMaterial 判定），保证顶底玻璃厚薄同源。
   * 探测开销：一次 getSystemMaterialTypes 调用，各调用方自有内容键缓存挡频。
   */
  static materialLevel(): hdsMaterial.MaterialLevel {
    return MaterialCompat.supportsImmersiveMaterial()
      ? hdsMaterial.MaterialLevel.EXQUISITE
      : hdsMaterial.MaterialLevel.ADAPTIVE;
  }
}
