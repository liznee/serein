import httpClient from '../api/HttpClient'
import { RemoteAuditList, RemoteHostList, RemoteSession, RemoteSessionList, RemoteTicket } from './RemoteModels'

interface RemoteViewRequest {
  host_id: string
  requested_capabilities: string[]
}

interface RemoteEndRequest {
  revision: number
  reason: string
}

interface RemotePrimaryDecisionRequest {
  revision: number
  reason?: string
}

export class RemoteAuthService {
  async listHosts(): Promise<RemoteHostList> {
    return httpClient.get<RemoteHostList>('/v1/remote/hosts')
  }

  async requestViewSession(hostId: string): Promise<RemoteSession> {
    const body: RemoteViewRequest = {
      'host_id': hostId,
      'requested_capabilities': ['view', 'input']
    }
    return httpClient.post<RemoteSession>('/v1/remote/sessions', body)
  }

  async getSession(sessionId: string): Promise<RemoteSession> {
    return httpClient.get<RemoteSession>('/v1/remote/sessions/' + encodeURIComponent(sessionId))
  }

  async listPrimaryRequests(): Promise<RemoteSessionList> {
    return httpClient.get<RemoteSessionList>('/v1/remote/primary/requests')
  }

  async approvePrimaryRequest(session: RemoteSession): Promise<RemoteSession> {
	const body: RemotePrimaryDecisionRequest = { 'revision': session.revision }
    return httpClient.post<RemoteSession>(
      '/v1/remote/primary/requests/' + encodeURIComponent(session.id) + '/approve',
	  body)
  }

  async rejectPrimaryRequest(session: RemoteSession): Promise<RemoteSession> {
	const body: RemotePrimaryDecisionRequest = { 'revision': session.revision, 'reason': 'rejected_by_primary' }
    return httpClient.post<RemoteSession>(
      '/v1/remote/primary/requests/' + encodeURIComponent(session.id) + '/reject',
	  body)
  }

  async endSession(session: RemoteSession): Promise<RemoteSession> {
    // Use revision 0 so the backend applies the end to the session's current
    // revision. The phone's local revision may be stale (e.g. host accepted
    // and bumped revision from 1 to 2, but poll hasn't caught up yet), and a
    // stale CAS revision would cause a 409 conflict — making the "End" button
    // appear non-functional.
    const body: RemoteEndRequest = {
      'revision': 0,
      'reason': 'ended_by_user'
    }
    return httpClient.post<RemoteSession>('/v1/remote/sessions/' + encodeURIComponent(session.id) + '/end', body)
  }

  async refreshTicket(sessionId: string): Promise<RemoteTicket> {
    return httpClient.post<RemoteTicket>('/v1/remote/sessions/' + encodeURIComponent(sessionId) + '/ticket/refresh')
  }

  async listAudit(hostId: string): Promise<RemoteAuditList> {
    return httpClient.get<RemoteAuditList>('/v1/remote/audit?host_id=' + encodeURIComponent(hostId) + '&limit=30')
  }
}

export default new RemoteAuthService()
