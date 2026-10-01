import window from "@ohos:window";
import type common from "@ohos:app.ability.common";
export class ColorConversion {
    /**
     * 生成沉浸式背景色：HSB 空间压亮度后转回 RGB。
     * 参考工程原实现，另补了 max===min（灰/黑白）时色相计算除零的防护。
     */
    public static dealColor(rRGB: number, gRGB: number, bRGB: number): number[] {
        let max = Math.max(Math.max(rRGB, gRGB), bRGB);
        let min = Math.min(Math.min(rRGB, gRGB), bRGB);
        let sHSB = max === 0 ? 0 : (max - min) / max;
        let bHSB = max / 255;
        let hHSB = 0;
        if (max === min) {
            // 灰色：色相无意义，跳过色相计算
            hHSB = 0;
        }
        else if (max === rRGB && gRGB >= bRGB) {
            hHSB = 60 * (gRGB - bRGB) / (max - min) + 0;
        }
        else if (max === rRGB && gRGB < bRGB) {
            hHSB = 60 * (gRGB - bRGB) / (max - min) + 360;
        }
        else if (max === gRGB) {
            hHSB = 60 * (bRGB - rRGB) / (max - min) + 120;
        }
        else {
            hHSB = 60 * (rRGB - gRGB) / (max - min) + 240;
        }
        if (bHSB >= 0.4) {
            bHSB = 0.3;
        }
        else if (bHSB >= 0.2) {
            bHSB -= 0.1;
        }
        else {
            bHSB = bHSB + 0.2;
        }
        let i: number = Math.floor((hHSB / 60) % 6);
        let f = (hHSB / 60) - i;
        let p = bHSB * (1 - sHSB);
        let q = bHSB * (1 - f * sHSB);
        let t = bHSB * (1 - (1 - f) * sHSB);
        switch (i) {
            case 0:
                rRGB = bHSB;
                gRGB = t;
                bRGB = p;
                break;
            case 1:
                rRGB = q;
                gRGB = bHSB;
                bRGB = p;
                break;
            case 2:
                rRGB = p;
                gRGB = bHSB;
                bRGB = t;
                break;
            case 3:
                rRGB = p;
                gRGB = q;
                bRGB = bHSB;
                break;
            case 4:
                rRGB = t;
                gRGB = p;
                bRGB = bHSB;
                break;
            case 5:
                rRGB = bHSB;
                gRGB = p;
                bRGB = q;
                break;
            default:
                break;
        }
        return [Math.floor(rRGB * 255.0), Math.floor(gRGB * 255.0), Math.floor(bRGB * 255.0)];
    }
    /**
     * 按背景明暗切换状态栏内容色：暗背景 → 白图标，亮背景 / 退出播放页 → 黑图标。
     * 全屏布局（setWindowLayoutFullScreen）下状态栏叠在页面背景上，
     * 不切换会出现「黑图标压在暗背景上看不见」。任何失败都不阻断主流程。
     */
    public static setStatusBarContentColor(context: common.Context, isDarkBackground: boolean): void {
        window.getLastWindow(context)
            .then((win: window.Window): Promise<void> => {
            const props: window.SystemBarProperties = {
                statusBarContentColor: isDarkBackground ? '#ffffff' : '#000000'
            };
            return win.setWindowSystemBarProperties(props);
        })
            .catch((e: Error): void => {
            console.error(`setStatusBarContentColor failed: ${e.message}`);
        });
    }
}
