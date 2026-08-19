import { COLOR, TYPO, SPACE } from '../utils/DesignTokens'

/** 空状态组件 — 暗色主题下品牌化空状态 */
@Component
export struct EmptyState {
  @Prop message: string = '暂无数据'
  @State pulseScale: number = 1.0
  private pulseTimer: number = -1

  aboutToAppear(): void {
    // subtle 脉动动画（scale 1→1.03，2s 循环）
    this.pulseTimer = setInterval(() => {
      animateTo({ duration: 1000, curve: Curve.EaseInOut }, () => {
        this.pulseScale = this.pulseScale === 1.0 ? 1.03 : 1.0
      })
    }, 2000)
  }

  aboutToDisappear(): void {
    if (this.pulseTimer !== -1) {
      clearInterval(this.pulseTimer)
      this.pulseTimer = -1
    }
  }

  build() {
    Column() {
      Image($r('app.media.logo'))
        .width(32).height(32)
        .borderRadius(8)
        .opacity(0.12)
        .scale({ x: this.pulseScale, y: this.pulseScale })
        .animation({ duration: 1000, curve: Curve.EaseInOut })
        .margin({ bottom: SPACE.lg })

      Text(this.message)
        .fontSize(TYPO.body.size)
        .fontColor(COLOR.textSecondary)
    }
    .width('100%')
    .padding({ top: SPACE.xxxxl, bottom: SPACE.xxxxl })
    .alignItems(HorizontalAlign.Center)
  }
}
