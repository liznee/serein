import { http } from '@kit.NetworkKit'

// ===== 统一 HTTP 客户端 =====
// 负责：拼接 baseUrl、注入 Bearer token、超时控制、错误归一、httpRequest 生命周期

/** API 错误 — 必须是 Error 子类(ArkTS throw 限制) */
export class ApiError extends Error {
  status: number  // HTTP 状态码，-1 = 网络错误

  constructor(status: number, message: string) {
    super(message)
    this.status = status
    this.name = 'ApiError'
  }
}

/** 检查一个错误是否是 ApiError */
export function isApiError(err: Object): boolean {
  return err instanceof ApiError
}

/** 请求头类型 */
interface RequestHeaders {
  'Content-Type': string
  Authorization?: string
}

/**
 * HTTP 客户端单例
 * 所有请求自动从 AppStorage 读取 backendUrl 和 clientToken
 */
export class HttpClient {
  private static instance: HttpClient

  static getInstance(): HttpClient {
    if (!HttpClient.instance) {
      HttpClient.instance = new HttpClient()
    }
    return HttpClient.instance
  }

  /** 从 AppStorage 取后端地址，未配置时返回空字符串 */
  private getBaseUrl(): string {
    const url = AppStorage.get<string>('backendUrl')
    if (url !== undefined && url !== null && url.length > 0) {
      return url
    }
    return ''
  }

  /** 从 AppStorage 取 CLIENT_TOKEN */
  private getToken(): string {
    const token = AppStorage.get<string>('clientToken')
    if (token !== undefined && token !== null && token.length > 0) {
      return token
    }
    return ''
  }

  /**
   * 通用 HTTP 请求
   * @throws ApiError 网络/业务错误统一抛出
   */
  async request<T>(method: http.RequestMethod, path: string, body?: Object): Promise<T> {
    const base = this.getBaseUrl()
    if (base === '') {
      throw new ApiError(-1, '后端地址未配置，请在设置中配置后端地址')
    }
    const url = base + path
    const token = this.getToken()
    const httpRequest = http.createHttp()

    try {
      // 构建请求头
      const headers: RequestHeaders = {
        'Content-Type': 'application/json'
      }
      if (token !== '') {
        headers.Authorization = 'Bearer ' + token
      }

      // 请求选项
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      }

      if (body !== undefined && body !== null) {
        options.extraData = JSON.stringify(body)
      }

      const response = await httpRequest.request(url, options)
      const respCode = response.responseCode
      const respBody = response.result as string

      // 2xx → 成功
      if (respCode === 200 || respCode === 201) {
        return JSON.parse(respBody) as T
      }

      // 4xx/5xx → 尝试解析后端 error 字段
      let message: string = 'HTTP ' + respCode
      try {
        const parsed: Record<string, Object> = JSON.parse(respBody)
        const errField = parsed['error']
        if (typeof errField === 'string') {
          message = errField
        }
      } catch (e) {
        console.warn('HttpClient: 后端错误响应 JSON 解析失败: ' + respCode + ' body=' + respBody.slice(0, 200))
      }
      throw new ApiError(respCode, message)
    } catch (err) {
      // 已经是 ApiError → 直接抛
      if (err instanceof ApiError) {
        throw err
      }
      // 网络错误 → status = -1
      const msg = (err as Error).message ?? '网络连接失败'
      throw new ApiError(-1, msg)
    } finally {
      // ⚠️ 必须销毁 httpRequest 实例，防止内存泄漏
      httpRequest.destroy()
    }
  }

  /** GET 请求 */
  async get<T>(path: string): Promise<T> {
    return this.request<T>(http.RequestMethod.GET, path)
  }

  /** POST 请求 */
  async post<T>(path: string, body?: Object): Promise<T> {
    return this.request<T>(http.RequestMethod.POST, path, body)
  }

  /** PUT request */
  async put<T>(path: string, body?: Object): Promise<T> {
    return this.request<T>(http.RequestMethod.PUT, path, body)
  }

  /** DELETE 请求 */
  async delete<T>(path: string): Promise<T> {
    return this.request<T>(http.RequestMethod.DELETE, path)
  }
}

export default HttpClient.getInstance()
