// ===== 底部导航图标组件 =====
// 使用 SVG 资源文件 + Image 组件渲染
// SVG 的 viewBox 自动缩放坐标系，图标在任何尺寸下都居中且清晰
//
// 之前用 Shape/Path + viewPort，但 HarmonyOS 的 Shape.viewPort
// 不会像 SVG viewBox 那样自动缩放路径坐标，导致图标偏左上角且偏小。
// 改用 SVG 文件后，Image 组件的 width/height 控制显示尺寸，
// SVG 内部的 viewBox="0 0 24 24" 负责坐标映射，完美居中。

export enum NavIconType {
  PROJECTS = 'projects',
  TERMINAL = 'terminal',
  COLLABORATION = 'collaboration',
  REMOTE = 'remote',
  SETTINGS = 'settings',
}

@Component
export struct NavIcon {
  @Prop iconType: NavIconType = NavIconType.PROJECTS
  @Prop color: string = '#8C909F'
  @Prop iconSize: number = 28
  @Prop strokeWidth: number = 1.8

  build() {
    Image(this.getIconResource())
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
  }

  /**
   * 根据图标类型和颜色选择对应的 SVG 资源
   * active 色 (#D97757) 用 _active.svg，其它用 _inactive.svg
   */
  private getIconResource(): Resource {
    const isActive: boolean = this.color === '#D97757'
    if (this.iconType === NavIconType.PROJECTS) {
      return isActive ? $r('app.media.nav_projects_active') : $r('app.media.nav_projects_inactive')
    } else if (this.iconType === NavIconType.TERMINAL) {
      return isActive ? $r('app.media.nav_terminal_active') : $r('app.media.nav_terminal_inactive')
    } else if (this.iconType === NavIconType.COLLABORATION) {
      return isActive ? $r('app.media.nav_collaboration_active') : $r('app.media.nav_collaboration_inactive')
    } else if (this.iconType === NavIconType.REMOTE) {
      return isActive ? $r('app.media.nav_remote_active') : $r('app.media.nav_remote_inactive')
    } else {
      return isActive ? $r('app.media.nav_settings_active') : $r('app.media.nav_settings_inactive')
    }
  }
}
