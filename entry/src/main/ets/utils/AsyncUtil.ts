/**
 * 异步小工具。
 */

/** 挂起 ms 毫秒（轮询等待 / 节流间隔用） */
export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}
