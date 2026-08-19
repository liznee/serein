package api

import (
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// rateLimit 滑动窗口限流:同一 IP 在 window 内最多 n 次请求,超出返回 429。
// 使用时间戳切片记录每次请求的时间点，滑动窗口算法避免固定窗口的边界突发问题。
// 用于保护 /devices/pair 等敏感端点,防 pair_code 暴力枚举。
func rateLimit(n int, window time.Duration) func(http.Handler) http.Handler {
	var mu sync.Mutex
	hits := make(map[string][]time.Time)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			now := time.Now()
			windowStart := now.Add(-window)

			mu.Lock()
			slots := hits[ip]
			// 清除窗口外的时间戳
			cut := 0
			for cut < len(slots) && slots[cut].Before(windowStart) {
				cut++
			}
			slots = slots[cut:]
			// 检查是否超限
			if len(slots) >= n {
				mu.Unlock()
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Retry-After", strconv.Itoa(int(window.Seconds())))
				w.WriteHeader(http.StatusTooManyRequests)
				w.Write([]byte(`{"error":"rate limited"}`))
				return
			}
			// 记录当前请求
			slots = append(slots, now)
			hits[ip] = slots
			// 防止 map 随 IP 无限增长:超过阈值时清空(粗粒度,够用)
			if len(hits) > 10000 {
				for k := range hits {
					delete(hits, k)
				}
				hits[ip] = slots
			}
			mu.Unlock()

			next.ServeHTTP(w, r)
		})
	}
}

// clientIP 从请求提取客户端 IP。
// 优先级：X-Real-IP（反向代理设的单一 IP）> X-Forwarded-For 首个 > RemoteAddr 去端口。
// 注意：X-Forwarded-For 可被客户端伪造，生产部署应在反向代理层剥离外部 XFF 头。
// 使用 net.SplitHostPort 正确解析 IPv4 和 IPv6 地址（含 [::1]:port 格式）。
func clientIP(r *http.Request) string {
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		if ip := strings.TrimSpace(xri); ip != "" {
			return ip
		}
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		ip := strings.TrimSpace(strings.SplitN(xff, ",", 2)[0])
		if ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		// 没有端口号或格式异常，直接返回
		return r.RemoteAddr
	}
	return host
}
