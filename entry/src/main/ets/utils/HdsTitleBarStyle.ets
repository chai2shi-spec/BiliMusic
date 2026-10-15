/**
 * HDS 标题栏沉浸光感样式助手（HdsNavigation 迁移批 1 建立，批 2 各子页复用）。
 *
 * 职责：把「材质 + 滚动模糊 + 兜底」收敛到一处，所有迁移到
 * HdsNavDestination.titleBar 的页面统一从这里取 TitleBarStyleOptions，
 * 保证全站顶栏与底部悬浮胶囊（Index.barFloatingStyle）材质观感一致。
 *
 * 2026-10-12 起沉浸路径按「渐进模糊」四步指南补显式样式端点（范围 = 根顶栏 +
 * 全部子页）：originalStyle 与 scrollEffectStyle **均为透明背景**（二次修正，
 * 首版终点 bg_page 实色会把渐变模糊整个盖住，详见 styleOptions 内注释）；
 * blurStrategy: ENABLE 与 ADAPTIVE/ADAPTIVE 材质保留。Index.titleBarStyle
 * 沉浸档补端点后与本助手完全等价，已收敛为对 styleOptions 的单行委托
 * （此前两份配置人工对齐易漂移）。
 *
 * （历史：2026-10-11 沉浸路径曾与 Index 沉浸档逐字对齐为「不设样式端点、
 * 用 HDS 默认样式」—— 该形态被 2026-10-12 的显式端点方案取代。）
 *
 * 对齐记录（Index 侧三轮排查定版，详见 Index.titleBarStyle 注释）：
 *   旧沉浸路径（IMMERSIVE_GRADIENT_BLUR + IMMERSIVE/EXQUISITE 材质 + 透明→
 *   blurRadius:40 端点插值 + thermoCtrl）真机表现为磨砂显形过晚。Index 沉浸档
 *   定版为 GRADIENT_BLUR + blurStrategy: ENABLE（FAQ faqs-arkui-1095 末问答：
 *   blurStrategy 默认 ADAPTIVE 在部分设备不渲染动态模糊，ENABLE 强制开启）
 *   + ADAPTIVE/ADAPTIVE 材质（官方 Spatialization MainPage 同款）。本助手
 *   沉浸路径同步该定版；兜底路径同样补 blurStrategy: ENABLE（部分设备
 *   ADAPTIVE 下 blurRadius 也不渲染）。
 *   （历史：2026-10-09 曾以「样式端点」修「滚动无变化」；端点现已回到两档
 *   共用 —— 沉浸档 2026-10-12 补、兜底档一直有。）
 *
 * 不加品牌粉光晕（任务书问题 2 结论：2026-10-06 真机观感显脏已整层删除；
 * HdsNavigationBackgroundStyle 本就无 lightColor 字段）。
 *
 * ⚠️ 本文件必须是 .ets：HDS 类型只能在 .ets 里 import（.ts 报 10311005）。
 */

