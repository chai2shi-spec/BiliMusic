/**
 * 搜索二级页标题栏行（搜索为 'Search' 二级页）。
 *
 * SearchInputBar 是 HdsNavDestination.titleBar 的 stackBuilder 内容
 * （SearchPage 侧承载），整行 56 锁高：
 *   · HDS 默认返回键（"<" 系统样式，位置由 HDS 管理）在行左侧，
 *     行首以定宽 Blank 让出（NAV_BACK_SIZE + NAV_TITLE_GAP，NavTitleRow 同口径）；
 *   · 搜索框与首页入口框（HomePage.SearchEntryRow）同款样式：放大镜 +
 *     占位文案 + 胶囊底（bg_card + 0.5 分隔线描边），内芯换成真输入
 *     TextInput —— 搜索不分「视频 / UP主」两类：一次搜索两类结果并发返回，
 *     UP 主以横滑卡片行展示在视频列表上方（见 SearchPage）；
 *     首页版 44 高，此处缩短为 36 适配 56 高标题栏行；
 *   · defaultFocus(true)：push 进页自动聚焦弹键盘（入口式搜索框的承接），
 *     SearchPage 侧另有延迟 requestFocus 兜底（NavDestination 动态挂载时
 *     defaultFocus 偶发不触发）。
 *
 * · 状态：keyword 是页面与栏共享的双向状态（两侧 @StorageLink，任一侧
 *   写入另一侧即见）。
 * · 动作：经 TabScrollerHolder 静态回调转交页面私有方法（页面 onAppear 注册）。
 *
 * ⚠️ stackBuilder 宿主几何（NavTitleRow 文件头真机解码）：宿主给内容的布局框是
 * 可见容器的上下对称扩边框，必须以 Column(height '100%') + Center 居中锚定，
 * 56vp 行恰好落进 [safeTop, safeTop+56] 可见容器 —— Start/End 锚定都会跑偏。
 */

import { TabScrollerHolder } from '../service/TabScrollerHolder';
import {
  NAV_TITLE_BAR_HEIGHT,
  NAV_H_PADDING,
  NAV_BACK_SIZE,
  NAV_TITLE_GAP
} from '../utils/NavTitleStyle';
import { SearchStateHolder } from '../service/SearchStateHolder';
import { STORE_SEARCH_KEYWORD } from '../common/Constants';

/** 搜索框高（vp）：首页入口框 44 的缩短版，56 高标题栏行内上下各留 10 */
const SEARCH_BOX_HEIGHT_VP: number = 36;
/** 搜索框圆角（vp）：胶囊（高的一半，与首页 44/22 同比例） */
const SEARCH_BOX_RADIUS_VP: number = 18;

/**
 * 搜索行（'Search' 二级页 titleBar 的 stackBuilder，56 锁高）：
 * HDS 返回键让位 + 首页同款胶囊搜索框（真输入 TextInput）。
 * 不设搜索按钮（用户口径「看着多余」）：提交搜索走键盘
 * onSubmit，搜索框不损失任何能力。
 */
@Component
export struct SearchInputBar {
  /** 双向：栏输入 ↔ 页面（点历史词条 / 恢复会话词）。初值取 holder 的会话词，两侧同源不打架 */
  @StorageLink(STORE_SEARCH_KEYWORD) keyword: string = SearchStateHolder.keyword;

  build() {
    // 宿主怪癖必需的中间层：height('100%') 撑满布局框 + Center 居中锚定，
    // 56vp 行恰好落进可见容器（见文件头 ⚠️ 几何解码，NavTitleRow 同款）
    Column() {
      Row() {
        // 让出 HDS 默认返回键区域（44 命中区 + 4 间距）：搜索框左缘与
        // NavTitleRow 标题左缘（16 + 48 = 64vp）同一条竖线
        Blank()
          .width(NAV_BACK_SIZE + NAV_TITLE_GAP)

        // 首页入口框同款胶囊：放大镜 + 真输入框（有词再出 ✕ 一键清空）
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(16)
            .height(16)
            .fontColor([$r('app.color.text_secondary')])
          TextInput({
            text: this.keyword,
            placeholder: '搜索歌曲、歌单、UP主'
          })
            .layoutWeight(1)
            .height(SEARCH_BOX_HEIGHT_VP)
            // 与行内 13fp 设计语言一致（默认 16fp 占位在窄框内会截断）
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .placeholderFont({ size: 13 })
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 0 })
            .enterKeyType(EnterKeyType.Search)
            // push 进页自动聚焦弹键盘（入口式搜索框的承接）；SearchPage 侧
            // 另有延迟 requestFocus 按 id 兜底（动态挂载时 defaultFocus 偶发不触发）
            .defaultFocus(true)
            .id('searchSubPageInput')
            .onSubmit((): void => {
              TabScrollerHolder.searchSubmit();
            })
            .onChange((v: string): void => {
              // 回写 keyword
              this.keyword = v;
              // 清空即回初始页：✕ 或退格删到空 → 页面整体重置
              if (v.length === 0) {
                TabScrollerHolder.searchReset();
              }
            })
          // 有词才出 ✕（PlaylistDetail 搜索框同款）：一键清空回初始页
          if (this.keyword.length > 0) {
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width(24)
            .height(24)
            .onClick((): void => {
              // 程序置空不触发 onChange：reset 必须自己调
              this.keyword = '';
              TabScrollerHolder.searchReset();
            })
          }
        }
        .layoutWeight(1)
        .height(SEARCH_BOX_HEIGHT_VP)
        .borderRadius(SEARCH_BOX_RADIUS_VP)
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 0.5, color: $r('app.color.bg_divider') })
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(NAV_TITLE_BAR_HEIGHT)
      // 水平基线统一 NAV_H_PADDING(16)：搜索行与页面内容同一条左缘
      .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
