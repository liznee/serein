﻿﻿import { ProjectsContent } from './ProjectsPage'
import { TerminalContent } from './TerminalPage'
import { CollaborationContent } from './CollaborationPage'
import { RemoteDesktopContent } from './RemoteDesktopPage'
import { NavIcon, NavIconType } from '../components/NavIcon'
import { NotificationPopup } from '../components/NotificationPopup'
import type { NotificationItem } from '../model/NotificationQueue'
import ApprovalPushService from '../service/ApprovalPushService'
import { setTheme, type ThemeName } from '../terminal/TerminalTheme'
import { promptAction } from '@kit.ArkUI'
import { verifyAuth, hashPin, verifyPin } from '../service/PinGuard'
import PrefStore from '../store/PrefStore'
import { FEATURE_COLLABORATION_CENTER, FEATURE_REMOTE_DESKTOP } from '../config/ProductFeatures'

/**
 * MainTabs — 底部导航栏根容器
 * 四个一级入口：项目、终端、远程与社区。
 */
@Entry
@Component
struct MainTabs {
  @State currentIndex: number = 0
  @State popupItem: NotificationItem | null = null
  @State pinVerified: boolean = false
  @State authFailed: boolean = false
  @State authChecking: boolean = true
  @State pinInput: string = ''
  @State pinError: string = ''
  @State useBiometric: boolean = true  // 优先用系统验证，失败后降级到 PIN 输入
  // tabPressedIndex 已移除：onTouch 绑定在整个 Tabs 上，内容区滑动也会触发 scale 动画导致底部栏跳动
  private storedPinHash: string = ''
  private controller: TabsController = new TabsController()
  private popupTimer: number = 0
  @StorageLink('switchToTerminal') @Watch('onSwitchToTerminal') _sw: boolean = false
  @StorageLink('appForegrounded') @Watch('onAppForegrounded') _fg: boolean = false
  @StorageLink('collaborationPendingCount') collaborationPendingCount: number = 0
  // 横屏远程控制是沉浸式画面：不保留会遮挡画面的四个一级导航。
  // RemoteDesktopContent 在恢复竖屏或离开时会立即复位该状态。
  @StorageLink('remoteDesktopImmersive') remoteDesktopImmersive: boolean = false

  aboutToAppear(): void {
    ApprovalPushService.setPopupHandler((item: NotificationItem) => {
      // 新通知来了 → 重置自动关闭计时器
      if (this.popupTimer !== 0) {
        clearTimeout(this.popupTimer)
      }
      this.popupItem = item
      this.popupTimer = setTimeout(() => {
        this.popupItem = null
        this.popupTimer = 0
      }, 3000)
    })
    this.checkPin()
  }

  aboutToDisappear(): void {
    if (this.popupTimer !== 0) {
      clearTimeout(this.popupTimer)
      this.popupTimer = 0
    }
  }

  async checkPin(): Promise<void> {
    this.authChecking = true
    this.useBiometric = true
    this.pinInput = ''
    this.pinError = ''
    try {
      // 本会话已验过 PIN（如从 PairPage 返回后重挂载）→ 跳过
      const sessionOk = AppStorage.get<boolean>('pinSessionOk')
      if (sessionOk === true) {
        this.pinVerified = true
        this.authChecking = false
        return
      }
      const enabled = await PrefStore.loadPinEnabled()
      if (!enabled) {
        this.pinVerified = true
        this.authChecking = false
        return
      }
      // 先试系统生物识别（指纹/面容）
      const ok = await verifyAuth()
      if (ok) {
        this.pinVerified = true
        this.authChecking = false
        AppStorage.setOrCreate('pinSessionOk', true)
        return
      }
      // 系统验证失败 → 降级到 PIN 输入
      this.useBiometric = false
      this.authFailed = true
    } catch (e) {
      console.error('[PinGuard] checkPin exception: ' + (e as Error).message)
      // 异常降级到 PIN 输入
      this.useBiometric = false
    }
    this.authChecking = false
  }

