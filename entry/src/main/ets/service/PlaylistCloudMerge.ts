/**
 * 云端歌单合并（方案 §5.3，纯函数：无 IO、无状态、无副作用）。
 *
 * 输入：本地歌单 L、其他设备同一歌单视图的数组 R、base（上次同步成功时的
 * 曲目 id 集合快照，null = 首次同步 / base 丢失）。
 *
 * 三条规则（顺序即优先级）：
 *   ① 元信息（name / description / coverUrl / upMid / upName / sourceKind /
 *     titleSorted）→ 整单 LWW：取 updatedAt 更大的一版；coverUrl 为空回落到
 *     任一非空 —— 改名与加歌是两类操作，不因「另一台加了首歌」回退名字。
 *   ② 曲目 → 按 track.id 三路集合合并（base / L / R）。安全阀：base 为空时
 *     只做并集永不删除 —— 与 FavSyncManager「上游 0 条永不作为删除依据」
 *     同一条纪律：数据同步里最贵的错误是静默丢数据，不是多留一条。
 *   ③ 顺序：取元信息赢家的 tracks 顺序为骨架（滤掉被删条目），另一侧独有
 *     的保留条目按 addedAt 升序追加到尾部。
 *
 * 曲目实例取舍：本地实例优先（保留本机 localFilePath 等不跨设备字段），
 * 本地没有的取「updatedAt 最新」的远端实例。
 */

import { Playlist, slimTrack, Track } from '../model/MusicModels';

/** ISO 串 → ms（非法 / 缺失回落 0，保证比较单调） */
function msOf(iso: string | undefined): number {
  if (iso === undefined || iso === null) {
    return 0;
  }
  const t: number = Date.parse(iso);
  return Number.isFinite(t) ? t : 0;
}

/** 歌单 updatedAt 的 ms（LWW 比较键） */
function updatedMsOf(p: Playlist): number {
  return msOf(p.updatedAt);
}

/**
 * 合并单个歌单（L + R[] + base）→ 新 Playlist（不修改任何入参）。
 *
 * @param local 本地歌单（id 一定非空）
 * @param remotes 其他设备的同 id 歌单视图（调用方已按 id 过滤；空数组 = 只回本地）
 * @param baseIds 上次同步成功时该歌单的曲目 id 集合；null = 无 base → 并集模式（永不删）
 */
