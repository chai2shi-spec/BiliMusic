/**
 * 主题色调色板（8 色：默认粉 + 红橙黄绿青蓝紫）与发布管线。
 *
 * 鸿蒙颜色资源（$r('app.color.*')）不支持运行时替换，主题切换改走
 * AppStorage 发布 hex 字符串 + 组件 @StorageProp 订阅：
 *   发布方（唯一入口 publishThemeColors）：
 *     · EntryAbility 启动（loadContent 前，首帧即正确）；
 *     · 设置页 chooseThemeColor（选色）/ cycleTheme（切深浅模式联动衍生色变体）；
 *     · EntryAbility.onConfigurationUpdate（系统深浅变化，跟随系统模式时生效）。
 *   消费方：组件按需 @StorageProp(STORE_THEME_PRIMARY/DEEP/SURFACE/ON)。
 *
 * 颜色资源文件（各主题 resources 下 element/color.json 的 bili_pink / brand_*）
 * 保留不删：作为 @StorageProp 初始值之外的文档与启动闪屏兜底。
 */

import { ThemeMode } from '../model/MusicModels';
import {
  STORE_THEME_COLOR,
  STORE_THEME_PRIMARY,
  STORE_THEME_DEEP,
  STORE_THEME_SURFACE,
  STORE_THEME_ON
} from './Constants';

/**
 * 单套主题色：主色 + 衍生色（deep / surface 各配浅、深两套值）+ 主色底上的深字色。
 * 取值模式对齐现有粉（bili_pink #FB7299 / brand_deep #C2185B·#FF8BAC /
 * brand_surface #FFF1F5·#33222B / brand_on #3D0018）。
 */
export interface ThemePalette {
  /** 主题 id，持久化到 AppSettings.themeColor；未知 id 回落 pink */
  id: string;
  /** 中文色名（设置页面板与「主题色」行后缀文案） */
  label: string;
  /** 主色（替代 bili_pink，深浅色同值） */
  primary: string;
  /** 深色文字/徽标 —— 浅色模式用（替代 brand_deep 浅色值） */
  deepLight: string;
  /** 深色文字/徽标 —— 深色模式用（替代 brand_deep 深色值） */
  deepDark: string;
  /** 浅色底/封面占位 —— 浅色模式用（替代 brand_surface 浅色值） */
  surfaceLight: string;
  /** 浅色底/封面占位 —— 深色模式用（替代 brand_surface 深色值） */
  surfaceDark: string;
  /** 主色底上的深字色（替代 brand_on） */
  on: string;
}

export const THEME_PALETTES: ThemePalette[] = [
  { id: 'pink', label: '粉', primary: '#FB7299', deepLight: '#C2185B', deepDark: '#FF8BAC', surfaceLight: '#FFF1F5', surfaceDark: '#33222B', on: '#3D0018' },
  { id: 'red', label: '红', primary: '#E5484D', deepLight: '#C62828', deepDark: '#FF8A80', surfaceLight: '#FFF3F3', surfaceDark: '#332020', on: '#3D0006' },
  { id: 'orange', label: '橙', primary: '#F57C00', deepLight: '#C05600', deepDark: '#FFB74D', surfaceLight: '#FFF5EC', surfaceDark: '#33261A', on: '#3D1F00' },
  { id: 'yellow', label: '黄', primary: '#F5A623', deepLight: '#B07C00', deepDark: '#FFD54F', surfaceLight: '#FFF9E6', surfaceDark: '#33301A', on: '#3D2E00' },
  { id: 'green', label: '绿', primary: '#43A047', deepLight: '#2E7D32', deepDark: '#81C995', surfaceLight: '#F0F7F0', surfaceDark: '#1F3320', on: '#00330D' },
  { id: 'cyan', label: '青', primary: '#00A5B5', deepLight: '#00707F', deepDark: '#4DD0E1', surfaceLight: '#EDF8F9', surfaceDark: '#1A2E33', on: '#00303A' },
  { id: 'blue', label: '蓝', primary: '#00AEEC', deepLight: '#00688F', deepDark: '#64C8F0', surfaceLight: '#EDF7FC', surfaceDark: '#1A2733', on: '#002A3D' },
  { id: 'purple', label: '紫', primary: '#8E24AA', deepLight: '#6A1B9A', deepDark: '#CE93D8', surfaceLight: '#F7F0FA', surfaceDark: '#2C1F33', on: '#2E0033' }
];

/** 按 id 取调色板；未知 id 回落粉（THEME_PALETTES[0]） */
function getThemePalette(id: string): ThemePalette {
  const found: ThemePalette | undefined =
    THEME_PALETTES.find((p: ThemePalette): boolean => p.id === id);
  return found ?? THEME_PALETTES[0];
}

/** 按主题 id 取中文色名（设置页文案用），未知 id 回落「粉」 */
export function themeColorLabel(id: string): string {
  return getThemePalette(id).label;
}

/**
 * 应用当前是否按深色渲染：DARK 强制深、LIGHT 强制浅、SYSTEM 跟随系统
 * （sysDark 由调用方读 UIAbilityContext.config.colorMode 传入）。
 */
export function isAppDark(themeMode: ThemeMode, sysDark: boolean): boolean {
  if (themeMode === ThemeMode.DARK) {
    return true;
  }
  if (themeMode === ThemeMode.LIGHT) {
    return false;
  }
  return sysDark;
}

/**
 * 解析并把当前主题色发布到 AppStorage（唯一发布入口）。
 * deep / surface 按入参 appDark 选浅/深变体，组件订阅后无需再关心深浅。
 */
export function publishThemeColors(id: string, appDark: boolean): void {
  const p: ThemePalette = getThemePalette(id);
  AppStorage.setOrCreate(STORE_THEME_COLOR, p.id);
  AppStorage.setOrCreate(STORE_THEME_PRIMARY, p.primary);
  AppStorage.setOrCreate(STORE_THEME_DEEP, appDark ? p.deepDark : p.deepLight);
  AppStorage.setOrCreate(STORE_THEME_SURFACE, appDark ? p.surfaceDark : p.surfaceLight);
  AppStorage.setOrCreate(STORE_THEME_ON, p.on);
}
