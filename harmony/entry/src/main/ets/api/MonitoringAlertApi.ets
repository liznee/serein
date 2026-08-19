import { HttpClient } from './HttpClient'
import type { MonitoringAlertListResp, MonitoringAlertRecord, MonitoringAlertSummary } from './types'

/** Read-only monitoring alert API. Alerts never participate in approval actions. */
export class MonitoringAlertApi {
  private static instance: MonitoringAlertApi
  private client: HttpClient = new HttpClient()

  static getInstance(): MonitoringAlertApi {
    if (!MonitoringAlertApi.instance) {
      MonitoringAlertApi.instance = new MonitoringAlertApi()
    }
    return MonitoringAlertApi.instance
  }

  async list(state: '' | 'active' | 'resolved' = '', limit: number = 50, offset: number = 0): Promise<MonitoringAlertListResp> {
    let path = '/monitoring/alerts?limit=' + limit + '&offset=' + offset
    if (state !== '') path += '&state=' + state
    return this.client.get<MonitoringAlertListResp>(path)
  }

  async summary(): Promise<MonitoringAlertSummary> {
    return this.client.get<MonitoringAlertSummary>('/monitoring/alerts/summary')
  }

  async detail(id: string): Promise<MonitoringAlertRecord> {
    return this.client.get<MonitoringAlertRecord>('/monitoring/alerts/' + id)
  }
}

export default MonitoringAlertApi.getInstance()
