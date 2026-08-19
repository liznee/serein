/**
 * Product capability switches.
 *
 * V1.0 ships one open-source feature set. These switches remain only as
 * compile-time capability guards for ports/builds that cannot provide a
 * dependency; they are not product-edition or payment gates.
 *
 * Security features are deliberately absent from this list: approvals,
 * encryption, background notifications and PIN protection are part of the
 * free core and must never be weakened by product edition selection.
 */
export const PRODUCT_EDITION: string = 'open-source-full'

export const FEATURE_REMOTE_DESKTOP: boolean = true
export const FEATURE_COLLABORATION_CENTER: boolean = true
export const FEATURE_CODEX_DESKTOP: boolean = true