import { TitleBarStyleOptions, ScrollEffectOptions, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { MaterialCompat } from './MaterialCompat';

export class HdsTitleBarStyle {
  /**
   * 生成 HdsNavDestination.titleBar({ style }) 的样式选项。
   *
   * 每次调用都会打一条 [TopBar] 日志（immersive / fallback + 模糊区间），
   * 真机验收时用 `hdc shell hilog | grep TopBar` 检索档位决策。
   *
   * @param blurStartVp 滚动模糊起始偏移（基准口径 = 关于页：「首条内容自静止位上移量」的下限）。
   *   不传 = HDS 默认（0）。
   * @param blurEndVp 滚动模糊完成偏移（上限，不传 = HDS 默认：GRADIENT_BLUR 8）。
   * @param maskExtraVp 模糊蒙层超出标题栏的额外高度（vp）。⚠️ 仅兜底路径使用
   *   （沉浸路径与 Index 沉浸档对齐、不设样式端点，无 mask 字段）。有
   *   bottomBuilder 第二行的页面传第二行高度，让滚动模糊蒙层罩住整栏
   *   （官方 bottomBuilder 示例同款：其值 = bottomBuilder 高度；默认 32
   *   罩不住较高的第二行）。不传 / ≤0 = HDS 默认 32。
   *
 * （历史记录：曾有过第三/四参 coffsetComp 让位量负补偿，已真机证伪删除。）
   */
  static styleOptions(blurStartVp?: number, blurEndVp?: number, maskExtraVp?: number): TitleBarStyleOptions {
    const immersive: boolean = MaterialCompat.supportsImmersiveMaterial();
    const startNum: number | undefined = blurStartVp;
    const endNum: number | undefined = blurEndVp;
    // 两档统一 GRADIENT_BLUR（2026-10-11 对齐 Index 定版）：滚动模糊时机与
    // 材质档位解耦，保证兜底路径与沉浸路径「起糊 / 显影」时机一致。
    const opts: ScrollEffectOptions = {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR
    };
    if (startNum !== undefined) {
      opts.blurEffectiveStartOffset = LengthMetrics.vp(startNum);
    }
    if (endNum !== undefined) {
      opts.blurEffectiveEndOffset = LengthMetrics.vp(endNum);
    }
    // 日志打实际生效的值：真机用 `hdc shell hilog | grep TopBar` 核对
    const startText: string = startNum !== undefined ? `${startNum}` : 'default';
    const endText: string = endNum !== undefined ? `${endNum}` : 'default';
    if (immersive) {
      console.info(`[TopBar] material=immersive(ADAPTIVE) effect=GRADIENT_BLUR blurStrategy=ENABLE endpoints=transparent->transparent blurStart=${startText} blurEnd=${endText}`);
      // 渐进模糊显式样式端点（2026-10-12 按指南四步法补齐）：滚动前 → 滚动完成后
      // 均为透明背景，系统在 blurEffectiveStartOffset~blurEffectiveEndOffset 区间内
      // 线性驱动渐变模糊显形。ENABLE / ADAPTIVE 材质保留（2026-10-11 定版，
      // 部分设备动态模糊渲染的强制开关）。
      //
      // ⚠️ 终点必须是透明，不能用不透明实色（2026-10-12 二次修正）：首版端点把
      // scrollEffectStyle 终点设为不透明 bg_page（意图「与页面底色融合」），结果
      // 滚动到位后实色背景把 GRADIENT_BLUR 渲染的渐变模糊整个盖住 —— 真机表现为
      // 「滚动后顶栏渐进模糊消失、只剩实色渐入」。渐变模糊是系统画在标题栏后的
      // 视效，只有背景保持透明才能透出；官方 GRADIENT_BLUR 可用配置（FAQ
      // faqs-arkui-component-3）的 scrollEffectStyle 终点同样是透明背景。
      return {
        scrollEffectOpts: opts,
        blurStrategy: BlurStrategy.ENABLE,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
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
    }
    // 兜底：GRADIENT_BLUR 滚动模糊 + 半透明玻璃底色 + blurRadius 近似旧 backgroundEffect。
    // 起点用「弱玻璃」（几乎透明、有一点底色，官方博客防闪烁口径），终点是标准玻璃色——
    // ⚠️ 修复（2026-10-09）：此前两端都用 header_glass_tint，样式零差异 → 滚动无动态。
    // maskExtraHeight：模糊蒙层额外高度，两端同值避免插值时蒙层伸缩
    const maskNum: number = maskExtraVp !== undefined && maskExtraVp > 0 ? maskExtraVp : 32;
    console.info(`[TopBar] material=fallback effect=GRADIENT_BLUR blurStrategy=ENABLE blurRadius=40 blurStart=${startText} blurEnd=${endText} mask=${maskNum}`);
    return {
      scrollEffectOpts: opts,
      blurStrategy: BlurStrategy.ENABLE,
      thermoCtrl: true,
      originalStyle: {
        backgroundStyle: {
          backgroundColor: $r('app.color.header_glass_tint_weak'),
          blurRadius: 40,
          maskExtraHeight: maskNum
        }
      },
      scrollEffectStyle: {
        backgroundStyle: {
          backgroundColor: $r('app.color.header_glass_tint'),
          blurRadius: 40,
          maskExtraHeight: maskNum
        }
      }
    };
  }
}
