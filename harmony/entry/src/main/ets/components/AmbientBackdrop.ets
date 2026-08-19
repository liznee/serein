/** Low-contrast visual depth for otherwise empty full-page states. */
@Component
export struct AmbientBackdrop {
  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor('#0B0E12')

      Circle({ width: 440, height: 440 })
        .fill('rgba(217,119,87,0.055)')
        .align(Alignment.TopEnd)
        .translate({ x: 148, y: -126 })
      Circle({ width: 288, height: 288 })
        .fill('rgba(217,119,87,0.032)')
        .align(Alignment.TopEnd)
        .translate({ x: 92, y: -52 })
      Circle({ width: 350, height: 350 })
        .fill('rgba(107,74,95,0.050)')
        .align(Alignment.BottomStart)
        .translate({ x: -162, y: 150 })
      Circle({ width: 170, height: 170 })
        .fill('rgba(217,119,87,0.026)')
        .align(Alignment.BottomStart)
        .translate({ x: -50, y: 66 })

      Row() {
        Circle({ width: 4, height: 4 }).fill('rgba(217,119,87,0.30)')
        Column().width(42).height(1).backgroundColor('rgba(217,119,87,0.15)')
        Circle({ width: 4, height: 4 }).fill('rgba(217,119,87,0.18)')
        Column().width(30).height(1).backgroundColor('rgba(217,119,87,0.10)')
        Circle({ width: 3, height: 3 }).fill('rgba(217,119,87,0.14)')
      }
      .align(Alignment.BottomEnd)
      .translate({ x: -28, y: -44 })
      .opacity(0.65)
    }
    .width('100%').height('100%').clip(true).enabled(false)
  }
}
