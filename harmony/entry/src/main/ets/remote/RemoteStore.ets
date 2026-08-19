import { RemoteHost, RemoteSession } from './RemoteModels'

// Keeps the newest revision only. A delayed HTTP/WS response must never move
// the page from connected back to waiting_consent.
export class RemoteStore {
  private hosts: RemoteHost[] = []
  private sessions: Map<string, RemoteSession> = new Map()

  replaceHosts(hosts: RemoteHost[]): void {
    this.hosts = hosts.slice()
  }

  listHosts(): RemoteHost[] {
    return this.hosts.slice()
  }

  applySession(value: RemoteSession): boolean {
    const current = this.sessions.get(value.id)
    if (current !== undefined && current.revision > value.revision) {
      return false
    }
    this.sessions.set(value.id, value)
    return true
  }

  getSession(id: string): RemoteSession | undefined {
    return this.sessions.get(id)
  }

  clearSession(id: string): void {
    this.sessions.delete(id)
  }
}

export default new RemoteStore()
