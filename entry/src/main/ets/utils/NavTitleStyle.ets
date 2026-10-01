/**
 * API 26 原生沉浸光感标题栏配置（NavigationTitleOptions）。
 *
 * - barStyle: STACK —— 内容延伸到标题栏下方，列表滚动时从材质下透出；
 * - systemMaterial: THIN 沉浸光感材质，materialColor 全透明白
 *   （不透明会挡住下面内容，玻璃效果由材质本身产生），
 *   interactive 开启按压形变反馈；
 * - backgroundColor Transparent + backgroundBlurStyle NONE：
 *   透掉标题栏默认底色/模糊，让 systemMaterial 完全接管；
 * - 运行时能力缺失（部分设备未注入 uiMaterial）时退化为透明标题栏，不影响使用。
 *
 * ⚠️ **标题栏整体落在状态栏下方**（用户要求：文字按钮不被状态栏 / 挖孔遮挡）。
 * NavDestination 自 API 11 起默认 `expandSafeArea([SYSTEM],[TOP,BOTTOM])`，原先靠它把
 * 标题栏顶到屏幕最顶、与状态栏融为一体；现在各子页在 NavDestination 上显式
 * `.padding({ top: safeTop })` 把标题栏与内容一起顶下来，覆盖该默认行为。
 * 材质仍是半透明毛玻璃（只是不再压到状态栏上），列表照旧从材质下透出。
 */

// uiMaterial 模块 26.0.0 才有（API 23/24 上静态 import 崩溃），必须 lazy；
// 且下方访问全部收在 isImmersiveSupported()（sdkApiVersion >= 26）之内。
import lazy { uiMaterial } from '@kit.ArkUI';
import { CompatUtils } from './MaterialCompat';

/** 沉浸标题栏高度（内容区顶部避让基准） */
export const NAV_TITLE_BAR_HEIGHT: number = 56;

export function immersiveTitleOptions(): NavigationTitleOptions {
  // API 23/24：无 uiMaterial 模块，也不认 systemMaterial 字段，退化为透明标题栏。
  if (!CompatUtils.isImmersiveSupported()) {
    return {
      backgroundColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      barStyle: BarStyle.STACK
    };
  }
  let material: uiMaterial.Material | undefined = undefined;
  try {
    if (uiMaterial.isImmersiveMaterialSupported()) {
      material = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        materialColor: 0x00FFFFFF,
        interactive: true
      });
    }
  } catch (e) {
    console.error(`create titleBar immersiveMaterial failed: ${JSON.stringify(e)}`);
  }
  return {
    backgroundColor: Color.Transparent,
    backgroundBlurStyle: BlurStyle.NONE,
    barStyle: BarStyle.STACK,
    systemMaterial: material
  };
}
