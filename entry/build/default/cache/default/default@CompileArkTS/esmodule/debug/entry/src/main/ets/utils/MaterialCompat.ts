import lazy uiMaterial from "@ohos:arkui.uiMaterial";
import { hdsMaterial } from "@hms:hds.hdsMaterial";
import deviceInfo from "@ohos:deviceInfo";
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
    static immersiveMaterial(style?: MaterialCompatStyle, options?: MaterialImmersiveOptions): uiMaterial.ImmersiveMaterial | undefined {
        if (!CompatUtils.isImmersiveSupported()) {
            return undefined;
        }
        try {
            if (typeof uiMaterial.ImmersiveStyle === 'undefined') {
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
            return new uiMaterial.ImmersiveMaterial(opts);
        }
        catch (e) {
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
        }
        catch (e) {
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
