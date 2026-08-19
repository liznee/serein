import type { Decision } from '../api/types'
import { decisionColor, decisionBorderColor, decisionLabel } from '../utils/RiskUtil'
import { TYPO } from '../utils/DesignTokens'

/** 决策状态标签 — 用于历史列表 */
@Component
export struct DecisionTag {
  @Prop decision: Decision = 'pending'

  build() {
    Text(decisionLabel(this.decision))
      .fontSize(TYPO.caption.size)
      .fontWeight(FontWeight.Medium)
      .fontColor(decisionColor(this.decision))
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .border({ width: 1, color: decisionBorderColor(this.decision) })
      .borderRadius(4)
  }
}
