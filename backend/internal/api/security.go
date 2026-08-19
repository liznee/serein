package api

import "net/http"

// securityHeaders 是安全响应头中间件,为所有 HTTP 响应添加标准安全头。
//
// 当 tlsEnabled=true 时,额外添加 Strict-Transport-Security (HSTS) 头,
// 告知浏览器在指定时间内只通过 HTTPS 连接本站,防止 SSL 剥离攻击。
//
// 头说明:
//   - X-Content-Type-Options: nosniff — 阻止 MIME 嗅探
//   - X-Frame-Options: DENY — 防止点击劫持(页面不可被 iframe 嵌入)
//   - Referrer-Policy: strict-origin-when-cross-origin — 限制 Referer 泄漏
//   - X-XSS-Protection: 0 — 禁用浏览器内置 XSS 过滤器(现代浏览器已废弃,
//     且该过滤器本身可能引入 XSS;依赖 CSP 替代)
//   - Strict-Transport-Security — 仅 TLS 模式,强制 HTTPS (max-age=1年)
func securityHeaders(tlsEnabled bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			h := w.Header()
			h.Set("X-Content-Type-Options", "nosniff")
			h.Set("X-Frame-Options", "DENY")
			h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
			h.Set("X-XSS-Protection", "0")
			if tlsEnabled {
				// HSTS: max-age=1年, includeSubDomains, preload
				h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
			}
			next.ServeHTTP(w, r)
		})
	}
}