export function mergePlaylist(local: Playlist, remotes: Playlist[], baseIds: Set<string> | null): Playlist {
  // 候选按 updatedAt 降序（含本地），第 0 个即元信息赢家
  const candidates: Playlist[] = [local];
  for (let i = 0; i < remotes.length; i++) {
    if (remotes[i].id === local.id) {
      candidates.push(remotes[i]);
    }
  }
  candidates.sort((a: Playlist, b: Playlist): number => updatedMsOf(b) - updatedMsOf(a));
  const winner: Playlist = candidates[0];

  // 曲目实例登记：本地优先，远端按 updatedAt 降序补缺（同 id 先到先得）
  const trackById: Map<string, Track> = new Map<string, Track>();
  for (let i = 0; i < local.tracks.length; i++) {
    const t: Track = local.tracks[i];
    if (t !== null && t !== undefined && typeof t.id === 'string' && t.id.length > 0
      && !trackById.has(t.id)) {
      trackById.set(t.id, t);
    }
  }
  const remoteSorted: Playlist[] = remotes.slice().sort(
    (a: Playlist, b: Playlist): number => updatedMsOf(b) - updatedMsOf(a));
  const remoteIds: Set<string> = new Set<string>();
  for (let r = 0; r < remoteSorted.length; r++) {
    const p: Playlist = remoteSorted[r];
    for (let i = 0; i < p.tracks.length; i++) {
      const t: Track = p.tracks[i];
      if (t === null || t === undefined || typeof t.id !== 'string' || t.id.length === 0) {
        continue;
      }
      remoteIds.add(t.id);
      if (!trackById.has(t.id)) {
        trackById.set(t.id, t);
      }
    }
  }

  // 三路集合合并（§5.3 表格的代码化）
  const localIds: Set<string> = new Set<string>();
  for (let i = 0; i < local.tracks.length; i++) {
    if (local.tracks[i] !== null && local.tracks[i] !== undefined) {
      localIds.add(local.tracks[i].id);
    }
  }
  const kept: Set<string> = new Set<string>();
  const allIds: string[] = Array.from(trackById.keys());
  for (let i = 0; i < allIds.length; i++) {
    const id: string = allIds[i];
    if (baseIds === null) {
      // 无 base（首次 / 快照丢失）：并集安全阀，绝不删除
      kept.add(id);
      continue;
    }
    const inL: boolean = localIds.has(id);
    const inR: boolean = remoteIds.has(id);
    const inB: boolean = baseIds.has(id);
    // 两边都在 → 保留；单边独有 → 新增保留；base 有而一侧没了 → 该侧删过 → 删
    if ((inL || inR) && (!inB || (inL && inR))) {
      kept.add(id);
    }
  }

  // 顺序：赢家 tracks 顺序为骨架（滤掉被删 / 重复条目），剩余保留条目按 addedAt 升序补尾
  const ordered: Track[] = [];
  const used: Set<string> = new Set<string>();
  for (let i = 0; i < winner.tracks.length; i++) {
    const wt: Track = winner.tracks[i];
    if (wt === null || wt === undefined) {
      continue;
    }
    if (kept.has(wt.id) && !used.has(wt.id)) {
      used.add(wt.id);
      const inst: Track | undefined = trackById.get(wt.id);
      if (inst !== undefined) {
        ordered.push(inst);
      }
    }
  }
  const leftovers: Track[] = [];
  for (let i = 0; i < allIds.length; i++) {
    const id: string = allIds[i];
    if (kept.has(id) && !used.has(id)) {
      used.add(id);
      const inst: Track | undefined = trackById.get(id);
      if (inst !== undefined) {
        leftovers.push(inst);
      }
    }
  }
  leftovers.sort((a: Track, b: Track): number => msOf(a.addedAt) - msOf(b.addedAt));

  // coverUrl 回落：赢家空 → 本地 → 任一非空
  let coverUrl: string = winner.coverUrl || local.coverUrl || '';
  if (coverUrl.length === 0) {
    for (let i = 0; i < candidates.length && coverUrl.length === 0; i++) {
      coverUrl = candidates[i].coverUrl || '';
    }
  }

  return {
    id: local.id,
    name: winner.name || local.name,
    description: winner.description,
    coverUrl: coverUrl,
    createdAt: winner.createdAt || local.createdAt,
    updatedAt: winner.updatedAt || local.updatedAt,
    upMid: winner.upMid,
    upName: winner.upName,
    sourceKind: winner.sourceKind ?? '',
    titleSorted: winner.titleSorted === true,
    tracks: ordered.concat(leftovers)
  };
}

/**
 * 合并各设备的墓碑表（§5.3 ④）：全设备并集、deletedAt 取最早
 * （一台删了就算删）；超过 TTL（60 天）的过期条目丢弃。
 */
export function mergeTombstones(maps: Array<Record<string, number>>,
  ttlMs: number, nowMs: number): Record<string, number> {
  const out: Record<string, number> = {};
  for (let m = 0; m < maps.length; m++) {
    const map: Record<string, number> = maps[m];
    const ids: string[] = Object.keys(map);
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const t: number = map[id];
      if (typeof t !== 'number' || !Number.isFinite(t) || t <= 0) {
        continue;
      }
      if (nowMs - t > ttlMs) {
        continue;
      }
      const cur: number | undefined = out[id];
      if (cur === undefined || t < cur) {
        out[id] = t;
      }
    }
  }
  return out;
}

/**
 * 解析云端歌单快照文件（playlists/{id}.json）→ 校验过的 Playlist；坏文件返回 null。
 *
 * 与 importPlaylistsFromParsed 的三点刻意差异（方案 §5.1，云恢复不能走它的原因）：
 *   · 不改重名（重名加「导入」后缀会让每次同步多长一份）；
 *   · 不重盖 updatedAt（否则所有歌单都变「刚改过」，LWW 判定彻底失真）；
 *   · 不重盖 addedAt（曲目「谁先加的」顺序依据必须跨设备保真）。
 * 曲目逐首 slimTrack + 清 localFilePath（来源设备的本机路径无效且误导）。
 */
