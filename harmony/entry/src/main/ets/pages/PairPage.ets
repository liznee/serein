import { router, promptAction } from '@kit.ArkUI'
import PrefStore from '../store/PrefStore'
import { KEY_BACKEND_URL } from '../state/AppStore'
import { COLOR, TYPO, SPACE, TOUCH, RADIUS } from '../utils/DesignTokens'

/**
 * 设备配对页 — 首次使用入口
 * 仅输入后端地址即可进入应用。配对码通过扫码项目 QR 获取（serein 终端生成）。
 */
@Entry
@Component
struct PairPage {
  @State backendUrl: string = ''
  @State loading: boolean = false
  @State errorMsg: string = ''
  @State enterPressed: boolean = false
  @State shakeOffset: number = 0
  private destroyed: boolean = false
  private timers: number[] = []

  aboutToAppear(): void {
    const saved = AppStorage.get<string>(KEY_BACKEND_URL)
    if (saved !== undefined && saved !== '') {
      this.backendUrl = saved
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true
    for (const t of this.timers) {
      clearTimeout(t)
    }
    this.timers = []
  }

  private triggerShake(): void {
    const deltas: number[] = [0, -8, 8, -6, 6, -3, 3, 0]
    for (let i = 0; i < deltas.length; i++) {
      const tid = setTimeout(() => { this.shakeOffset = deltas[i] }, i * 50)
      this.timers.push(tid)
    }
  }

  private normalizeUrl(raw: string): string {
    let result = raw.trim().replace(/\/+$/, '')
    if (!result.startsWith('http://') && !result.startsWith('https://')) {
      result = 'https://' + result
    }
    return result
  }

  async handleEnter(): Promise<void> {
    if (this.backendUrl.trim() === '') {
      this.errorMsg = '请输入后端地址'
      return
    }
    this.loading = true
    this.errorMsg = ''

    const url = this.normalizeUrl(this.backendUrl)
    AppStorage.setOrCreate(KEY_BACKEND_URL, url)

    try {
      await PrefStore.saveBackendUrl(url)
      const tid = setTimeout(() => {
        if (!this.destroyed) {
          router.replaceUrl({ url: 'pages/MainTabs' })
        }
      }, 300)
      this.timers.push(tid)
    } catch (err) {
      this.errorMsg = '保存设置失败，请重试'
      this.triggerShake()
    } finally {
      this.loading = false
    }
  }

  build() {
    Column() {
      // 标题区域
      Row() {
        Image($r('app.media.logo'))
          .width(40).height(40)
          .borderRadius(8)
          .margin({ right: 10 })
        Text('Serein')
          .fontSize(TYPO.display.size)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR.textPrimary)
      }
      .margin({ top: SPACE.xxxxl, bottom: SPACE.xs })

      Text('连接您的审批后端')
        .fontSize(TYPO.body.size)
        .fontColor(COLOR.textSecondary)
        .margin({ bottom: SPACE.xs })

      Text('输入地址后进入应用，扫描电脑端 serein 命令生成的 QR 码即可完成配对')
        .fontSize(TYPO.bodySmall.size)
        .fontColor(COLOR.textTertiary)
        .margin({ bottom: SPACE.xxxl })

      // 后端地址
      Text('后端地址')
        .fontSize(TYPO.bodySmall.size)
        .fontColor(COLOR.textSecondary)
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: SPACE.xs })

      TextInput({ text: this.backendUrl, placeholder: 'https://你的服务器地址' })
        .width('100%')
        .height(TOUCH.input)
        .fontSize(TYPO.body.size)
        .backgroundColor(COLOR.surface)
        .borderRadius(RADIUS.md)
        .onChange((value: string) => {
          this.backendUrl = value
        })
        .margin({ bottom: SPACE.lg })

      // 错误提示
      if (this.errorMsg !== '') {
        Text(this.errorMsg)
          .fontSize(TYPO.bodySmall.size)
          .fontColor(COLOR.danger)
          .padding(SPACE.md)
          .borderRadius(RADIUS.md)
          .backgroundColor(COLOR.dangerContainer)
          .border({ width: 1, color: 'rgba(181,51,51,0.25)' })
          .width('100%')
          .margin({ bottom: SPACE.lg })
          .translate({ x: this.shakeOffset })
          .animation({ duration: 50, curve: Curve.EaseInOut })
      }

      // 进入应用按钮
      Button() {
        if (this.loading) {
          Row() {
            LoadingProgress().width(18).height(18).color(COLOR.textInverse)
            Text('进入中…')
              .fontSize(TYPO.bodyLarge.size)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR.textInverse)
              .margin({ left: SPACE.sm })
          }
        } else {
          Text('进入应用')
            .fontSize(TYPO.bodyLarge.size)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR.textInverse)
        }
      }
      .width('100%')
      .height(TOUCH.button)
      .fontColor(COLOR.textInverse)
      .backgroundColor(COLOR.primary)
      .enabled(!this.loading)
      .borderRadius(RADIUS.md)
      .scale(this.enterPressed ? { x: 0.97, y: 0.97 } : { x: 1, y: 1 })
      .animation({ duration: 100, curve: Curve.EaseOut })
      .shadow(this.enterPressed ? { radius: 8, color: 'rgba(217,119,87,0.25)', offsetX: 0, offsetY: 0 } : { radius: 0, color: 'transparent', offsetX: 0, offsetY: 0 })
      .onClick(() => {
        this.handleEnter()
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) { this.enterPressed = true }
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.enterPressed = false }
      })

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: SPACE.xxl, right: SPACE.xxl })
    .backgroundColor(COLOR.background)
  }
}
