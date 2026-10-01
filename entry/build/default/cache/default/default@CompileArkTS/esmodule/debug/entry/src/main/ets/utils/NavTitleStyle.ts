import lazy uiMaterial from "@ohos:arkui.uiMaterial";
import { CompatUtils } from "@normalized:N&&&entry/src/main/ets/utils/MaterialCompat&";
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
    }
    catch (e) {
        console.error(`create titleBar immersiveMaterial failed: ${JSON.stringify(e)}`);
    }
    return {
        backgroundColor: Color.Transparent,
        backgroundBlurStyle: BlurStyle.NONE,
        barStyle: BarStyle.STACK,
        systemMaterial: material
    };
}