export function parseCloudPlaylist(raw: string): Playlist | null {
  let parsed: Playlist;
  try {
    parsed = JSON.parse(raw) as Playlist;
  } catch (e) {
    return null;
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object'
    || typeof parsed.id !== 'string' || parsed.id.length === 0
    || typeof parsed.name !== 'string' || parsed.name.length === 0
    || !Array.isArray(parsed.tracks)) {
    return null;
  }
  const tracks: Track[] = [];
  for (let i = 0; i < parsed.tracks.length; i++) {
    const t: Track = parsed.tracks[i];
    if (t === null || t === undefined || typeof t !== 'object'
      || typeof t.id !== 'string' || t.id.length === 0) {
      continue;
    }
    // slimTrack 统一字段（audioUrl 置空，签名直链过期无用）；
    // addedAt 透传（slimTrack 本就保留，不重盖 —— 云端带来的真实加入时间可信）
    tracks.push({
      ...slimTrack(t),
      localFilePath: ''
    });
  }
  return {
    id: parsed.id,
    name: parsed.name,
    description: typeof parsed.description === 'string' ? parsed.description : '',
    coverUrl: typeof parsed.coverUrl === 'string' ? parsed.coverUrl : '',
    createdAt: typeof parsed.createdAt === 'string' ? parsed.createdAt : '',
    updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : '',
    upMid: typeof parsed.upMid === 'string' ? parsed.upMid : '',
    upName: typeof parsed.upName === 'string' ? parsed.upName : '',
    sourceKind: typeof parsed.sourceKind === 'string' ? parsed.sourceKind : '',
    titleSorted: parsed.titleSorted === true,
    tracks: tracks
  };
}

/**
 * 解析云端索引文件（playlist-index.json）条目；坏文件返回 null。
 * 索引是提交点（方案 §3）：hash 用于读取端差量判定，trackCount 供展示。
 */
export interface CloudPlaylistIndexEntry {
  rev: string;
  updatedAt: string;
  hash: string;
  trackCount: number;
}

export function parseCloudIndex(raw: string): Record<string, CloudPlaylistIndexEntry> | null {
  let parsed: Record<string, CloudPlaylistIndexEntry>;
  try {
    parsed = JSON.parse(raw) as Record<string, CloudPlaylistIndexEntry>;
  } catch (e) {
    return null;
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
    return null;
  }
  return parsed;
}

/**
 * 解析云端设备元信息（meta.json）；坏文件返回 null。
 */
export interface CloudDeviceMeta {
  deviceName: string;
  appVersion: string;
  /** 最后一次写回自己目录的 ms 时间戳 */
  lastWriteAt: number;
  /** 云端存在的月份分片（YYYY-MM，按 meta 就能列出会话文件） */
  sessionMonths: string[];
}

export function parseCloudMeta(raw: string): CloudDeviceMeta | null {
  let parsed: CloudDeviceMeta;
  try {
    parsed = JSON.parse(raw) as CloudDeviceMeta;
  } catch (e) {
    return null;
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object'
    || typeof parsed.deviceName !== 'string') {
    return null;
  }
  const months: string[] = Array.isArray(parsed.sessionMonths) ? parsed.sessionMonths : [];
  return {
    deviceName: parsed.deviceName,
    appVersion: typeof parsed.appVersion === 'string' ? parsed.appVersion : '',
    lastWriteAt: typeof parsed.lastWriteAt === 'number' ? parsed.lastWriteAt : 0,
    sessionMonths: months.filter((m: string): boolean => typeof m === 'string')
  };
}

/* ------------------------------------------------------------------ *
 * 最近播放（recent.json）—— 逐条 LWW，不是整表 LWW
 *
 * 与歌单的根本差异：歌单是「一个集合，谁改谁赢」，最近播放是「每条记录
 * 各自带着自己的时间戳」，因此合并粒度是**单条曲目**：
 *   · 同一首在两台设备都播过 → 取 playedAt 更大的那份（连 lastPosSec 一起取，
 *     「最后一次听」的位置比「更早那次听到哪」有意义）；
 *   · 删除要能跨设备传播，否则「我删了它又回来了」—— 用 per-id 墓碑
 *     （deleted[id] >= playedAt 才算删，删完又听了就保留）；
 *   · 「清空」用 clearedAt 一个数表达：playedAt <= clearedAt 的一律丢弃，
 *     比给 200 条逐条写墓碑省一个数量级。
 * ------------------------------------------------------------------ */

