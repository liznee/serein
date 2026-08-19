import type { ProviderKind } from '../model/collaboration/CollaborationModels'
import type { CollaborationProvider } from './CollaborationProvider'
import GithubProvider from './GithubProvider'
import GiteeProvider from './GiteeProvider'

export function getCollaborationProvider(kind: ProviderKind): CollaborationProvider {
  if (kind === 'github') return GithubProvider
  if (kind === 'gitee') return GiteeProvider
  throw new Error('不支持的协作平台')
}
