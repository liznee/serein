import { http } from '@kit.NetworkKit'
import type { ProviderKind } from '../model/collaboration/CollaborationModels'
import { CollaborationProviderError } from './CollaborationProvider'
import { encodeQuery } from './ProviderJson'

interface ProviderHeaders {
  'Accept': string
  'Content-Type': string
  'Authorization'?: string
  'X-GitHub-Api-Version'?: string
  'User-Agent'?: string
}

/**
 * Provider-only HTTP client. It refuses arbitrary hosts so a malicious Issue URL
 * cannot receive an account token.
 */
export class ProviderHttpClient {
  private provider: ProviderKind

  constructor(provider: ProviderKind) { this.provider = provider }

  private allowedBase(): string {
    return this.provider === 'github' ? 'https://api.github.com' : 'https://gitee.com/api/v5'
  }

  private buildUrl(path: string, token: string, query?: Record<string, string>): string {
    if (!path.startsWith('/')) throw new CollaborationProviderError(this.provider, -1, 'invalid_path', '平台请求路径无效')
    const params: Record<string, string> = {}
    if (query) {
      const keys = Object.keys(query)
      for (let i = 0; i < keys.length; i++) params[keys[i]] = query[keys[i]]
    }
    // Gitee v5 官方接口把 OAuth access_token 定义为 query 参数。该 URL
    // 绝不写日志，错误对象也不包含 URL。
    if (this.provider === 'gitee') params['access_token'] = token
    const suffix = encodeQuery(params)
    return this.allowedBase() + path + (suffix === '' ? '' : '?' + suffix)
  }

  private headers(token: string, form: boolean): ProviderHeaders {
    if (this.provider === 'github') {
      return {
        'Accept': 'application/vnd.github+json',
        'Content-Type': form ? 'application/x-www-form-urlencoded' : 'application/json',
        'Authorization': 'Bearer ' + token,
        'X-GitHub-Api-Version': '2026-03-10',
        'User-Agent': 'Serein-Collaboration'
      }
    }
    return {
      'Accept': 'application/json',
      'Content-Type': form ? 'application/x-www-form-urlencoded' : 'application/json',
      'User-Agent': 'Serein-Collaboration'
    }
  }

  async request<T>(method: http.RequestMethod, path: string, token: string,
    query?: Record<string, string>, body?: Record<string, Object>, form: boolean = false): Promise<T> {
    if (!token) throw new CollaborationProviderError(this.provider, 401, 'missing_token', '账号凭证不存在，请重新授权')
    const request = http.createHttp()
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: this.headers(token, form),
        connectTimeout: 10000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING,
      }
      if (body) {
        if (form) {
          const formValues: Record<string, string> = {}
          const keys = Object.keys(body)
          for (let i = 0; i < keys.length; i++) formValues[keys[i]] = String(body[keys[i]])
          if (this.provider === 'gitee') formValues['access_token'] = token
          options.extraData = encodeQuery(formValues)
        } else {
          options.extraData = JSON.stringify(body)
        }
      }
      const response = await request.request(this.buildUrl(path, token, query), options)
      const status = response.responseCode
      const raw = response.result as string
      if (status >= 200 && status < 300) {
        if (raw === '') return JSON.parse('{}') as T
        return JSON.parse(raw) as T
      }

      let message = '平台请求失败（HTTP ' + status + '）'
      let code = 'http_error'
      try {
        const errorBody = JSON.parse(raw) as Record<string, Object>
        const providerMessage = errorBody['message']
        const providerError = errorBody['error']
        if (typeof providerMessage === 'string' && providerMessage.length < 300 &&
          !this.containsCredential(providerMessage, token)) message = providerMessage
        if (typeof providerError === 'string' && providerError.length < 100 &&
          !this.containsCredential(providerError, token)) code = providerError
      } catch (_) {}
      if (status === 401) message = '账号授权已失效，请重新授权'
      if (status === 403) message = '当前账号没有该操作所需权限，或平台限流'
      if (status === 404) message = '仓库或工作项不存在，或当前账号无权访问'
      throw new CollaborationProviderError(this.provider, status, code, message)
    } catch (e) {
      if (e instanceof CollaborationProviderError) throw e
      // NetworkKit may include the full request URL in its native error text.
      // Gitee requires access_token in the query string, so never propagate the
      // raw native message into UI, encrypted cache, writeback audit or logs.
      throw new CollaborationProviderError(this.provider, -1, 'network_error', '平台连接失败，请检查网络后重试')
    } finally {
      request.destroy()
    }
  }

  get<T>(path: string, token: string, query?: Record<string, string>): Promise<T> {
    return this.request<T>(http.RequestMethod.GET, path, token, query)
  }

  post<T>(path: string, token: string, body: Record<string, Object>, form: boolean = false): Promise<T> {
    return this.request<T>(http.RequestMethod.POST, path, token, undefined, body, form)
  }

  patch<T>(path: string, token: string, body: Record<string, Object>, form: boolean = false): Promise<T> {
    return this.request<T>(http.RequestMethod.PATCH, path, token, undefined, body, form)
  }

  put<T>(path: string, token: string, body: Record<string, Object>, form: boolean = false): Promise<T> {
    return this.request<T>(http.RequestMethod.PUT, path, token, undefined, body, form)
  }

  private containsCredential(value: string, token: string): boolean {
    const normalized = value.toLowerCase()
    return value.indexOf(token) >= 0 || normalized.indexOf('access_token') >= 0 ||
      normalized.indexOf('authorization:') >= 0 || normalized.indexOf('bearer ') >= 0 ||
      normalized.indexOf('client_secret') >= 0
  }
}