/** 云端最近播放文件（每设备一份 recent.json） */
export interface CloudRecentPayload {
  /** 本机「清空最近播放」的时刻（0 = 没清空过） */
  clearedAt: number;
  tracks: Track[];
  /** 本机删过的条目：id → 删除时刻（ms） */
  deleted: Record<string, number>;
}

/** 合并结果（tracks 为最终列表，deleted / clearedAt 供回写本地状态） */
export interface RecentMergeResult {
  tracks: Track[];
  deleted: Record<string, number>;
  clearedAt: number;
}

/**
 * 解析云端最近播放文件；坏文件返回 null。
 * 曲目逐条 slimTrack + 清 localFilePath（来源设备的本机路径无效）。
 */
export function parseCloudRecent(raw: string): CloudRecentPayload | null {
  let parsed: CloudRecentPayload;
  try {
    parsed = JSON.parse(raw) as CloudRecentPayload;
  } catch (e) {
    return null;
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
    return null;
  }
  const tracks: Track[] = [];
  const rawTracks: Track[] = Array.isArray(parsed.tracks) ? parsed.tracks : [];
  for (let i = 0; i < rawTracks.length; i++) {
    const t: Track = rawTracks[i];
    if (t === null || t === undefined || typeof t !== 'object'
      || typeof t.id !== 'string' || t.id.length === 0) {
      continue;
    }
    tracks.push({
      ...slimTrack(t),
      localFilePath: ''
    });
  }
  const deleted: Record<string, number> = {};
  const rawDeleted: Record<string, number> = (parsed.deleted !== null && parsed.deleted !== undefined
    && typeof parsed.deleted === 'object') ? parsed.deleted : {};
  const ids: string[] = Object.keys(rawDeleted);
  for (let i = 0; i < ids.length; i++) {
    const ts: number = rawDeleted[ids[i]];
    if (typeof ts === 'number' && Number.isFinite(ts) && ts > 0) {
      deleted[ids[i]] = ts;
    }
  }
  return {
    clearedAt: typeof parsed.clearedAt === 'number' && Number.isFinite(parsed.clearedAt)
      ? parsed.clearedAt : 0,
    tracks: tracks,
    deleted: deleted
  };
}

/**
 * 合并本机与各设备的最近播放（纯函数）。
 *
 * @param local 本机当前列表（已含 7 天过滤）
 * @param payloads 各设备（含自己上次写回的那份）的云端快照
 * @param localClearedAt 本机清空时刻
 * @param localDeleted 本机墓碑表
 * @param keepMs 保留窗（与 LibraryStore.RECENT_KEEP_MS 同源）
 * @param maxItems 上限（与 LibraryStore.RECENT_MAX_ITEMS 同源）
 */
