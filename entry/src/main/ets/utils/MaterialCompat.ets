/**
 * 沉浸式材质兼容层（移植自 Sumy-Music）。
 *
 * ⚠️ 更正一条曾经写错的结论：早先这里注释说「本机 HarmonyOS SDK 并未提供
 * @kit.UIDesignKit」—— 那是只翻了 `sdk/default/openharmony/ets/kits` 得出的误判。
 * 该 kit 在 **hms 侧**（`sdk/default/hms/ets/kits/@kit.UIDesignKit.d.ets`），
 * 已实测可编译（HdsTabs / hdsMaterial 均可用），故现在把 HDS 这一路补回来。
 *
 * 两条并列的「沉浸材质」通路，用途不同、别混用：
 * - **HDS 通路**（`hdsMaterial` + `systemMaterialEffect`）：给 HdsTabs 等 HDS 组件用。
 *   材质由 HDS 自己施加，我们只通过 `MaterialCompat.supportsImmersiveMaterial()`
 *   决定材质档位（EXQUISITE 精美 / ADAPTIVE 自适应）。
 * - **uiMaterial 通路**（`uiMaterial.ImmersiveMaterial` + `.systemMaterial()`）：
 *   给自绘组件（Row / Column 等）用。低版本或运行时能力缺失时返回 undefined，
 *   调用方再用 `MaterialCompat.effect()` 走 backgroundEffect 模拟毛玻璃。
 *   ⚠️ 官方《沉浸光感常见问题》生效范围（2026-10-24 真机实锤）：「其他组件」的
 *   systemMaterial 仅在 Navigation/NavDestination 标题栏或横向 Tabs 底部
 *   TabBar（barPosition=End）内生效，其他区域**静默不渲染**——自绘 Row 直接
 *   挂 .systemMaterial() 就是全透明。当前工程无 uiMaterial 消费方：二级页
 *   悬浮播放栏（SubPagePlayBar）2026-10-24 终版走 HDS 内部材质通路（二号
 *   HdsTabs miniBar + systemMaterialEffect，与首页胶囊同源），普通 Tabs
 *   barFloatingStyle.systemMaterial 载体（B案）真机生效但观感不达预期已弃。
 */

