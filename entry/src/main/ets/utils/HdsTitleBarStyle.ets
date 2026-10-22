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

/**
 * ===== 顶栏样式简史（2026-10-22，同日四次变更后定版）=====
 * ① GRADIENT_BLUR 渐变毛玻璃：快滑时渐变遮罩 pass 被系统丢弃 → 毛玻璃
 *    「闪一下消失」；② 换 COMMON_BLUR 防闪烁 + 材质类型恢复 IMMERSIVE 找回
 *    光感；③ 滚动模糊背板整体取消（用户拍板「要光感、不要毛玻璃」）——
 *    enableScrollEffect: false，恒为静态样式；④ 材质档位调整：类型
 *    IMMERSIVE → ADAPTIVE（自适应系统材质，本机默认解析为沉浸式材质），
 *    档位 GENTLE → SMOOTH（平滑质感）。
 * ⑤ **现状（2026-10-22 用户指定重开）**：按 UI Design Kit 规范重开顶部
 *    导航栏滚动联动渐进模糊 —— GRADIENT_BLUR 渐变模糊类型 + 起止偏移区间
 *    （blurStartVp → blurEndVp 线性过渡）+ ADAPTIVE/SMOOTH 材质。组件内部
 *    自动监听滚动偏移驱动毛玻璃 / 透明度平滑过渡，无需手动监听滚动事件；
 *    绑定链（各页 List scroller → 根/子页 bindToScrollable）③期间全程未拆，
 *    本次零重查直接生效。
 *    ⚠️ 闪烁观察点：①的快滑闪烁发生在旧管线（无 blurStrategy: ENABLE /
 *    thermoCtrl 显式压制）时代，本次两项压制齐备；若真机复现「毛玻璃闪一
 *    下消失」，退路是 scrollEffectType 换回 COMMON_BLUR（枚举仍可用）。
 *
 * 现状两档：
 * - 沉浸档（supportsImmersiveMaterial() 为真）：GRADIENT_BLUR 渐变模糊
 *   叠加 ADAPTIVE/SMOOTH 材质光感 —— originalStyle / scrollEffectStyle 均
 *   透明，让系统渐变模糊与材质透出，可读性由模糊背板承担。
 * - 兜底档：GRADIENT_BLUR 渐变模糊 + 弱→标准玻璃色随偏移线性插值
 *   （header_glass_tint_weak → header_glass_tint）。
 *
 * blurStrategy: ENABLE（FAQ faqs-arkui-1095：部分设备默认 ADAPTIVE 下动态
 * 模糊不渲染，ENABLE 强制开启）；thermoCtrl: false = 不主动申请发热降级
 * （置 true 是连续播放后顶栏材质消失的隐性来源之一）。
 */
export class HdsTitleBarStyle {
  /**
   * 材质档位：SMOOTH（平滑，2026-10-22 用户指定）。
   * 档位光谱：EXQUISITE（精，最贵）> SMOOTH（平滑）> GENTLE（轻，最便宜）。
   * SMOOTH 质感比 GENTLE 更接近系统原生「液态玻璃」，成本介于两者之间；
   * 滚动模糊重开后快滑动态负载回归，若中低端机出现材质被系统降档
   * （「闪一下没了」），回退 GENTLE 即可。
   */
  private static readonly USE_MATERIAL_LEVEL: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;

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
   * 滚动联动渐进模糊（2026-10-22 重开，见类头简史 ⑤）：GRADIENT_BLUR +
   * 起止偏移线性过渡，搭配 ADAPTIVE/SMOOTH 材质。
   * 每次真正换样式（缓存未命中）会打一条 [TopBar] 日志，真机验收时用
   * `hdc shell hilog | grep TopBar` 检索档位决策。
   *
   * @param blurStartVp 起糊偏移（vp）：滚动量低于此值时顶栏保持 originalStyle。
   * @param blurEndVp 完糊偏移（vp）：滚动量超过此值时动态样式过渡完成，停在
   *   scrollEffectStyle；设小于 blurStartVp 时 SDK 按默认值处理。
   */
  static styleOptions(blurStartVp?: number, blurEndVp?: number): TitleBarStyleOptions {
    const immersive: boolean = MaterialCompat.supportsImmersiveMaterial();
    // 滚动联动渐进模糊（2026-10-22 用户指定重开）：GRADIENT_BLUR 渐变模糊类型，
    // 起止偏移用各页传入区间；enableScrollEffect 显式写 true（= 默认值），
    // 防 SDK 默认值变化时静默关掉滚动效果。
    const opts: ScrollEffectOptions = {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
      blurEffectiveStartOffset: LengthMetrics.vp(blurStartVp ?? 0),
      blurEffectiveEndOffset: LengthMetrics.vp(blurEndVp ?? 8)
    };
    // 内容键（见 styleCache 注释）：是否沉浸档 + 起糊/完糊区间（归一化后）。
    const key: string = `gb|${blurStartVp ?? 0}|${blurEndVp ?? 8}|${immersive ? 1 : 0}`;
    const hit: TitleBarStyleOptions | undefined = HdsTitleBarStyle.styleCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    if (immersive) {
      console.info(`[TopBar] material=immersive materialType=ADAPTIVE scrollEffect=on ` +
        `type=GRADIENT_BLUR blurStart=${blurStartVp ?? 0} blurEnd=${blurEndVp ?? 8} ` +
        `level=${HdsTitleBarStyle.USE_MATERIAL_LEVEL === hdsMaterial.MaterialLevel.SMOOTH ? 'SMOOTH' : 'other'} ` +
        `thermoCtrl=false`);
      // 沉浸档：GRADIENT_BLUR 渐变模糊 + ADAPTIVE/SMOOTH 材质光感。
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
          // 类型 ADAPTIVE —— 自适应系统材质，本机默认解析为沉浸式材质
          // （跟随系统策略，策略变化自动适配）；档位 SMOOTH（平滑质感，
          // 见 USE_MATERIAL_LEVEL 注释）。
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: HdsTitleBarStyle.USE_MATERIAL_LEVEL
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.ohos_id_color_background_transparent')
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.ohos_id_color_background_transparent')
          }
        }
      };
      HdsTitleBarStyle.styleCache.set(key, builtImmersive);
      return builtImmersive;
    }
    // 兜底档：GRADIENT_BLUR 渐变模糊 + 弱→标准玻璃色随偏移线性插值。
    console.info(`[TopBar] material=fallback scrollEffect=on type=GRADIENT_BLUR ` +
      `blurStart=${blurStartVp ?? 0} blurEnd=${blurEndVp ?? 8} thermoCtrl=false`);
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
          backgroundColor: $r('app.color.header_glass_tint')
        }
      }
    };
    HdsTitleBarStyle.styleCache.set(key, builtFallback);
    return builtFallback;
  }
}
