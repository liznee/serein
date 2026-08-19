import { HttpClient } from './HttpClient'
import type { PairResp, PairReq } from './types'

// ===== 设备 API 层 =====
// 封装 /devices/* 端点

/** 主设备状态响应 */
export interface PrimaryStatusResp {
  device_id: string
  device_name: string
  is_primary: boolean
}

/** 主设备注册响应 */
export interface RegisterPrimaryResp {
  device_id: string
  device_name: string
  is_primary: boolean
}

/** System push-token registration response. The token is never echoed. */
export interface RegisterPushTokenResp {
  registered: boolean
  delivery_enabled: boolean
}

interface RegisterPushTokenReq {
  push_token: string
}

export class DeviceApi {
  private static instance: DeviceApi
  private client: HttpClient = new HttpClient()

  static getInstance(): DeviceApi {
    if (!DeviceApi.instance) {
      DeviceApi.instance = new DeviceApi()
    }
    return DeviceApi.instance
  }

  /**
   * 设备配对 — POST /devices/pair
   * @param deviceName  设备名（不可为空）
   * @param pairCode    配对码
   * @returns           201 返回 client_token + device_id；403 配对码错误
   */
  async pair(deviceName: string, pairCode: string): Promise<PairResp> {
    const body: PairReq = {
      device_name: deviceName,
      pair_code: pairCode
    }
    return this.client.post<PairResp>('/devices/pair', body)
  }

  // Removes this phone from the backend before local credentials are erased.
  // This is required by Serein's single-phone pairing policy.
  async unpairCurrent(): Promise<void> {
    await this.client.delete<Object>('/devices/current')
  }

  /** Register the current device's Huawei Push Kit token with Serein. */
  async registerPushToken(pushToken: string): Promise<RegisterPushTokenResp> {
    const body: RegisterPushTokenReq = {
      push_token: pushToken
    }
    return this.client.put<RegisterPushTokenResp>('/devices/current/push-token', body)
  }

  /**
   * 查询主设备状态 — GET /v1/devices/primary
   * @returns  返回当前设备是否为主设备
   */
  async getPrimaryStatus(): Promise<PrimaryStatusResp> {
    return this.client.get<PrimaryStatusResp>('/v1/devices/primary')
  }

  /**
   * 注册为主设备 — POST /v1/devices/primary/register
   * 将当前已认证设备标记为主设备。同一时间只有一台设备可以是主设备。
   * @returns  注册后的设备状态
   */
  async registerAsPrimary(): Promise<RegisterPrimaryResp> {
    return this.client.post<RegisterPrimaryResp>('/v1/devices/primary/register')
  }

  /**
   * 取消主设备标记 — DELETE /v1/devices/primary
   * 放弃当前设备的远程控制发起权限。操作幂等。
   * @returns  取消后的设备状态（is_primary 始终为 false）
   */
  async clearPrimary(): Promise<PrimaryStatusResp> {
    return this.client.delete<PrimaryStatusResp>('/v1/devices/primary')
  }
}

export default DeviceApi.getInstance()