// ⚠️ @ohos.arkui.uiMaterial 整个模块 26.0.0 才有：API 23/24 设备上静态 import 会在
// 模块加载期直接失败导致启动崩溃，必须 lazy —— 首次访问时才解析模块，
// 而所有访问点都被 sdkApiVersion >= 26 挡住，老设备永远不会触发加载。
import lazy { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 材质分档，对应 uiMaterial.ImmersiveStyle（从薄到厚） */
export enum MaterialCompatStyle {
  ULTRA_THIN = 0,
  THIN = 1,
  REGULAR = 2,
  THICK = 3,
  ULTRA_THICK = 4
}

/** 模拟材质参数，结构兼容 backgroundEffect 的 BackgroundEffectOptions */
export interface MaterialEffectOptions {
  radius: number;
  saturation: number;
  brightness: number;
  color: string;
}

export interface MaterialImmersiveOptions {
  interactive?: boolean;
  lightEffect?: boolean;
}

export class CompatUtils {
  private static supportImmersive: boolean | null = null;

  static isImmersiveSupported(): boolean {
    if (CompatUtils.supportImmersive === null) {
      CompatUtils.supportImmersive = deviceInfo.sdkApiVersion >= 26;
    }
    return CompatUtils.supportImmersive;
  }
}

export class MaterialCompat {
  /** 能力日志只打一次的标记 */
  private static capabilityLogged: boolean = false;
  /** hasImmersiveMaterial 结果缓存（能力在运行期不变，null = 未探测） */
  private static hasImmersiveCache: boolean | null = null;

  /**
   * 本机是否真正能渲染 systemMaterial 沉浸材质（sdkApiVersion ≥ 26 +
   * 运行时注入了 ImmersiveStyle + 设备上报 isImmersiveMaterialSupported），
   * 与 immersiveMaterial() 返回非 undefined 的判定完全同源。
   *
   * 调用方据此决定组件链式背景色的取值：材质可用时必须给**透明**底
   * （官方 FAQ「背景色遮挡材质效果」：不透明 backgroundColor 画在材质层
   * 之上，玻璃被完全盖住），不可用时回落实色兜底。结果缓存，能力运行期
   * 不变，重复调用零开销。
   */
  static hasImmersiveMaterial(): boolean {
    if (MaterialCompat.hasImmersiveCache !== null) {
      return MaterialCompat.hasImmersiveCache;
    }
    let ok: boolean = false;
    if (CompatUtils.isImmersiveSupported()) {
      try {
        if (typeof uiMaterial.ImmersiveStyle !== 'undefined' && uiMaterial.isImmersiveMaterialSupported()) {
          ok = true;
        }
      } catch (e) {
        console.error(`[MaterialCompat] probe hasImmersiveMaterial failed: ${JSON.stringify(e)}`);
      }
    }
    MaterialCompat.hasImmersiveCache = ok;
    return ok;
  }

  /**
   * 一次性输出设备沉浸材质能力四要素（hilog 可查）：
   * sdkApiVersion / isImmersiveMaterialSupported / getGlobalMaterialLevel / getMaterialInfo。
   * isImmersiveMaterialSupported() 为 false 时 systemMaterial 会「静默不生效」，
   * getGlobalMaterialLevel() 为 SMOOTH（低算力档）时不渲染背景滤镜 ——
   * 这两项正是「API 已到 26 但材质仍不可见」的两大隐藏开关。
   */
  private static logCapabilityOnce(): void {
    if (MaterialCompat.capabilityLogged) {
      return;
    }
    MaterialCompat.capabilityLogged = true;
    try {
      const supported: boolean = uiMaterial.isImmersiveMaterialSupported();
      const level: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      console.info(`[MaterialCompat] capability: sdkApiVersion=${deviceInfo.sdkApiVersion}, `
        + `immersiveSupported=${supported}, materialLevel=${JSON.stringify(level)}, `
        + `materialInfo=${JSON.stringify(info)}`);
    } catch (e) {
      console.error(`[MaterialCompat] probe capability failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 生成模拟沉浸式材质的 backgroundEffect 参数
   * @param isDark 是否深色模式
   * @param cardBg 卡片底色（深色模式下作为蒙版基色）
   * @param style 材质分档
   */
  static effect(isDark: boolean, cardBg: string, style?: MaterialCompatStyle): MaterialEffectOptions {
    const s: MaterialCompatStyle = style !== undefined ? style : MaterialCompatStyle.REGULAR;
    let radius: number = 20;
    let lightAlpha: number = 0.52;
    let darkAlpha: number = 0.80;
    switch (s) {
      case MaterialCompatStyle.ULTRA_THIN:
        radius = 12;
        lightAlpha = 0.36;
        darkAlpha = 0.65;
        break;
      case MaterialCompatStyle.THIN:
        radius = 16;
        lightAlpha = 0.44;
        darkAlpha = 0.72;
        break;
      case MaterialCompatStyle.THICK:
        radius = 28;
        lightAlpha = 0.64;
        darkAlpha = 0.86;
        break;
      case MaterialCompatStyle.ULTRA_THICK:
        radius = 36;
        lightAlpha = 0.78;
        darkAlpha = 0.92;
        break;
      case MaterialCompatStyle.REGULAR:
      default:
        break;
    }
    const color: string = isDark
      ? MaterialCompat.withAlpha(cardBg, darkAlpha)
      : MaterialCompat.withAlpha('#FFFFFF', lightAlpha);
    return {
      radius: radius,
      saturation: 1.2,
      brightness: 1.0,
      color: color
    };
  }

  /**
   * API 26+ 返回真正的沉浸式材质对象，供 .systemMaterial() 使用；
   * 低版本或运行时能力缺失时返回 undefined（systemMaterial 接受 undefined，走默认样式）。
   *
   * 双重守卫：部分设备上报的 sdkApiVersion 已达 26，但运行时并未注入
   * uiMaterial.ImmersiveStyle，此时读取其成员会抛 TypeError 并导致启动崩溃，
   * 因此用 typeof 做一次运行时能力探测。
   */
  static immersiveMaterial(
    style?: MaterialCompatStyle,
    options?: MaterialImmersiveOptions
  ): uiMaterial.ImmersiveMaterial | undefined {
    if (!CompatUtils.isImmersiveSupported()) {
      console.info(`[MaterialCompat] sdkApiVersion=${deviceInfo.sdkApiVersion} < 26, immersiveMaterial -> undefined`);
      return undefined;
    }
    try {
      if (typeof uiMaterial.ImmersiveStyle === 'undefined') {
        console.info('[MaterialCompat] runtime has no uiMaterial.ImmersiveStyle, immersiveMaterial -> undefined');
        return undefined;
      }
      MaterialCompat.logCapabilityOnce();
      if (!uiMaterial.isImmersiveMaterialSupported()) {
        console.info('[MaterialCompat] device reports isImmersiveMaterialSupported=false, '
          + 'systemMaterial will be silently ignored -> undefined');
        return undefined;
      }
      const s: MaterialCompatStyle = style !== undefined ? style : MaterialCompatStyle.REGULAR;
      let immersiveStyle: uiMaterial.ImmersiveStyle;
      switch (s) {
        case MaterialCompatStyle.ULTRA_THIN:
          immersiveStyle = uiMaterial.ImmersiveStyle.ULTRA_THIN;
          break;
        case MaterialCompatStyle.THIN:
          immersiveStyle = uiMaterial.ImmersiveStyle.THIN;
          break;
        case MaterialCompatStyle.THICK:
          immersiveStyle = uiMaterial.ImmersiveStyle.THICK;
          break;
        case MaterialCompatStyle.ULTRA_THICK:
          immersiveStyle = uiMaterial.ImmersiveStyle.ULTRA_THICK;
          break;
        case MaterialCompatStyle.REGULAR:
        default:
          immersiveStyle = uiMaterial.ImmersiveStyle.REGULAR;
          break;
      }
      const opts: uiMaterial.ImmersiveOptions = {
        style: immersiveStyle,
        applyShadow: true
      };
      if (options !== undefined && options.interactive === true) {
        opts.interactive = true;
      }
      if (options !== undefined && options.lightEffect === true) {
        opts.lightEffect = { color: Color.White };
      }
      console.info(`[MaterialCompat] immersiveMaterial created: style=${immersiveStyle}, interactive=${opts.interactive === true}`);
      return new uiMaterial.ImmersiveMaterial(opts);
    } catch (e) {
      console.error(`create immersiveMaterial failed: ${JSON.stringify(e)}`);
      return undefined;
    }
  }

  /**
   * 设备是否支持 HDS 的 IMMERSIVE 材质类型（hdsMaterial，6.1.0(23) 起）。
   *
   * 支持 → HDS 组件（本工程里是 HdsTabs 悬浮底栏）可用 MaterialLevel.EXQUISITE 精美档；
   * 不支持 / 查询异常 → 调用方回落 MaterialLevel.ADAPTIVE，由系统按算力自适应，
   * 避免低配设备强上精美档导致卡顿发热。
   *
   * 探测本身可能抛异常（老设备 / 裁剪版 ROM 可能没注入该命名空间成员），
   * 一律 catch 后返回 false —— 探测失败时「当作不支持」是安全方向。
   */
  static supportsImmersiveMaterial(): boolean {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      return types.includes(hdsMaterial.MaterialType.IMMERSIVE);
    } catch (e) {
      console.error(`getSystemMaterialTypes failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 将 #RRGGBB 颜色转换为 #AARRGGBB（追加/替换 alpha 通道） */
  static withAlpha(hexColor: string, alpha: number): string {
    let hex: string = hexColor.replace('#', '');
    if (hex.length === 8) {
      hex = hex.substring(2);
    }
    hex = hex.substring(0, 6);
    const a: number = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
    return `#${a.toString(16).padStart(2, '0')}${hex}`;
  }
}
