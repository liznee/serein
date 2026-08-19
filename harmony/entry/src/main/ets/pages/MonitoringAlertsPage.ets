import { router } from '@kit.ArkUI'
import MonitoringAlertApi from '../api/MonitoringAlertApi'
import type { MonitoringAlertRecord } from '../api/types'
import { isApiError } from '../api/HttpClient'
import type { ApiError } from '../api/HttpClient'
import { handleAuthError } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { COLOR, RADIUS, SPACE, TOUCH, TYPO, WEIGHT } from '../utils/DesignTokens'

type AlertTab = '' | 'active' | 'resolved'

@Entry
@Component
struct MonitoringAlertsPage {
  @State items: MonitoringAlertRecord[] = []
  @State loading: boolean = true
  @State refreshing: boolean = false
  @State errorMsg: string = ''
  @State activeAlertCount: number = 0
  @State activeTab: AlertTab = 'active'

  aboutToAppear(): void { this.load() }

  private formatTime(raw: string | undefined): string {
    if (raw === undefined || raw === '') return '--'
    const d = new Date(raw)
    if (Number.isNaN(d.getTime())) return raw.replace('T', ' ').substring(0, 16)
    const pad = (n: number): string => n < 10 ? '0' + n : '' + n
    return pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes())
  }

  private stateLabel(item: MonitoringAlertRecord): string {
    return item.state === 'active' ? '进行中' : '已恢复'
  }

  private stateColor(item: MonitoringAlertRecord): string {
    if (item.state === 'resolved') return '#8C909F'
    return item.level === 'critical' ? '#D97757' : '#D99A83'
  }

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    try {
      const list = await MonitoringAlertApi.list(this.activeTab, 50, 0)
      const summary = await MonitoringAlertApi.summary()
      this.items = list.items ?? []
      this.activeAlertCount = summary.active
    } catch (err) {
      if (isApiError(err) && (err as ApiError).status === 401) {
        handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }); return
      }
      this.errorMsg = isApiError(err) ? (err as ApiError).message : '告警记录加载失败'
    } finally {
      this.loading = false
      this.refreshing = false
    }
  }

  private selectTab(tab: AlertTab): void {
    if (this.activeTab === tab) return
    this.activeTab = tab
    this.load()
  }

  @Builder
  private tab(label: string, tab: AlertTab): void {
    Text(label)
      .fontSize(TYPO.bodySmall.size).fontWeight(this.activeTab === tab ? WEIGHT.bold : WEIGHT.regular)
      .fontColor(this.activeTab === tab ? '#F0E5C7' : '#8C909F')
      .height(36).padding({ left: SPACE.md, right: SPACE.md })
      .backgroundColor(this.activeTab === tab ? 'rgba(217,119,87,0.20)' : 'transparent')
      .borderRadius(RADIUS.full)
      .onClick(() => { this.selectTab(tab) })
  }

  @Builder
  private alertRow(item: MonitoringAlertRecord): void {
    Column() {
      Row() {
        Column() {
          Text(item.title).fontSize(TYPO.body.size).fontWeight(WEIGHT.semibold).fontColor('#F0E5C7')
          Text(item.message).fontSize(TYPO.caption.size).fontColor('#C2C6D6').margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.stateLabel(item)).fontSize(TYPO.caption.size).fontWeight(WEIGHT.semibold)
          .fontColor(this.stateColor(item)).padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('rgba(217,119,87,0.10)').borderRadius(RADIUS.full)
      }.width('100%').alignItems(VerticalAlign.Top)
      Row() {
        Text('触发 ' + this.formatTime(item.created_at)).fontSize(10).fontColor('#6E7380')
        Blank()
        Text(item.state === 'resolved' ? '恢复 ' + this.formatTime(item.resolved_at) : '最近 ' + this.formatTime(item.last_seen_at))
          .fontSize(10).fontColor('#6E7380')
      }.width('100%').margin({ top: SPACE.sm })
    }
    .width('100%').padding(SPACE.md)
    .backgroundColor('#161B22').border({ width: 1, color: 'rgba(217,119,87,0.18)' }).borderRadius(RADIUS.md)
  }

  build() {
    Column() {
      Row() {
        Text('<').fontSize(24).fontColor('#D97757').width(40).height(40).textAlign(TextAlign.Center)
          .padding({ top: 5 }).backgroundColor('rgba(217,119,87,0.08)').borderRadius(RADIUS.full)
          .onClick(() => { router.back() })
        Column() {
          Text('监控告警').fontSize(22).fontWeight(WEIGHT.bold).fontColor('#F0E5C7')
          Text(this.activeAlertCount > 0 ? this.activeAlertCount + ' 项需要关注' : '当前没有活动告警')
            .fontSize(TYPO.caption.size).fontColor(this.activeAlertCount > 0 ? '#D99A83' : '#8C909F').margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).margin({ left: SPACE.md }).layoutWeight(1)
      }.width('100%').padding({ left: SPACE.md, right: SPACE.md, top: 48, bottom: SPACE.md })

      Row() {
        this.tab('进行中', 'active')
        this.tab('全部', '')
        this.tab('已恢复', 'resolved')
      }.width('100%').padding({ left: SPACE.md, right: SPACE.md, bottom: SPACE.sm })

      if (this.loading) {
        Column() { LoadingProgress().width(34).height(34).color('#D97757') }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.errorMsg !== '') {
        Column() {
          Text(this.errorMsg).fontSize(TYPO.body.size).fontColor('#D99A83')
          Button('重试').fontSize(TYPO.bodySmall.size).fontColor('#F0E5C7').backgroundColor('rgba(217,119,87,0.18)').borderRadius(RADIUS.sm)
            .margin({ top: SPACE.md }).onClick(() => { this.load() })
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            if (this.items.length === 0) {
              ListItem() {
                Column() {
                  Text('暂无监控告警').fontSize(TYPO.body.size).fontColor('#C2C6D6')
                  Text('资源异常恢复后会保留在这里').fontSize(TYPO.caption.size).fontColor('#6E7380').margin({ top: SPACE.sm })
                }.width('100%').padding({ top: 64 }).alignItems(HorizontalAlign.Center)
              }
            } else {
              ForEach(this.items, (item: MonitoringAlertRecord) => {
                ListItem() { this.alertRow(item) }.margin({ bottom: SPACE.sm })
              }, (item: MonitoringAlertRecord) => item.id)
            }
          }.width('100%').layoutWeight(1).padding({ left: SPACE.md, right: SPACE.md, top: SPACE.sm })
        }
        .width('100%').layoutWeight(1)
        .onRefreshing(() => { this.refreshing = true; this.load() })
      }
    }
    .width('100%').height('100%').backgroundColor(COLOR.background)
  }
}
