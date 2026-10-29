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
 *    会被策略降级清空材质 —— 仅允许出现在设备不支持沉浸材质的
 *    显式探测后兜底一处，不当默认值随手用；
 *    MaterialLevel.EXQUISITE（=0）是最贵档，禁止真值判断枚举。
 */
import { hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { MaterialCompat } from '../../utils/MaterialCompat';
import { STORE_IMMERSIVE_MATERIAL_TIER } from '../Constants';
import {
  IMMERSIVE_TIER_EXQUISITE,
  IMMERSIVE_TIER_GENTLE,
  IMMERSIVE_TIER_SMOOTH,
  IMMERSIVE_TIER_OPTIONS
} from '../../model/MusicModels';

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
   * 当前沉浸光感材质档位（AppStorage 镜像读取 + 白名单兜底）：
   * EntryAbility 启动首发、外观页切换时重发；未就位 / 异常值一律
   * 回落默认精美档（EntryAbility 首帧 build 前必已就位，兜底只防极端时序）。
   */
  static materialTier(): string {
    const tier: string | undefined = AppStorage.get<string>(STORE_IMMERSIVE_MATERIAL_TIER);
    if (tier !== undefined && IMMERSIVE_TIER_OPTIONS.includes(tier)) {
      return tier;
    }
    return IMMERSIVE_TIER_EXQUISITE;
  }

  /**
   * 统一材质档位（档位感知，与底部胶囊 / 二级页播放栏 / 标题栏三处同源），
   * 三档与 hdsMaterial.MaterialLevel 一一对应：
   * - exquisite：EXQUISITE 精美（最高规格，外观页已按设备能力门控拦截）；
   * - gentle：GENTLE 轻柔（中档固定玻璃）；
   * - smooth：SMOOTH 流畅（低算力档）。
   * 设备不支持沉浸材质（MaterialCompat.supportsImmersiveMaterial() 判定）
   * 时统一兜底 ADAPTIVE —— 显式探测后的兜底档，与「没探测就随手写」不同。
   * 探测开销：一次 getSystemMaterialTypes 调用，各调用方自有内容键缓存挡频。
   */
  static materialLevel(): hdsMaterial.MaterialLevel {
    const tier: string = MaterialTokens.materialTier();
    if (!MaterialCompat.supportsImmersiveMaterial()) {
      return hdsMaterial.MaterialLevel.ADAPTIVE;
    }
    switch (tier) {
      case IMMERSIVE_TIER_GENTLE:
        return hdsMaterial.MaterialLevel.GENTLE;
      case IMMERSIVE_TIER_SMOOTH:
        return hdsMaterial.MaterialLevel.SMOOTH;
      default:
        // 白名单兜底后 tier 必为三档之一，default 仅防御（含 exquisite）
        return hdsMaterial.MaterialLevel.EXQUISITE;
    }
  }

  /**
   * 悬浮胶囊系（Index.barFloatingStyle / SubPagePlayBar）材质类型：
   * BAR_MATERIAL_TYPE（IMMERSIVE 强制沉浸材质）。
   * 历史曾有 off 档（→ MaterialType.NONE）通路，off 档已取消，
   * 结构保留（仍显式传值，不省略字段，防 SDK 默认值漂移）。
   */
  static barMaterialType(): hdsMaterial.MaterialType {
    return MaterialTokens.BAR_MATERIAL_TYPE;
  }
}
