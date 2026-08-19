import { pushService } from '@kit.PushKit'
import { UIAbility } from '@kit.AbilityKit'
import DeviceApi from '../api/DeviceApi'

type TokenUpdateHandler = (token: string) => void

class PushKitRegistrationService {
  private started: boolean = false
	private retryTimer: number = -1
	private retryAttempt: number = 0
	private registering: boolean = false
  private tokenUpdateHandler: TokenUpdateHandler = (token: string): void => {
		this.registerTokenWithRecovery(token)
  }

  async start(ability: UIAbility): Promise<void> {
    if (this.started) return
    this.started = true
    AppStorage.setOrCreate('pushKitDeliveryActive', false)
		try {
			pushService.on('tokenUpdate', ability, this.tokenUpdateHandler)
			await this.refreshToken()
		} catch (error) {
			this.reportUnavailable(error as Object)
			this.scheduleRetry()
		}
  }

  stop(): void {
    if (!this.started) return
		this.started = false
		this.registering = false
		this.retryAttempt = 0
		if (this.retryTimer >= 0) {
			clearTimeout(this.retryTimer)
			this.retryTimer = -1
		}
		AppStorage.setOrCreate('pushKitDeliveryActive', false)
    try {
      pushService.off('tokenUpdate', this.tokenUpdateHandler)
    } catch (_error) {
    }
  }

	private async refreshToken(): Promise<void> {
		if (!this.started || this.registering) return
		this.registering = true
		try {
			const token = await pushService.getToken()
			await this.registerToken(token)
			this.retryAttempt = 0
		} finally {
			this.registering = false
		}
	}

	private async registerTokenWithRecovery(token: string): Promise<void> {
		if (!this.started || this.registering) return
		this.registering = true
		try {
			await this.registerToken(token)
			this.retryAttempt = 0
		} catch (error) {
			AppStorage.setOrCreate('pushKitDeliveryActive', false)
			this.reportUnavailable(error as Object)
			this.scheduleRetry()
		} finally {
			this.registering = false
		}
	}

	private async registerToken(token: string): Promise<void> {
		if (!this.started || token.length < 16) {
			AppStorage.setOrCreate('pushKitDeliveryActive', false)
			return
		}
		const result = await DeviceApi.registerPushToken(token)
		const active = result.registered && result.delivery_enabled
		AppStorage.setOrCreate('pushKitDeliveryActive', active)
		console.info('serein push kit registration: active=' + active)
	}

	private scheduleRetry(): void {
		if (!this.started || this.retryTimer >= 0) return
		const delays: number[] = [5000, 15000, 30000, 60000]
		const delayIndex = Math.min(this.retryAttempt, delays.length - 1)
		const delay = delays[delayIndex]
		this.retryAttempt++
		this.retryTimer = setTimeout(() => {
			this.retryTimer = -1
			this.refreshToken().catch((error: Object) => {
				AppStorage.setOrCreate('pushKitDeliveryActive', false)
				this.reportUnavailable(error)
				this.scheduleRetry()
			})
		}, delay)
  }

  private reportUnavailable(error: Object): void {
    const details = error as Record<string, Object>
    let code: Object = 'unknown'
    if (details['code'] !== undefined) {
      code = details['code']
    } else if (details['status'] !== undefined) {
      code = details['status']
    }
    console.warn('serein push kit unavailable: code=' + code)
  }
}

export default new PushKitRegistrationService()
