/**
 * 沉浸光感材质令牌（2026-10-24 沉浸光感改造 P0 抽取，规格：
 * design/沉浸光感改造方案-AI实施规格.md 第 5 节 P0）。
 *
 * 背景：改一个材质观感参数曾经要同步 4 个文件（HdsTitleBarStyle /
 * Index.barFloatingStyle / SubPagePlayBar / HeaderBarMaterial），且顶底已出现
 * 漂移（materialType 顶 ADAPTIVE vs 底 IMMERSIVE）。本文件把散落参数收成唯一
 * 出处，各处只引用不写值；回退只回退值、不回退结构（规格第 8 节回退原则）。
 *
 * 主题色光晕 alpha（GLOW_ALPHA=0.12）已集中定义在 common/Constants.ts，
 * 不在此重复声明（避免双源漂移）。
 *
 * ⚠️ 本文件必须是 .ets：hdsMaterial 类型只能在 .ets 里 import（.ts 报 10311005）。
 * ⚠️ 禁忌（规格第 6 节）：MaterialLevel.ADAPTIVE（=10）语义是「跟随系统策略」，
 *    会被策略降级清空材质，不当默认值随手用；MaterialLevel.EXQUISITE（=0）
 *    是最贵档，禁止真值判断枚举。
 */
import { hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { MaterialCompat } from '../../utils/MaterialCompat';

export class MaterialTokens {
  /**
   * 顶栏（HdsTitleBarStyle.styleOptions）材质类型。
   * P1（2026-10-24）对齐底部：ADAPTIVE → IMMERSIVE（强制沉浸材质，不被系统
   * 策略解析成非沉浸）。回退值 = ADAPTIVE（录于 HdsTitleBarStyle 类头简史 ⑦）。
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
   * 顶栏滚动效果类型（2026-10-24 修「松手抛行阶段渐变模糊消失」，简史 ⑧→⑨ 终版）：
   * ⑧ GRADIENT_BLUR 与 IMMERSIVE_GRADIENT_BLUR **均**在 fling 惯性滚动阶段
   * 被渲染管线丢弃渐变 pass（真机两轮实证；F2 暂停圆盘排除帧负载后仍丢 →
   * 是 ScrollState.Fling 状态本身触发，非负载）。
   * ⑨ 终版（用户真机验收通过）：**COMMON_BLUR 抛行中不消失** —— 渐变类
   * 滚动效果专属的 pass 丢弃问题，均匀模糊通路不受影响。保留 COMMON_BLUR：
   * 均匀模糊无渐变边缘、blurRadius / maskExtraHeight 对它不生效，模糊背景
   * 随滚动透明渐变出现/消失（仍与滚动联动）；since 5.1.0(18) 全设备可用。
   * ⚠️ 不要再切回 GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR —— 两者 fling 期
   * 必丢（本注释即回退依据）；GRADUAL_BLUR 已测（⑪ 2026-10-24 单页实验：
   * FollowsPage 开滚动联动 + 隐藏自绘层，真机验收用户判定退回，恢复
   * COMMON_BLUR）—— 四种类型至此全部实证，勿再试；现状即终版。
   */
  static readonly TITLE_SCROLL_EFFECT_TYPE: ScrollEffectType = ScrollEffectType.COMMON_BLUR;

  /**
   * 统一材质档位（规格 P1）：与底部胶囊同一表达式求值
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
