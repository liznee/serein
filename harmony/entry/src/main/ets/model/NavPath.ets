// ===== 路由路径常量 =====
// 集中管理所有页面路径，对应 main_pages.json 注册

class NavPath {
  static readonly PROJECTS: string = 'pages/ProjectsPage'
  static readonly APPROVALS: string = 'pages/ApprovalsPage'
  static readonly PAIR: string = 'pages/PairPage'
  static readonly DETAIL: string = 'pages/DetailPage'
  static readonly HISTORY: string = 'pages/HistoryPage'
  static readonly SETTINGS: string = 'pages/SettingsPage'
  static readonly TERMINAL: string = 'pages/TerminalPage'
  static readonly COLLABORATION: string = 'pages/CollaborationPage'
  static readonly REMOTE_CAPABILITY: string = 'pages/RemoteCapabilityPage'
  static readonly REMOTE_DESKTOP: string = 'pages/RemoteDesktopPage'
  static readonly MONITORING_ALERTS: string = 'pages/MonitoringAlertsPage'
}

export default NavPath
