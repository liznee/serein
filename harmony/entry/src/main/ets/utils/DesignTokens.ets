// serein Design System — "Obsidian Nexus" (Stitch-generated)
// Glassmorphism + Liquid Metal accents on Deep Obsidian base
// Colors/typography/spacing from Stitch DESIGN.md

interface TextStyle { size: number; height: number }
interface TypoScale { caption: TextStyle; bodySmall: TextStyle; body: TextStyle; bodyLarge: TextStyle; title: TextStyle; headline: TextStyle; display: TextStyle }
export const TYPO: TypoScale = {
  caption: { size: 11, height: 1.5 }, bodySmall: { size: 13, height: 1.5 },
  body: { size: 15, height: 1.6 }, bodyLarge: { size: 17, height: 1.5 },
  title: { size: 20, height: 1.4 }, headline: { size: 26, height: 1.3 }, display: { size: 32, height: 1.2 }
}

interface WeightScale { regular: number; medium: number; semibold: number; bold: number }
export const WEIGHT: WeightScale = { regular: 400, medium: 500, semibold: 600, bold: 700 }

interface SpaceScale { xs: number; sm: number; md: number; lg: number; xl: number; xxl: number; xxxl: number; xxxxl: number }
export const SPACE: SpaceScale = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 40, xxxl: 48, xxxxl: 64 }

interface RadiusScale { sm: number; md: number; lg: number; full: number }
export const RADIUS: RadiusScale = { sm: 6, md: 12, lg: 16, full: 9999 }

interface TouchScale { min: number; button: number; input: number }
export const TOUCH: TouchScale = { min: 44, button: 44, input: 48 }

interface DurationScale { micro: number; fast: number; normal: number; slow: number }
export const DUR: DurationScale = { micro: 100, fast: 200, normal: 300, slow: 400 }
export const MOTION: DurationScale = DUR

interface CurveScale { enter: Curve; exit: Curve; spring: Curve; smooth: Curve }
export const CURVES: CurveScale = { enter: Curve.EaseOut, exit: Curve.EaseIn, spring: Curve.FastOutSlowIn, smooth: Curve.EaseInOut }
export const PRESS_SCALE: number = 0.97

interface IconScale { sm: number; action: number; large: number }
export const ICON: IconScale = { sm: 30, action: 44, large: 50 }

export const HEADER_HEIGHT = 52
export const PAGE_SIZE: number = 30

// ---- Colors (Stitch Obsidian Nexus) ----
interface ColorScale { primary: Resource; primaryContainer: Resource; success: Resource; successContainer: Resource; warning: Resource; warningContainer: Resource; danger: Resource; dangerContainer: Resource; surface: Resource; surfaceSecondary: Resource; background: Resource; textPrimary: Resource; textSecondary: Resource; textTertiary: Resource; textInverse: Resource; divider: Resource; overlay: Resource }
export const COLOR: ColorScale = {
  primary: $r('app.color.primary'), primaryContainer: $r('app.color.primary_container'),
  success: $r('app.color.success'), successContainer: $r('app.color.success_container'),
  warning: $r('app.color.warning'), warningContainer: $r('app.color.warning_container'),
  danger: $r('app.color.danger'), dangerContainer: $r('app.color.danger_container'),
  surface: $r('app.color.surface'), surfaceSecondary: $r('app.color.surface_secondary'),
  background: $r('app.color.background'), textPrimary: $r('app.color.text_primary'),
  textSecondary: $r('app.color.text_secondary'), textTertiary: $r('app.color.text_tertiary'),
  textInverse: $r('app.color.text_inverse'), divider: $r('app.color.divider'), overlay: $r('app.color.overlay')
}

// ---- Glass System (Stitch: 60% opacity, 20px blur, 1px metallic stroke) ----
interface GlassToken { bg: string; border: string; blur: number }
interface GlassScale { surface: GlassToken; card: GlassToken; elevated: GlassToken; input: GlassToken }
export const GLASS: GlassScale = {
  surface: { bg: 'rgba(29,32,36,0.60)', border: 'rgba(140,144,159,0.15)', blur: 20 },
  card:    { bg: 'rgba(39,42,47,0.40)', border: 'rgba(217,119,87,0.10)', blur: 12 },
  elevated:{ bg: 'rgba(39,42,47,0.60)', border: 'rgba(217,119,87,0.30)', blur: 20 },
  input:   { bg: 'rgba(11,14,18,0.40)', border: 'rgba(140,144,159,0.15)', blur: 0 }
}

// ---- Surface compat ----
interface SurfaceScale { page: string; card: Resource; cardAlt: Resource; elevated: Resource; modal: Resource; input: Resource; border: Resource; borderFocus: string; accentLeft: string; accentGlow: string; overlay: string }
export const SURFACE: SurfaceScale = {
  page: '#111418', card: $r('app.color.surface'), cardAlt: $r('app.color.surface_secondary'),
  elevated: $r('app.color.primary_container'), modal: $r('app.color.surface_secondary'),
  input: $r('app.color.surface_secondary'), border: $r('app.color.divider'),
  borderFocus: '#D97757', accentLeft: '#D97757', accentGlow: 'rgba(217,119,87,0.08)', overlay: 'rgba(0,0,0,0.65)'
}