  async checkPinInput(): Promise<void> {
    const entered = this.pinInput.trim()
    if (!entered) {
      this.pinError = '请输入 PIN'
      return
    }
    const stored = await PrefStore.loadPinHash()
    if (stored === '') {
      // 首次设置 PIN，PBKDF2-SHA256 哈希后存储（替代 XOR 混淆 — 大理寺 M1 修复）
      try {
        const hash = await hashPin(entered)
        await PrefStore.savePinHash(hash)
        this.pinVerified = true
        return
      } catch (e) {
        console.error('[MainTabs] hashPin 失败: ' + (e as Error).message)
        this.pinError = 'PIN 设置失败，请重试'
        return
      }
    }
    const ok = await verifyPin(stored, entered)
    if (ok) {
      this.pinVerified = true
      AppStorage.setOrCreate('pinSessionOk', true)
    } else {
      this.pinError = 'PIN 错误，请重试'
      this.pinInput = ''
    }
  }

  onAppForegrounded(): void {
    if (this._fg && this.pinVerified) {
      // 从后台恢复 — 仅在后台超过 5 分钟时才要求重新验证
      const lastBg = AppStorage.get<number>('lastBackgroundTime') ?? 0
      const bgDuration = Date.now() - lastBg
      const REQUIRE_REVERIFY_MS = 5 * 60 * 1000  // 5 分钟
      if (bgDuration < REQUIRE_REVERIFY_MS) {
        // 短暂离开，不需要重新验证
        AppStorage.setOrCreate('appForegrounded', false)
        return
      }
      AppStorage.setOrCreate('pinSessionOk', false)
      this.pinVerified = false
      this.authChecking = true
      this.authFailed = false
      this.checkPin()
      AppStorage.setOrCreate('appForegrounded', false)
    }
  }

