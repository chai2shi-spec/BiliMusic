/**
 * 标题栏毛玻璃的共享属性修饰器（各 Tab 页 / 子页固定标题栏通用）。
 *
 * 另有按钮通路（ButtonMaterialModifier）：给搜索 / 新建 / 选择等胶囊按钮用。
 * 按钮自带链式实色底作为兜底，修饰器低版本 no-op 即可，不需要塞 backgroundColor。
 *
 * 自绘容器通路：官方《沉浸光感常见问题》明确「其他组件」的 systemMaterial 仅在
 * Navigation/NavDestination 标题栏或横向 Tabs 底部 TabBar 生效，其他区域静默
 * 不渲染 —— 自绘 Row 直接挂 .systemMaterial() 就是全透明。二级页悬浮播放栏
 * 走 HDS 载体（见 SubPagePlayBar.ets，二号 HdsTabs miniBar 通路），
 * 本文件不提供自绘容器修饰器。
 *
 * 分段按钮配色（SegmentColors / makeBiliSegmentColors）：
 * CapsuleSegmentButtonV2 等标准组件的 B 站粉着色参数组。
 *
 * ⚠️ 属性优先级：ArkUI 链式属性优先级高于 attributeModifier，挂本修饰器的 Row
 * 上不要再链式设置 background / backgroundEffect，否则会被链式值覆盖。
 *
 * 按钮材质工厂走 MaterialCompat 的版本门控（sdkApiVersion ≥ 26 + typeof 运行时探测），
 * 调用方只需 `makeButtonMaterialModifier()`，无需再关心兼容分支。
 */

// uiMaterial 模块 26.0.0 才有（API 23/24 上静态 import 崩溃），必须 lazy；
// 本文件只在类型位置引用它，运行时经 MaterialCompat 的版本门控访问。
import { ColorMetrics } from '@kit.ArkUI';
import lazy { uiMaterial } from '@kit.ArkUI';
import { MaterialCompat, MaterialCompatStyle } from './MaterialCompat';
import { STORE_THEME_PRIMARY, STORE_THEME_ON } from '../common/Constants';

/**
 * 按钮沉浸光感材质的属性修饰器：仅当材质对象存在（API 26+ 且运行时支持）时
 * 才调用 systemMaterial（THIN + interactive + lightEffect，小控件靠光效出玻璃感）；
 * 低版本 no-op —— 按钮自带的链式实色底（bili_pink / brand_surface）即兜底，
 * 用户在 API 23/24 设备上看到的就是这些实色。
 */
export class ButtonMaterialModifier implements AttributeModifier<ButtonAttribute> {
  private material: uiMaterial.ImmersiveMaterial | undefined;

  constructor(material: uiMaterial.ImmersiveMaterial | undefined) {
    this.material = material;
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    const m: uiMaterial.ImmersiveMaterial | undefined = this.material;
    if (m === undefined) {
      return;
    }
    try {
      instance.systemMaterial(m);
    } catch (e) {
      console.error(`apply button systemMaterial failed: ${JSON.stringify(e)}`);
    }
  }
}

/**
 * 生成按钮用 THIN 档交互材质修饰器：
 * 搜索页（视频切换 / 搜索）、歌单页（新建）、下载页（选择）等胶囊按钮统一走这里。
 */
export function makeButtonMaterialModifier(): ButtonMaterialModifier {
  return new ButtonMaterialModifier(
    MaterialCompat.immersiveMaterial(MaterialCompatStyle.THIN, { interactive: true, lightEffect: true })
  );
}

/**
 * 输入框沉浸光感材质的属性修饰器：与 ButtonMaterialModifier 同款通路（THIN +
 * interactive + lightEffect），仅类型钉在 TextInputAttribute 上 —— ArkTS 无结构化
 * 泛型复用，按钮版不能直接挂 TextInput，需要本平行类。
 * 材质对象为 undefined（API < 26 / 运行时缺失）时 no-op，输入框自带的链式实色底
 * 即兜底（UP 主页搜索框：bg_card）。
 */
export class TextInputMaterialModifier implements AttributeModifier<TextInputAttribute> {
  private material: uiMaterial.ImmersiveMaterial | undefined;

  constructor(material: uiMaterial.ImmersiveMaterial | undefined) {
    this.material = material;
  }

  applyNormalAttribute(instance: TextInputAttribute): void {
    const m: uiMaterial.ImmersiveMaterial | undefined = this.material;
    if (m === undefined) {
      return;
    }
    try {
      instance.systemMaterial(m);
    } catch (e) {
      console.error(`apply textInput systemMaterial failed: ${JSON.stringify(e)}`);
    }
  }
}

/**
 * 生成输入框用 THIN 档交互材质修饰器：
 * UP 主页头部搜索框（与同行播放全部 / 订阅投稿 / 搜索按钮同档，玻璃观感统一）。
 */
export function makeTextInputMaterialModifier(): TextInputMaterialModifier {
  return new TextInputMaterialModifier(
    MaterialCompat.immersiveMaterial(MaterialCompatStyle.THIN, { interactive: true, lightEffect: true })
  );
}

/**
 * 解析颜色为 ColorMetrics（CapsuleSegmentButtonV2 / Chip 等标准组件的
 * 着色参数用）。入参放宽到 ResourceColor —— 主题切换后主色是 AppStorage 里的
 * hex 字符串而不是资源引用。解析失败返回 undefined —— 组件可空参数回落系统
 * 默认色，不抛错不崩溃。
 */
function loadColorMetrics(color: ResourceColor): ColorMetrics | undefined {
  try {
    return ColorMetrics.resourceColor(color);
  } catch (e) {
    console.error(`loadColorMetrics failed: ${JSON.stringify(e)}`);
    return undefined;
  }
}

/**
 * 当前主题色的分段按钮配色组（CapsuleSegmentButtonV2 着色参数）：
 * 选中底 / 选中字读 AppStorage 主题色键（EntryAbility 启动发布、设置页切色重发布；
 * ?? 后的 hex 是偏好尚未发布时的兜底），未选中字 text_secondary / 凹槽 bg_divider
 * 维持资源色。任一解析失败 → 对应项 undefined，组件回落系统默认色。
 * ⚠️ 调用方必须每次渲染现取（getter），缓存成字段的话切色不刷新。
 */
export interface SegmentColors {
  selectedBg: ColorMetrics | undefined;
  selectedFont: ColorMetrics | undefined;
  unselectedFont: ColorMetrics | undefined;
  grooveBg: ColorMetrics | undefined;
}

/** 生成当前主题色的分段按钮配色组：搜索行「视频/UP主」、页签行四段、观看历史段切换统一走这里 */
export function makeBiliSegmentColors(): SegmentColors {
  return {
    selectedBg: loadColorMetrics(AppStorage.get<string>(STORE_THEME_PRIMARY) ?? '#FB7299'),
    selectedFont: loadColorMetrics(AppStorage.get<string>(STORE_THEME_ON) ?? '#3D0018'),
    unselectedFont: loadColorMetrics($r('app.color.text_secondary')),
    grooveBg: loadColorMetrics($r('app.color.bg_divider'))
  };
}
