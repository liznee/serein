import HttpClient from '../api/HttpClient'
import type { ProviderKind } from '../model/collaboration/CollaborationModels'

export interface OAuthAvailability {
  available: boolean
  mode: string
  read_scope: string[]
  public_write_scope: string[]
  private_write_scope: string[]
}

export type OAuthAccessMode = 'read' | 'public_write' | 'private_write'

interface OAuthStartInput {
  access: OAuthAccessMode
}

export interface CollaborationOAuthConfig {
  github: OAuthAvailability
  gitee: OAuthAvailability
}

export interface OAuthStartResult {
  provider: ProviderKind
  state: string
  authorization_url: string
  expires_in: number
  access: OAuthAccessMode
}

export interface OAuthPollResult {
  provider: ProviderKind
  status: string
  access_token?: string
  scopes?: string[]
  error?: string
  access?: OAuthAccessMode
}

export class CollaborationAuthService {
  async config(): Promise<CollaborationOAuthConfig> {
    return HttpClient.get<CollaborationOAuthConfig>('/collaboration/oauth/config')
  }

  async start(provider: ProviderKind, access: OAuthAccessMode = 'read'): Promise<OAuthStartResult> {
    const input: OAuthStartInput = { access: access }
    return HttpClient.post<OAuthStartResult>('/collaboration/oauth/' + provider + '/start', input)
  }

  async poll(provider: ProviderKind, state: string): Promise<OAuthPollResult> {
    if (!/^[a-zA-Z0-9_-]{32,64}$/.test(state)) throw new Error('非法授权状态')
    return HttpClient.get<OAuthPollResult>('/collaboration/oauth/' + provider + '/status/' + state)
  }
}

export default new CollaborationAuthService()
