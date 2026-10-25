/**
 * 缓存目录文件任务（TaskPool 专用）。
 *
 * 背景：缓存统计与清理是递归同步 IO（listFileSync / statSync /
 * unlinkSync），遍历对象（含 Image 组件的 image_file_cache 等目录）
 * 文件数随使用量无上界增长，放在主线程会长时间阻塞（AppFreeze）。
 * 本文件把这两个递归函数移植为 @Concurrent 任务：递归同步 fs 在 TaskPool
 * 线程里执行是合法且廉价的，主线程只拿到最终的字节数 / 删除计数。
 *
 * ⚠️ @Concurrent 限制（必须遵守）：
 *   - 只能是本文件顶层函数，不得写成闭包 / 类方法 / 箭头函数；
 *   - 不得捕获外层变量（this、模块级可变量都算）；
 *   - 参数与返回值必须可序列化（本文件 string → number 满足）；
 *   - 只能通过 taskpool.execute 调用，禁止主线程直接 import 后同步调用。
 */

import fs from '@ohos.file.fs';

/**
 * 递归统计目录占用（字节）。目录不存在 / 单项读不动时按 0 计，绝不抛。
 * ⚠️ @Concurrent 函数禁止自引用（es2abc 报「not import variable or local
 * variable」），递归必须改写为显式栈迭代。
 */
@Concurrent
function dirSizeTask(path: string): number {
  if (path.length === 0) {
    return 0;
  }
  let total: number = 0;
  const pending: string[] = [path];
  while (pending.length > 0) {
    const dir: string | undefined = pending.pop();
    if (dir === undefined) {
      continue;
    }
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const child: string = `${dir}/${names[i]}`;
        try {
          const st: fs.Stat = fs.statSync(child);
          if (st.isDirectory()) {
            pending.push(child);
          } else {
            total += st.size;
          }
        } catch (e) {
          // 单个条目统计失败（被占用 / 刚被删）跳过
        }
      }
    } catch (e) {
      // 目录不存在
    }
  }
  return total;
}

/**
 * 清空目录内容，**保留目录自身**（cacheDir 是系统目录，不能删）。
 * @returns 删除的文件个数
 * 文件边遍历边删；子目录内容清空后再 rmdir 子目录自身。
 * ⚠️ 同上：@Concurrent 禁止自引用，递归改显式栈迭代。
 */
@Concurrent
function clearDirContentsTask(path: string): number {
  if (path.length === 0) {
    return 0;
  }
  let removed: number = 0;
  const pending: string[] = [path];
  // 按父→子顺序记录要删的子目录，最后逆序（子→父）统一 rmdir
  const dirsToRemove: string[] = [];
  while (pending.length > 0) {
    const dir: string | undefined = pending.pop();
    if (dir === undefined) {
      continue;
    }
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const child: string = `${dir}/${names[i]}`;
        try {
          const st: fs.Stat = fs.statSync(child);
          if (st.isDirectory()) {
            dirsToRemove.push(child);
            pending.push(child);
          } else {
            fs.unlinkSync(child);
            removed += 1;
          }
        } catch (e) {
          // 被占用的文件删不掉，跳过；不要因为一个文件中断整次清理
        }
      }
    } catch (e) {
      // 目录不存在
    }
  }
  for (let i = dirsToRemove.length - 1; i >= 0; i--) {
    try {
      fs.rmdirSync(dirsToRemove[i]);
    } catch (e) {
      // 非空（被占用文件残留）删不掉，跳过
    }
  }
  return removed;
}

export { dirSizeTask, clearDirContentsTask };
