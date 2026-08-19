import type { RiskLevel } from '../api/types'
import { riskColor, riskBgColor, riskLabel } from '../utils/RiskUtil'
import { TYPO } from '../utils/DesignTokens'

/** 风险等级徽章 — 遵循 ui-ux-pro-max: 颜色+图标双重编码 */
@Component
export struct RiskBadge {
  @Prop level: RiskLevel = 'green'

  build() {
    Row() {
      // 圆点（颜色+形状双重编码）
      Circle({ width: 7, height: 7 })
        .fill(riskColor(this.level))

      Text(riskLabel(this.level))
        .fontSize(TYPO.caption.size)
        .fontWeight(FontWeight.Medium)
        .fontColor(riskColor(this.level))
        .margin({ left: 4 })
    }
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .borderRadius(4)
    .backgroundColor(riskBgColor(this.level))
  }
}