  @Builder
  pinLockScreen(): void {
    Column() {
      // 锁图标容器（珊瑚色边框圆形，非 emoji）
      Row() {
        Text('LOCK')
          .fontSize(14).fontWeight(700)
          .fontColor('#D97757')
          .fontFamily('monospace')
      }
      .width(56).height(56)
      .borderRadius(28)
      .border({ width: 2, color: 'rgba(217,119,87,0.40)' })
      .justifyContent(FlexAlign.Center)
      .margin({ top: '35%' })

      Text('需要验证身份')
        .fontSize(18)
        .fontColor('#E1E2E8')
        .margin({ top: 20 })
        .fontWeight(500)

      if (this.useBiometric) {
        Text('使用 PIN 或生物识别解锁 App')
          .fontSize(13)
          .fontColor('#8C909F')
          .margin({ top: 8 })

        if (this.authFailed) {
          Text('验证失败，请重试')
            .fontSize(12)
            .fontColor('#b53333')
            .margin({ top: 16 })
        }

        Button('验证')
          .fontSize(15)
          .height(44)
          .width(160)
          .fontColor('#1A1C20')
          .backgroundColor('#D97757')
          .borderRadius(6)
          .margin({ top: 32 })
          .onClick(() => {
            this.authFailed = false
            this.checkPin()
          })
      } else {
        // 生物识别不可用，降级到数字 PIN 输入
        Text('请输入 PIN 码')
          .fontSize(13)
          .fontColor('#8C909F')
          .margin({ top: 8 })

        TextInput({ text: this.pinInput, placeholder: '输入 PIN' })
          .type(InputType.Password)
          .maxLength(10)
          .fontSize(20)
          .height(52)
          .width(220)
          .textAlign(TextAlign.Center)
          .fontColor('#E1E2E8')
          .backgroundColor('rgba(29,32,36,0.60)')
          .border({ width: 1, color: this.pinError !== '' ? '#b53333' : 'rgba(140,144,159,0.20)' })
          .borderRadius(8)
          .margin({ top: 20 })
          .onChange((v: string) => { this.pinInput = v; this.pinError = '' })

        if (this.pinError !== '') {
          Text(this.pinError)
            .fontSize(12)
            .fontColor('#b53333')
            .margin({ top: 8 })
        }

        Button('解锁')
          .fontSize(15)
          .height(44)
          .width(160)
          .fontColor('#1A1C20')
          .backgroundColor('#D97757')
          .borderRadius(6)
          .margin({ top: 20 })
          .onClick(() => {
            this.checkPinInput()
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0E12')
  }

  onSwitchToTerminal(): void {
    if (this._sw) {
      this.controller.changeIndex(1)
      AppStorage.setOrCreate('switchToTerminal', false)
    }
  }

  @Builder
  tabBarItem(index: number, iconType: NavIconType, label: string, badgeCount: number) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        NavIcon({
          iconType: iconType,
          color: this.currentIndex === index ? '#D97757' : '#8C909F',
          iconSize: 28,
          strokeWidth: 1.8,
        })
        if (badgeCount > 0) {
          Text(badgeCount > 99 ? '99+' : badgeCount.toString())
            .fontSize(9)
            .fontWeight(700)
            .fontColor('#191B1F')
            .textAlign(TextAlign.Center)
            .minFontSize(8)
            .height(16)
            .constraintSize({ minWidth: 16, maxWidth: 26 })
            .padding({ left: 4, right: 4 })
            .backgroundColor('#D99A83')
            .borderRadius(8)
            .translate({ x: 8, y: -5 })
        }
      }.width(32).height(28)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentIndex === index ? '#E1E2E8' : '#8C909F')
        .letterSpacing(0.3)
        .margin({ top: 4 })
      if (this.currentIndex === index) {
        Row()
          .width(32).height(3)
          .backgroundColor('#D97757')
          .borderRadius(1.5)
          .margin({ top: 6 })
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack() {
      if (this.authChecking) {
        // 认证检查中 — 纯色背景，不显示 LOCK UI，避免闪屏
        Column()
          .width('100%').height('100%')
          .backgroundColor('#0B0E12')
      } else if (!this.pinVerified) {
        // 认证检查完成但需要用户验证 PIN
        this.pinLockScreen()
      } else {
        // 已验证通过，显示正常内容
        Column() {
          Tabs({
            barPosition: BarPosition.End,
            index: this.currentIndex,
            controller: this.controller
          }) {
            TabContent() {
              ProjectsContent()
            }
            .tabBar(this.tabBarItem(0, NavIconType.PROJECTS, '项目', 0))

            TabContent() {
              TerminalContent()
            }
            .tabBar(this.tabBarItem(1, NavIconType.TERMINAL, '终端', 0))

            if (FEATURE_REMOTE_DESKTOP) {
              TabContent() {
                RemoteDesktopContent({ asTab: true })
              }
              .tabBar(this.tabBarItem(2, NavIconType.REMOTE, '远程', 0))
            }

            if (FEATURE_COLLABORATION_CENTER) {
              TabContent() {
                CollaborationContent()
              }
              .tabBar(this.tabBarItem(FEATURE_REMOTE_DESKTOP ? 3 : 2,
                NavIconType.COLLABORATION, '社区', this.collaborationPendingCount))
            }
          }
          .scrollable(false)
          .animationDuration(200)
          .barWidth('100%')
          .barHeight(FEATURE_REMOTE_DESKTOP && this.remoteDesktopImmersive ? 0 : 72)
          .barBackgroundColor('#0B0E12')
          .onChange((index: number) => {
            this.currentIndex = index
            if (index === 1) {
              const seq = AppStorage.get<number>('terminalActivationSeq') ?? 0
              AppStorage.setOrCreate('terminalActivationSeq', seq + 1)
            }
          })
        }
        .width('100%').height('100%')
        .backgroundColor('#0B0E12')
        // 仅延伸进状态栏/导航条做沉浸；不 extendSafeArea KEYBOARD——
        // 那样会把底部 Tab 输入栏主动钻进键盘下方，抵消所有键盘避让方案
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // 审批通知弹窗（浮在最上层，由 NotificationPopup 自带遮罩管理点击）
        if (this.popupItem !== null) {
          NotificationPopup({
            item: this.popupItem,
            onDismiss: () => {
              if (this.popupTimer !== 0) {
                clearTimeout(this.popupTimer)
                this.popupTimer = 0
              }
              this.popupItem = null
            }
          })
        }
      }
    }
    .width('100%').height('100%')
  }
}
