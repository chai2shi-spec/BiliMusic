/**
 * @Reusable 复用入参缺省判断：复用时框架用新调用点的入参覆盖 @Prop，
 * 新调用点未传的 @Prop 会被置为 undefined（不回落声明默认值）。
 * 读取处再读 `.length` / 对象成员即崩（CoverImage v1.3.5 线上崩溃：
 * jscrash "Cannot read property length of undefined"，听歌日记切周期触发）。
 * @Reusable 组件统一在 aboutToReuse 里用它回落缺省项（CoverImage / TrackCard）。
 */
export function reuseParamMissing(params: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = params[key];
  return v === undefined;
}
