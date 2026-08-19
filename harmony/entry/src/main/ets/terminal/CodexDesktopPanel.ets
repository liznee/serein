import type { CodexDesktopThread } from '../model/CodexDesktopStore'
import { desktopThreadCommand } from '../model/CodexDesktopStore'

/**
 * 当前项目的 Codex 桌面会话选择器。
 *
 * 这里只负责选择会话；选中后立即进入完整 Terminal 页面。Thread ID、租约、
 * 续租等协议细节不展示给用户。
 */
@Component
export struct CodexDesktopPanel {
  @Prop threads: CodexDesktopThread[] = []
  @Prop projectName: string = ''
  @Prop loading: boolean = false
  @Prop error: string = ''
  onCommand?: (command: string) => void
  onRefresh?: () => void
  onClose?: () => void
  private openingThreadId: string = ''

  private send(command: string): void {
    if (this.onCommand) this.onCommand(command)
  }

  private openThread(thread: CodexDesktopThread): void {
    if (thread.id === '' || this.openingThreadId !== '') return
    this.openingThreadId = thread.id
    // Selection is a local UI action: dismiss the chooser immediately and let
    // Terminal show the short connection state while the relay resumes the
    // thread. Do not hold the panel open for a network round trip.
    if (this.onClose) this.onClose()
    this.send(desktopThreadCommand('take', thread.id))
  }

  private statusText(thread: CodexDesktopThread): string {
    const raw = typeof thread.status === 'string' ? thread.status.toLowerCase() : ''
    if (raw.indexOf('progress') >= 0 || raw.indexOf('active') >= 0) return '运行中'
    if (raw.indexOf('interrupt') >= 0) return '已中断'
    if (raw.indexOf('fail') >= 0) return '失败'
    return '可继续'
  }

  private updatedText(timestamp: number): string {
    if (timestamp <= 0) return ''
    const value = timestamp < 100000000000 ? timestamp * 1000 : timestamp
    const date = new Date(value)
    const month = this.twoDigits(date.getMonth() + 1)
    const day = this.twoDigits(date.getDate())
    const hour = this.twoDigits(date.getHours())
    const minute = this.twoDigits(date.getMinutes())
    return month + '-' + day + ' ' + hour + ':' + minute
  }

  private twoDigits(value: number): string {
    return value < 10 ? '0' + value : '' + value
  }

  /**
   * Keep short session lists compact while retaining the previous maximum
   * viewport for larger lists. The Scroll below takes over after five cards.
   */
  private panelHeight(): number {
    if ((this.loading && this.threads.length === 0) || this.error !== '' || this.threads.length === 0) return 300
    const visibleCards = Math.min(this.threads.length, 5)
    return Math.min(650, 122 + visibleCards * 106)
  }

  @Builder
  private threadRow(thread: CodexDesktopThread): void {
    Column() {
      Row() {
        Text(thread.title !== '' ? thread.title : '未命名会话')
          .fontSize(14).fontWeight(600).fontColor('#E8E3DF')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.statusText(thread))
          .fontSize(9).fontWeight(600).fontColor('#C99684')
          .padding({ left: 7, right: 7, top: 4, bottom: 4 })
          .backgroundColor('rgba(217,119,87,0.09)').borderRadius(9999)
          .margin({ left: 10 })
      }.width('100%').alignItems(VerticalAlign.Top)

      Row() {
        Text(thread.turns > 0 ? thread.turns + ' 轮对话' : '新会话')
          .fontSize(10).fontColor('#858A96')
        if (this.updatedText(thread.updatedAt) !== '') {
          Text('·').fontSize(10).fontColor('#555B66').margin({ left: 6, right: 6 })
          Text(this.updatedText(thread.updatedAt)).fontSize(10).fontColor('#858A96')
        }
        Blank()
        Text('打开')
          .fontSize(11).fontWeight(650).fontColor('#F1DCD4')
          .padding({ left: 13, right: 13, top: 8, bottom: 8 })
          .backgroundColor('rgba(217,119,87,0.18)').borderRadius(9)
          .onClick(() => { this.openThread(thread) })
      }.width('100%').alignItems(VerticalAlign.Center).margin({ top: 12 })
    }
    .width('100%').padding(14).margin({ bottom: 10 })
    .backgroundColor('rgba(29,32,36,0.78)').borderRadius(13)
    .border({ width: 1, color: 'rgba(217,119,87,0.14)' })
    .onClick(() => { this.openThread(thread) })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('选择桌面会话').fontSize(18).fontWeight(700).fontColor('#F0EBE7')
          Text(this.projectName + ' · 仅显示当前项目')
            .fontSize(10).fontColor('#777C8A').margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('刷新').fontSize(10).fontWeight(650).fontColor('#D99A83')
          .padding({ left: 11, right: 11, top: 8, bottom: 8 })
          .backgroundColor('rgba(217,119,87,0.10)').borderRadius(8)
          .onClick(() => {
            if (this.onRefresh) this.onRefresh()
            else this.send('/desktop list')
          })
        Text('×').fontSize(24).fontColor('#A9ACB7').margin({ left: 14 })
          .onClick(() => { if (this.onClose) this.onClose() })
      }.width('100%').padding({ left: 18, right: 18, top: 16, bottom: 13 })

      Scroll() {
        Column() {
          if (this.threads.length > 0) {
            ForEach(this.threads, (thread: CodexDesktopThread) => {
              this.threadRow(thread)
            }, (thread: CodexDesktopThread) => thread.id)
          } else if (this.loading) {
            Column() {
              LoadingProgress()
                .width(30).height(30).color('#D97757')
              Text('正在读取 ' + this.projectName + ' 的桌面会话…')
                .fontSize(12).fontColor('#9A9EAA').margin({ top: 14 })
            }.width('100%').padding({ top: 52, bottom: 52 })
          } else if (this.error !== '') {
            Column() {
              Text('会话读取失败')
                .fontSize(13).fontWeight(600).fontColor('#C8C1BD')
              Text(this.error)
                .fontSize(10).fontColor('#777C8A').textAlign(TextAlign.Center)
                .lineHeight(17).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 8 })
              Text('重新加载')
                .fontSize(11).fontWeight(650).fontColor('#F1DCD4')
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor('rgba(217,119,87,0.16)').borderRadius(9)
                .margin({ top: 16 })
                .onClick(() => { if (this.onRefresh) this.onRefresh() })
            }.width('100%').padding({ top: 44, bottom: 44, left: 24, right: 24 })
          } else if (this.threads.length === 0) {
            Column() {
              Text('这个项目还没有可继续的桌面会话')
                .fontSize(13).fontWeight(550).fontColor('#B8BBC4')
                .textAlign(TextAlign.Center)
              Text('可以先在 Codex 电脑端为该项目创建一条会话，然后点击刷新。')
                .fontSize(11).fontColor('#777C8A').textAlign(TextAlign.Center)
                .lineHeight(18).margin({ top: 8 })
            }.width('100%').padding({ top: 46, bottom: 46, left: 24, right: 24 })
          }
        }.width('100%').padding({ left: 18, right: 18, bottom: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto)
    }
    .width('100%').height(this.panelHeight()).position({ x: 0, y: 42 })
    .backgroundColor('#111419').borderRadius(18)
    .border({ width: 1, color: 'rgba(217,119,87,0.22)' })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.45)', offsetY: 8 })
    .transition(TransitionEffect.scale({ x: 0.94, y: 0.92 })
      .combine(TransitionEffect.translate({ y: -12 }))
      .combine(TransitionEffect.OPACITY)
      .animation({ duration: 240, curve: Curve.FastOutSlowIn }))
  }
}
