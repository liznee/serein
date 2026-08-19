// ===== 液态玻璃通知弹窗（NotificationPopup） =====
// 遵循 ui-ux-pro-max: 毛玻璃背景 + 弹簧入场动画 + EaseOut 退场
// 用于 App 前台时展示新审批请求，从屏幕顶部滑入

import { router } from '@kit.ArkUI'
import { COLOR, TYPO, SPACE, RADIUS, DUR, CURVES } from '../utils/DesignTokens'
import NavPath from '../model/NavPath'
import type { NotificationItem } from '../model/NotificationQueue'

@Component
export struct NotificationPopup {
  @Prop item: NotificationItem | null = null
  onDismiss: () => void = () => {}

  build() {
    if (this.item !== null) {
      // 半透明遮罩
      Stack() {
        Column() {
          // 毛玻璃弹窗卡片
          Column() {
            // 顶行: 风险等级 + 关闭按钮
            Row() {
              // 风险级别标签
              Text(this.riskLabel(this.item.riskLevel))
                .fontSize(TYPO.caption.size)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.riskColor(this.item.riskLevel))
                .padding({ left: SPACE.sm, right: SPACE.sm, top: 2, bottom: 2 })
                .borderRadius(RADIUS.sm)
                .backgroundColor(this.riskBg(this.item.riskLevel))

              Blank()

              // 关闭按钮
              Row() {
                Text('✕')
                  .fontSize(16)
                  .fontColor('#C2C6D6')
                  .fontWeight(FontWeight.Bold)
              }
              .width(36)
              .height(36)
              .borderRadius(9999)
              .backgroundColor('rgba(217,119,87,0.08)')
              .border({ width: 1, color: 'rgba(217,119,87,0.20)' })
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.onDismiss() })
            }
            .width('100%')

            // 标题
            Text(this.item.title)
              .fontSize(TYPO.bodyLarge.size)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: SPACE.sm })

            // 命令预览（等宽字体，单行截断）
            Text(this.item.command !== '' ? this.item.command : '(无命令内容)')
              .fontSize(TYPO.bodySmall.size)
              .fontColor(COLOR.textSecondary)
              .fontFamily('monospace')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: SPACE.xs })

            // 审批按钮行：拒绝 + 详情 + 允许
            Row() {
              Text('拒绝')
                .fontSize(TYPO.bodySmall.size)
                .fontColor('#b53333')
                .fontWeight(FontWeight.Medium)
                .padding({ left: SPACE.md, right: SPACE.md, top: SPACE.sm, bottom: SPACE.sm })
                .borderRadius(RADIUS.full)
                .backgroundColor('rgba(255,180,171,0.12)')
                .border({ width: 1, color: 'rgba(255,180,171,0.25)' })
                .onClick(() => {
                  if (this.item !== null && this.item.onDeny) { this.item.onDeny() }
                  this.onDismiss()
                })

              Text('详情 ›')
                .fontSize(TYPO.bodySmall.size)
                .fontColor('#C2C6D6')
                .fontWeight(FontWeight.Medium)
                .padding({ left: SPACE.md, right: SPACE.md, top: SPACE.sm, bottom: SPACE.sm })
                .borderRadius(RADIUS.full)
                .backgroundColor('rgba(39,42,47,0.50)')
                .border({ width: 1, color: 'rgba(140,144,159,0.20)' })
                .onClick(() => {
                  this.onDismiss()
                  if (this.item !== null) {
                    router.pushUrl({ url: NavPath.DETAIL, params: { id: this.item.id } })
                  }
                })

              Text('允许')
                .fontSize(TYPO.bodySmall.size)
                .fontColor('#1A1C20')
                .fontWeight(FontWeight.Medium)
                .padding({ left: SPACE.md, right: SPACE.md, top: SPACE.sm, bottom: SPACE.sm })
                .borderRadius(RADIUS.full)
                .backgroundColor(COLOR.primary)
                .onClick(() => {
                  if (this.item !== null && this.item.onAllow) { this.item.onAllow() }
                  this.onDismiss()
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceEvenly)
            .margin({ top: SPACE.md })
          }
          .width('92%')
          .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.md, bottom: SPACE.lg })
          // 烟熏暖黑底色，与全局黑色 + 琥珀色主题保持一致
          .backgroundColor('rgba(23,20,18,0.97)')
          .borderRadius(RADIUS.lg)
          .border({ width: 1, color: 'rgba(217,119,87,0.24)' })
          .shadow({
            radius: 24,
            color: 'rgba(82,42,28,0.32)',
            offsetY: 10
          })
          // 很轻的琥珀顶光，不使用白色液态玻璃高光
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [
              ['rgba(217,119,87,0.10)', 0.0],
              ['rgba(23,20,18,0.0)', 0.34],
              ['rgba(23,20,18,0.0)', 1.0]
            ]
          })
          .margin({ top: 60 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        // 弹簧入场动画
        .transition(
          TransitionEffect.OPACITY
            .animation({ duration: DUR.slow, curve: CURVES.spring })
            .combine(
              TransitionEffect.translate({ y: -60 })
                .animation({ duration: DUR.slow, curve: CURVES.spring })
            )
        )
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  private riskLabel(level: string): string {
    if (level === 'red') return '高危'
    if (level === 'yellow') return '注意'
    return '安全'
  }

  private riskColor(level: string): Resource {
    if (level === 'red') return $r('app.color.risk_red_text')
    if (level === 'yellow') return $r('app.color.risk_yellow_text')
    return $r('app.color.risk_green_text')
  }

  private riskBg(level: string): Resource {
    if (level === 'red') return $r('app.color.risk_red_bg')
    if (level === 'yellow') return $r('app.color.risk_yellow_bg')
    return $r('app.color.risk_green_bg')
  }
}
