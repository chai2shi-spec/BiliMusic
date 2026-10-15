/**
 * 断点系统（移植自 audio-interaction-master，按本项目规范去掉 as 断言）。
 *
 * BreakpointSystem：注册三条媒体查询监听，把当前断点（sm/md/lg）写入
 * AppStorage（BreakpointConstants.CURRENT_BREAKPOINT），各组件 @StorageProp 订阅。
 * BreakpointType：按断点取值的三态工具（sm 必填，md/lg 缺省回落 sm）。
 *
 * 注意：register 需要页面侧传入 UIContext（参考工程从 AppStorage 取，
 * 本项目改为显式传参，避免 as 断言与初始化时序问题）。
 */

import { mediaquery } from '@kit.ArkUI';
import { BreakpointConstants } from '../constants/BreakpointConstants';

/** 三态取值选项：sm 必填，md / lg 可缺省（缺省回落 sm） */
export interface BreakPointTypeOption<T> {
  sm: T;
  md?: T;
  lg?: T;
}

export class BreakpointType<T> {
  options: BreakPointTypeOption<T>;

  constructor(option: BreakPointTypeOption<T>) {
    this.options = option;
  }

  getValue(currentPoint: string): T {
    if (currentPoint === BreakpointConstants.BREAKPOINT_MD && this.options.md !== undefined) {
      return this.options.md;
    }
    if (currentPoint === BreakpointConstants.BREAKPOINT_LG && this.options.lg !== undefined) {
      return this.options.lg;
    }
    return this.options.sm;
  }
}

/** 断点监听：register / unregister 必须成对调用（页面 aboutToAppear / aboutToDisappear） */
export class BreakpointSystem {
  private currentBreakpoint: string = BreakpointConstants.BREAKPOINT_SM;
  private smListener: mediaquery.MediaQueryListener | null = null;
  private mdListener: mediaquery.MediaQueryListener | null = null;
  private lgListener: mediaquery.MediaQueryListener | null = null;

  private isBreakpointSM = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_SM);
    }
  };

  private isBreakpointMD = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_MD);
    }
  };

  private isBreakpointLG = (mediaQueryResult: mediaquery.MediaQueryResult): void => {
    if (mediaQueryResult.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_LG);
    }
  };

  private updateCurrentBreakpoint(breakpoint: string): void {
    if (this.currentBreakpoint !== breakpoint) {
      this.currentBreakpoint = breakpoint;
      AppStorage.setOrCreate<string>(BreakpointConstants.CURRENT_BREAKPOINT, this.currentBreakpoint);
    }
  }

  /** 首帧同步一次当前断点，避免首渲染按默认 sm 布局再跳变 */
  public register(context: UIContext): void {
    this.smListener = context.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_SM);
    this.smListener.on('change', this.isBreakpointSM);
    this.mdListener = context.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_MD);
    this.mdListener.on('change', this.isBreakpointMD);
    this.lgListener = context.getMediaQuery().matchMediaSync(BreakpointConstants.RANGE_LG);
    this.lgListener.on('change', this.isBreakpointLG);
    if (this.smListener.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_SM);
    } else if (this.mdListener !== null && this.mdListener.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_MD);
    } else if (this.lgListener !== null && this.lgListener.matches) {
      this.updateCurrentBreakpoint(BreakpointConstants.BREAKPOINT_LG);
    }
  }

  public unregister(): void {
    if (this.smListener !== null) {
      this.smListener.off('change', this.isBreakpointSM);
      this.smListener = null;
    }
    if (this.mdListener !== null) {
      this.mdListener.off('change', this.isBreakpointMD);
      this.mdListener = null;
    }
    if (this.lgListener !== null) {
      this.lgListener.off('change', this.isBreakpointLG);
      this.lgListener = null;
    }
  }
}
