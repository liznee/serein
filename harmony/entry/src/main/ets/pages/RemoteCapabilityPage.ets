import { router } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import { COLOR, RADIUS, TYPO, WEIGHT } from '../utils/DesignTokens'

/**
 * 远程控制阶段 0：设备端 WebRTC 能力探针。
 * 页面仅加载本地 rawfile，不调用摄像头、麦克风或外部网络。
 */
@Entry
@Component
struct RemoteCapabilityPage {
  private controller: webview.WebviewController = new webview.WebviewController()

  build() {
    Column() {
      Row() {
        Row() {
          Text('<')
            .fontSize(24)
            .fontColor('#D97757')
            .fontFamily('monospace')
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor('rgba(217,119,87,0.08)')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { router.back() })

        Column() {
          Text('Remote Lab')
            .fontSize(TYPO.title.size)
            .fontWeight(WEIGHT.bold)
            .fontColor('#D97757')
            .fontFamily('monospace')
          Text('Stage 0 · 本机能力探针')
            .fontSize(TYPO.caption.size)
            .fontColor('#8C909F')
            .margin({ top: 1 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row().width(36)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 44, bottom: 10 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      Web({ src: $rawfile('remote-poc/index.html'), controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .geolocationAccess(false)
        .backgroundColor('#0B0E12')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR.background)
  }
}
