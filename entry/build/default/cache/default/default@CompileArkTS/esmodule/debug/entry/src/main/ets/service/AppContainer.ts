import type common from "@ohos:app.ability.common";
import { initPreferences } from "@normalized:N&&&entry/src/main/ets/preferences/AppPreferences&";
import { initRdb } from "@normalized:N&&&entry/src/main/ets/database/RdbHelper&";
import { MusicPlayer } from "@normalized:N&&&entry/src/main/ets/player/MusicPlayer&";
import { DownloadManager } from "@normalized:N&&&entry/src/main/ets/service/DownloadManager&";
import { initBuvidCookie, upgradeBuvidCookie } from "@normalized:N&&&entry/src/main/ets/service/BiliDevice&";
export class AppContainer {
    private static initialized: boolean = false;
    static async init(context: common.Context): Promise<void> {
        if (AppContainer.initialized) {
            return;
        }
        await initPreferences(context);
        await initRdb(context);
        // buvid：缺它首页推荐接口会被 412 拦下，必须早于任何页面请求装填
        // （登录态已不存在，这是唯一的请求 Cookie 来源）
        initBuvidCookie();
        DownloadManager.getInstance().init(context);
        await MusicPlayer.getInstance().init(context);
        // 后台换取官方 buvid（不 await：本地兜底值已足够过 412，不能拖慢启动）
        upgradeBuvidCookie();
        AppContainer.initialized = true;
    }
}
