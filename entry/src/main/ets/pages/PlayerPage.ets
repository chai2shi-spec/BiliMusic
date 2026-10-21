/**
 * 播放详情页（2026-10-21 组件状态切换动画改版：不再是 NavDestination，无路由）。
 *
 * 本页现在是 Index 根 Stack 上的 overlay 薄壳：PlayBar.openPlayer 写
 * STORE_PLAYER_OVERLAY_MOUNTED=true → Index 条件挂载 LazyDest('Player')（复用
 * 懒加载注册 + 1.5s 预热，冷启动优化不回退）→ 本组件 → PlayerInfoComponent。
 *
 * 打开/收起的主动画全部由组件状态驱动（无 pushPath / pop / customTransition）：
 *   · 打开：PlayerInfoComponent.playEnterTransition —— 单个 animateTo(700ms,
 *     PLAYER_MAIN_CURVE) 写 STORE_PLAYER_OPEN=true，同帧驱动两套 geometryTransition
 *     配对（背景面从迷你栏真实视觉包围盒长到全屏 + 唱片页内配对飞行）与
 *     Index 页签图标 opacity 淡出。
 *   · 收起：TopArea 收起按钮（STORE_PLAYER_CLOSE_REQUEST seq）或系统返回
 *     （Index.onBackPress 拦截）→ Index.closePlayer 的 animateTo 逆向镜像，
 *     700ms 后 STORE_PLAYER_OVERLAY_MOUNTED=false 卸载本壳。
 *
 * 保留的原有机制：
 *   - 全屏布局避让（safeTop / safeBottom 在 PlayerInfoComponent 内部消费）；
 *   - 离开时把状态栏内容色复原为黑（首页是浅色背景）。
 */

import { PlayerInfoComponent } from '../components/player/PlayerInfoComponent';
import { ColorConversion } from '../common/utils/ColorConversion';
import { common } from '@kit.AbilityKit';

@Component
export struct PlayerPage {
  aboutToDisappear(): void {
    // 状态栏内容色复原为黑图标：沉浸页里按背景明暗切换过，首页是浅色背景
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      ColorConversion.setStatusBarContentColor(ctx, false);
    }
  }

  build() {
    Stack() {
      PlayerInfoComponent()
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 懒加载注册表入口（见 service/LazyPageRegistry.ets，2026-10-17 启动优化）：
 * Index 不静态 import 本页；动态 import 后经 wrapBuilder 调用本 Builder 渲染
 *（路由 pageMap 与播放页 overlay 共用同一份注册与预热）。
 */
@Builder
export function PlayerPageBuilder(): void {
  PlayerPage()
}


/** 懒加载注册表预包装（2026-10-17）：wrapBuilder 只接受本文件内的直接
 * @Builder 引用（编译期校验），注册表经动态 import 取本导出。 */
export const PlayerPageWrapped: WrappedBuilder<[]> = wrapBuilder(PlayerPageBuilder);
