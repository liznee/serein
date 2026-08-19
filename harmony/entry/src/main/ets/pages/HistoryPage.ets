import { router } from '@kit.ArkUI'
import type { ApprovalRecord } from '../api/types'
import ApprovalApi from '../api/ApprovalApi'
import { ApprovalCard } from '../components/ApprovalCard'
import { EmptyState } from '../components/EmptyState'
import NavPath from '../model/NavPath'
import { isApiError } from '../api/HttpClient'
import type { ApiError } from '../api/HttpClient'
import { handleAuthError } from '../state/AppStore'
import { COLOR, TYPO, SPACE, TOUCH, RADIUS, ICON, HEADER_HEIGHT, WEIGHT, SURFACE } from '../utils/DesignTokens'
import { Icons } from '../utils/Icons'
import { ActionIcon, ActionIconType } from '../components/ActionIcon'

const PAGE_SIZE = 30

interface TabItem {
  label: string
  status: string
}

const TABS: TabItem[] = [
  { label: '全部', status: '' },
  { label: '已同意', status: 'allow' },
  { label: '已拒绝', status: 'deny' },
  { label: '已超时', status: 'timeout' }
]

/** 审批历史页 — 遵循 ui-ux-pro-max: 语义颜色、触摸目标、统一间距节奏、错误反馈 */
@Entry
@Component
struct HistoryPage {
  @State items: ApprovalRecord[] = []
  @State loading: boolean = false
  @State loadingMore: boolean = false
  @State errorMsg: string = ''
  @State activeTab: number = 0
  @State total: number = 0
  @State loadMoreFailed: boolean = false
  private pageOffset: number = 0
  private hasMore: boolean = true
  private project: string = 'default'

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>
    if (params && params['project'] !== undefined) {
      this.project = params['project'] as string
    }
    this.loadFirstPage()
  }

  handleTabChange(index: number): void {
    this.activeTab = index
    this.items = []
    this.pageOffset = 0
    this.hasMore = true
    this.loadMoreFailed = false
    this.loadFirstPage()
  }

  async loadFirstPage(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const status = TABS[this.activeTab].status
    // 注意: 新版服务器 pending 查询已自动过滤超时审批
    // 旧版服务器需客户端配合过滤
    try {
      const resp = await ApprovalApi.list(status, PAGE_SIZE, 0, this.project)
      let rawItems = resp.items ?? []
      // "全部" tab: 排除 pending（仅展示已决定的审批）
      if (status === '') {
        rawItems = rawItems.filter((item: ApprovalRecord) => item.decision !== 'pending')
      }
      this.items = rawItems
      this.total = resp.total
      this.pageOffset = rawItems.length
      this.hasMore = this.pageOffset < (resp.total)
      this.loadMoreFailed = false
    } catch (err) {
      if (isApiError(err)) {
        const apiErr = err as ApiError
        if (apiErr.status === 401) {
          handleAuthError()
          router.replaceUrl({ url: NavPath.PAIR })
          return
        }
        this.errorMsg = apiErr.message ?? '加载失败'
      } else {
        this.errorMsg = '加载失败'
      }
    } finally {
      this.loading = false
    }
  }

  async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.loading) {
      return
    }
    this.loadingMore = true
    const status = TABS[this.activeTab].status
    try {
      const resp = await ApprovalApi.list(status, PAGE_SIZE, this.pageOffset, this.project)
      const newItems = resp.items ?? []
      this.items = this.items.concat(newItems)
      this.pageOffset = this.pageOffset + newItems.length
      this.total = resp.total
      this.hasMore = this.pageOffset < this.total
      this.loadMoreFailed = false
    } catch (err) {
      // 加载更多失败：阻止死循环，显示可点击重试
      this.loadMoreFailed = true
      console.error('HistoryPage.loadMore 失败: ' + JSON.stringify(err))
    } finally {
      this.loadingMore = false
    }
  }

  handleTapCard(record: ApprovalRecord): void {
    router.pushUrl({ url: NavPath.DETAIL, params: { id: record.id } })
  }

  handleBack(): void {
    router.back()
  }

  /** 清空非 pending 的历史审批记录 */
  async handleClearHistory(): Promise<void> {
    try {
      const res = await ApprovalApi.clearHistory()
      console.info('clearHistory deleted: ' + res.deleted)
      // 刷新当前列表
      this.pageOffset = 0
      this.hasMore = true
      this.loadFirstPage()
    } catch (err) {
      console.error('clearHistory failed: ' + (err as Error).message)
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Row() { Text('<').fontSize(24).fontColor('#D97757').fontFamily('monospace') }.width(36).height(36).borderRadius(18).backgroundColor('rgba(217,119,87,0.08)').justifyContent(FlexAlign.Center).onClick(()=>{this.handleBack()})
        Blank()
        Text('History').fontSize(22).fontWeight(700).fontColor('#D97757').fontFamily('monospace')
        Blank()
        Row().width(36)
      }
      .width('100%').padding({left:16,right:16,top:44,bottom:12})

      // Tab 栏 — 触摸目标 ≥44pt
      Row() {
        ForEach(TABS, (tab: TabItem, index: number) => {
          Text(tab.label)
            .fontSize(TYPO.bodySmall.size)
            .height(TOUCH.min)
            .fontWeight(this.activeTab === index ? WEIGHT.bold : WEIGHT.regular)
            .fontColor(this.activeTab === index ? COLOR.primary : COLOR.textSecondary)
            .padding({ left: SPACE.md, right: SPACE.md })
            .border({
              width: { bottom: this.activeTab === index ? 2 : 0 },
              color: this.activeTab === index ? COLOR.primary : Color.Transparent
            })
            .onClick(() => {
              this.handleTabChange(index)
            })
        })
      }
      .width('100%')
      .padding({ left: SPACE.sm })
      .backgroundColor(COLOR.background)
      .border({ width: { bottom: 1 }, color: COLOR.divider })

      // 内容区 — Swiper 左右滑动切换Tab
      Swiper() {
        ForEach(TABS, (tab: TabItem, index: number) => {
          Column() {
            if (this.loading) {
              LoadingProgress()
                .width(36).height(36).margin({ top: SPACE.xxxxl })
            } else if (this.errorMsg !== '') {
              Column() {
                Text(this.errorMsg)
                  .fontSize(TYPO.body.size).fontColor(COLOR.danger).margin({ bottom: SPACE.md })
                Button('重试')
                  .fontSize(TYPO.body.size).height(TOUCH.button)
                  .fontColor(COLOR.primary).backgroundColor(COLOR.primaryContainer)
                  .borderRadius(RADIUS.md)
                  .onClick(() => { this.loadFirstPage() })
              }
              .width('100%').margin({ top: SPACE.xxxxl }).alignItems(HorizontalAlign.Center)
            } else if (this.items.length === 0) {
              EmptyState({
                message: index === 0 ? '暂无审批记录' : '暂无此类记录'
              })
            } else {
              List() {
                ForEach(this.items, (item: ApprovalRecord) => {
                  ListItem() {
                    ApprovalCard({
                      record: item, showActions: false,
                      onTap: () => { this.handleTapCard(item) }
                    })
                  }
                  .margin({ bottom: SPACE.md })
                }, (item: ApprovalRecord) => item.id)

                ListItem() {
                  Row() {
                    if (this.loadingMore) {
                      LoadingProgress().width(20).height(20)
                      Text('加载中…').fontSize(TYPO.caption.size).fontColor(COLOR.textTertiary).margin({ left: SPACE.sm })
                    } else if (this.hasMore) {
                      Text('上拉加载更多').fontSize(TYPO.caption.size).fontColor(COLOR.textTertiary)
                    } else if (this.loadMoreFailed) {
                      Text('加载失败，点击重试').fontSize(TYPO.caption.size).fontColor(COLOR.danger).onClick(() => { this.loadMore() })
                    } else if (!this.hasMore && this.items.length > 0) {
                      Text(Icons.EMPTY + ' 共 ' + this.total + ' 条 ' + Icons.EMPTY).fontSize(TYPO.caption.size).fontColor(COLOR.textTertiary)
                    }
                  }
                  .width('100%').justifyContent(FlexAlign.Center).padding({ top: SPACE.md, bottom: SPACE.xxl })
                }
              }
              .width('100%').layoutWeight(1)
              .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.sm })
              .backgroundColor(COLOR.background).divider({ strokeWidth: 0 })
              .onReachEnd(() => { this.loadMore() })
            }
          }
          .width('100%').height('100%')
        }, (tab: TabItem) => tab.label)
      }
      .index(this.activeTab)
      .loop(false)
      .width('100%')
      .layoutWeight(1)
      .onChange((idx: number) => {
        this.handleTabChange(idx)
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR.background)
  }
}
