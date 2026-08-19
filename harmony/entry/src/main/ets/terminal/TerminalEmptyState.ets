/**
 * TerminalEmptyState — 未选项目时的空状态页面
 *
 * 展示 App 图标 + Serein 名称 + 选择项目提示。
 */
import { currentTheme } from './TerminalTheme'

@Component
export struct TerminalEmptyState {
  build() {
    Column() {
      // App 图标 + Serein 名称
      Column() {
        Image($r('app.media.logo'))
          .width(64).height(64)
          .borderRadius(14)
          .margin({ bottom: 12 })
        Text('Serein')
          .fontSize(22).fontWeight(700)
          .fontColor(currentTheme().accent)
          .fontFamily('monospace')
          .margin({ bottom: 4 })
      }
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 24 })

      // 珊瑚色边框卡片 — 选择项目提示
      Column() {
        Text('请选择一个项目开始对话')
          .fontSize(15)
          .fontColor('#C2C6D6')
          .fontFamily('monospace')
        Text('点击左上角 ☰ 或左右滑动切换')
          .fontSize(12)
          .fontColor('#8C909F')
          .fontFamily('monospace')
          .margin({ top: 6 })
      }
      .padding(24)
      .border({ width: 1, color: 'rgba(217,119,87,0.25)', style: BorderStyle.Dashed })
      .borderRadius(12)
      .backgroundColor('rgba(217,119,87,0.04)')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}
