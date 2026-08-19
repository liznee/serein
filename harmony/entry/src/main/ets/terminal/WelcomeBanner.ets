/**
 * WelcomeBanner — 终端页面启动横幅组件
 *
 * 从 TerminalPage.TerminalContent 提取 @Builder 为独立 @Component，
 * 减少 TerminalPage.ets 行数。使用 @Prop 接收项目路径。
 *
 * 颜色层级（UI优化）:
 *   标题 "Serein" → text (白色) — 主信息
 *   项目路径 → textDim (灰色) — 次要信息
 *   "Tips" 标签 → accent (terracotta) — 强调
 *   命令列表 → textDim (灰色) — 参考
 */
import { currentTheme } from './TerminalTheme'

@Component
export struct WelcomeBanner {
  @Prop projectPath: string = ''

  build() {
    Row() {
      // ====== 左栏：App 图标 + 版本 ======
      Column() {
        Image($r('app.media.logo'))
          .width(40).height(40)
          .borderRadius(8)
          .margin({ bottom: 4 })
        Text('Serein')
          .fontSize(11).fontColor(currentTheme().text).fontFamily('monospace').fontWeight(700)
        Text(this.projectPath)
          .fontSize(9).fontColor(currentTheme().textDim).fontFamily('monospace').opacity(0.7).margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      // ====== 中间分隔线 ======
      Column()
        .width(1).height(60)
        .backgroundColor(currentTheme().divider)
        .margin({ left: 10, right: 10 })

      // ====== 右栏：tips ======
      Column() {
        Text('Tips')
          .fontSize(11).fontColor(currentTheme().textDim).fontFamily('monospace').fontWeight(700)
        Text('/clear /help /history')
          .fontSize(10).fontColor(currentTheme().accent).fontFamily('monospace').opacity(0.85).margin({ top: 1 })
        Text('/!<cmd> /diff /resume')
          .fontSize(10).fontColor(currentTheme().accent).fontFamily('monospace').opacity(0.85).margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(currentTheme().panel)
    .border({ width: 1, color: 'rgba(217,119,87,0.25)' })
    .borderRadius(8)
    .margin({ bottom: 6 })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.20)', offsetY: 2 })
    .constraintSize({ maxHeight: 110 })
  }
}