export function mergeRecentTracks(local: Track[], payloads: CloudRecentPayload[],
  localClearedAt: number, localDeleted: Record<string, number>,
  keepMs: number, maxItems: number, nowMs: number): RecentMergeResult {
  // ① 清空时刻取最大：任何一台设备清空过，比它更早的记录就不该复活
  let clearedAt: number = localClearedAt > 0 ? localClearedAt : 0;
  for (let i = 0; i < payloads.length; i++) {
    const c: number = payloads[i].clearedAt;
    if (c > clearedAt) {
      clearedAt = c;
    }
  }
  // ② 墓碑并集（取最早一次删除即可），过 TTL 的丢弃
  const deleted: Record<string, number> = {};
  const mergeDeleted = (map: Record<string, number>): void => {
    const ids: string[] = Object.keys(map);
    for (let k = 0; k < ids.length; k++) {
      const id: string = ids[k];
      const ts: number = map[id];
      if (typeof ts !== 'number' || !Number.isFinite(ts) || ts <= 0) {
        continue;
      }
      if (nowMs - ts > keepMs) {
        continue;
      }
      const cur: number | undefined = deleted[id];
      if (cur === undefined || ts < cur) {
        deleted[id] = ts;
      }
    }
  };
  mergeDeleted(localDeleted);
  for (let i = 0; i < payloads.length; i++) {
    mergeDeleted(payloads[i].deleted);
  }
  // ③ 逐条 LWW：同 id 取 playedAt 更大的一份
  const byId: Map<string, Track> = new Map<string, Track>();
  const consider = (t: Track): void => {
    if (t === null || t === undefined || typeof t.id !== 'string' || t.id.length === 0) {
      return;
    }
    const cur: Track | undefined = byId.get(t.id);
    if (cur === undefined) {
      byId.set(t.id, t);
      return;
    }
    const a: number = typeof t.playedAt === 'number' ? t.playedAt : 0;
    const b: number = typeof cur.playedAt === 'number' ? cur.playedAt : 0;
    if (a > b) {
      byId.set(t.id, t);
    }
  };
  // 先放本地（同级时本地优先：保住 localFilePath 之外的本地字段语义）
  const localById: Map<string, Track> = new Map<string, Track>();
  for (let i = 0; i < local.length; i++) {
    const t: Track = local[i];
    if (t !== null && t !== undefined && typeof t.id === 'string' && t.id.length > 0) {
      localById.set(t.id, t);
    }
    consider(t);
  }
  for (let i = 0; i < payloads.length; i++) {
    const list: Track[] = payloads[i].tracks;
    for (let k = 0; k < list.length; k++) {
      consider(list[k]);
    }
  }
  // ④ 过滤：清空早于播放的一律丢；删过的（删除时刻 >= 播放时刻）丢；7 天窗口
  const kept: Track[] = [];
  byId.forEach((t: Track): void => {
    const playedAt: number = typeof t.playedAt === 'number' ? t.playedAt : 0;
    // clearedAt 为 0（从未清空）时不做这一步：否则 playedAt=0 的存量记录会被全清
    if (clearedAt > 0 && playedAt <= clearedAt) {
      return;
    }
    const d: number | undefined = deleted[t.id];
    if (d !== undefined && d >= playedAt) {
      return;
    }
    // 与 LibraryStore.isWithinRecentWindow 同口径：playedAt=0 的存量记录保留
    if (playedAt > 0 && nowMs - playedAt >= keepMs) {
      return;
    }
    // 远端版本赢了（playedAt 更新）时，**本机独有字段必须从本地实例回填**：
    //   · localFilePath —— 否则本机已下载的歌在「最近播放」里退化成在线解析，
    //     离线直接播不出来（歌单合并的「本地实例优先」是同一条纪律）；
    //   · isLiked / likedAt —— 本机收藏态才是这台设备上的显示真源，
    //     远端快照里的收藏态可能已经过期。
    const localInst: Track | undefined = localById.get(t.id);
    if (localInst !== undefined) {
      const remotePath: string = typeof t.localFilePath === 'string' ? t.localFilePath : '';
      const localPath: string = typeof localInst.localFilePath === 'string' ? localInst.localFilePath : '';
      if (remotePath.length === 0 && localPath.length > 0) {
        t.localFilePath = localPath;
      }
      t.isLiked = localInst.isLiked;
      t.likedAt = localInst.likedAt;
    }
    kept.push(t);
  });
  kept.sort((a: Track, b: Track): number => {
    const pa: number = typeof a.playedAt === 'number' ? a.playedAt : 0;
    const pb: number = typeof b.playedAt === 'number' ? b.playedAt : 0;
    return pb - pa;
  });
  return {
    tracks: kept.slice(0, maxItems),
    deleted: deleted,
    clearedAt: clearedAt
  };
}

/**
 * 解析云端墓碑表（tombstones.json，{playlistId: deletedAtMs}）；坏文件返回 null。
 */
export function parseCloudTombstones(raw: string): Record<string, number> | null {
  let parsed: Record<string, number>;
  try {
    parsed = JSON.parse(raw) as Record<string, number>;
  } catch (e) {
    return null;
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
    return null;
  }
  return parsed;
}
