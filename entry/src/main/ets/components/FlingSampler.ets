/**
 * [Fling] F1 边界采样器（design/Fling状态触发-两工程对照与AI实施规格.md §F1）。
 *
 * 参考两工程共识：「惯性帧不写状态」。本类只做**状态翻转检测**——
 * `note()` 与上次状态比较，翻转才返回 true，调用方据此**只在边界写一次**
 * （打日志），严禁逐帧写。
 *
 * 硬约束（规格 §6）：
 * - 内部只有普通静态成员，不得声明 @State / @StorageLink；
 * - 调用方回调必须 void 返回，绝不返回 ScrollResult（会吃帧）；
 * - 只挂首页签 List 一处（SearchPage），禁止全站铺。
 */
export class FlingSampler {
  /** 上一次采样到的滚动状态：翻转检测的唯一依据 */
  private static lastState: ScrollState = ScrollState.Idle;

  /**
   * 状态翻转检测：与 lastState 比较，变化时更新并返回 true（边界到达），
   * 未变化返回 false（调用方什么都不许做）。
   */
  static note(state: ScrollState): boolean {
    if (state === FlingSampler.lastState) {
      return false;
    }
    FlingSampler.lastState = state;
    return true;
  }

  /** 状态名（仅日志用）：Idle / Scroll / Fling。⚠️ 不能叫 name —— 与内置
   * Function.name 冲突（真机编译器 10505001 实测报错） */
  static stateName(state: ScrollState): string {
    if (state === ScrollState.Fling) {
      return 'Fling';
    }
    return state === ScrollState.Scroll ? 'Scroll' : 'Idle';
  }
}
