import { http } from '@kit.NetworkKit'
import { KEY_CLIENT_TOKEN } from '../state/AppStore'
import type {
  CollaborationState, LocalProjectRemote, RemoteRepository, RepositoryBinding
} from '../model/collaboration/CollaborationModels'
import PrefStore, { normalizeAgentType } from '../store/PrefStore'
import type { ProjectConfig } from '../store/PrefStore'
import CollaborationStore from '../store/CollaborationStore'

interface CollaborationSessionSnapshot {
  agent_session_id: string
  agent_type: string
  project: string
  updated_at: string
}

export class CollaborationProjectService {
  async loadLocalProjects(): Promise<LocalProjectRemote[]> {
    const snapshot = await PrefStore.loadAll()
    let backendUrl = snapshot.backendUrl
    if (backendUrl === '') backendUrl = AppStorage.get<string>('backendUrl') ?? ''
    if (backendUrl === '') return []

    const request = http.createHttp()
    try {
      const headers: Record<string, string> = {}
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      if (token !== '') headers['Authorization'] = 'Bearer ' + token
      const response = await request.request(backendUrl + '/agent/projects', {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 5000,
        expectDataType: http.HttpDataType.STRING,
      })
      if (response.responseCode !== 200) throw new Error('本地项目服务不可用')
      const data = JSON.parse(response.result as string) as Record<string, Object>
      const paths = (data['projects'] as Record<string, string>) ?? {}
      const remotes = (data['git_remotes'] as Record<string, string[]>) ?? {}
      const sessionIndex = (data['collaboration_sessions'] as Record<string, CollaborationSessionSnapshot>) ?? {}
      const names = Object.keys(paths)
      const projects: LocalProjectRemote[] = []
      for (let i = 0; i < names.length; i++) {
        const name = names[i]
        const projectSessions: Record<string, string> = {}
        const scopes = Object.keys(sessionIndex)
        for (let j = 0; j < scopes.length; j++) {
          const value = sessionIndex[scopes[j]]
          if (value.project === name && value.agent_session_id !== '') {
            projectSessions[scopes[j]] = value.agent_session_id
          }
        }
        projects.push({
          project: name,
          path: paths[name],
          agentType: this.agentTypeFor(name, snapshot.projects),
          remotes: remotes[name] ?? [],
          collaborationSessions: projectSessions,
        })
      }
      return projects
    } finally {
      request.destroy()
    }
  }

  matchingProjects(repository: RemoteRepository, projects: LocalProjectRemote[]): LocalProjectRemote[] {
    const key = this.repositoryRemoteKey(repository).toLowerCase()
    const matches: LocalProjectRemote[] = []
    for (let i = 0; i < projects.length; i++) {
      for (let j = 0; j < projects[i].remotes.length; j++) {
        if (projects[i].remotes[j].toLowerCase() === key) {
          matches.push(projects[i])
          break
        }
      }
    }
    return matches
  }

  async confirmBinding(repository: RemoteRepository, project: LocalProjectRemote): Promise<RepositoryBinding> {
    const state = await CollaborationStore.load()
    const binding: RepositoryBinding = {
      repositoryId: repository.id,
      project: project.project,
      projectPath: project.path,
      normalizedRemote: this.repositoryRemoteKey(repository),
      confirmedAt: Date.now(),
    }
    state.bindings = state.bindings.filter((value: RepositoryBinding) => value.repositoryId !== repository.id)
    state.bindings.push(binding)
    if (state.trackedRepositoryIds.indexOf(repository.id) < 0) state.trackedRepositoryIds.push(repository.id)
    await CollaborationStore.save(state)
    return binding
  }

  async removeBinding(repositoryId: string): Promise<void> {
    const state = await CollaborationStore.load()
    state.bindings = state.bindings.filter((value: RepositoryBinding) => value.repositoryId !== repositoryId)
    await CollaborationStore.save(state)
  }

  private repositoryRemoteKey(repository: RemoteRepository): string {
    const host = repository.provider === 'github' ? 'github.com' : 'gitee.com'
    return host + '/' + repository.fullName.replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '')
  }

  private agentTypeFor(project: string, configs: ProjectConfig[]): string {
    for (let i = 0; i < configs.length; i++) {
      if (configs[i].name === project) return normalizeAgentType(configs[i].agentType)
    }
    return 'claude'
  }
}

export default new CollaborationProjectService()
