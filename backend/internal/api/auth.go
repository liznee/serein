package api

import (
	"context"
	"crypto/subtle"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"serein/internal/remote"
	"serein/internal/store"
)

type authenticatedDeviceContextKey struct{}

// authenticatedDevice returns the paired device identity bound by clientAuth.
// Remote-control handlers require this value and never trust a device ID from
// request JSON or query parameters.
func authenticatedDevice(r *http.Request) *store.Device {
	device, _ := r.Context().Value(authenticatedDeviceContextKey{}).(*store.Device)
	return device
}

// hookAuth 校验全局 HOOK_TOKEN(hook 脚本用单一 token)。
//   - token 非空:以常量时间比较 Bearer token,不匹配返回 401
//   - token 为空 且 devMode=true:放行(仅本地开发/测试)
//   - token 为空 且 devMode=false:返回 401(纵深防御,即使 main.go panic guard 失效也不放行)
//
// 使用常量时间比较避免时序侧信道。
func hookAuth(token string, devMode bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if token == "" {
				if devMode {
					next.ServeHTTP(w, r)
				} else {
					unauthorized(w)
				}
				return
			}
			got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				tokenHint := ""
				if len(got) > 8 {
					tokenHint = got[:8] + "..."
				} else if got != "" {
					tokenHint = "(short)"
				}
				log.Printf("[auth] hookAuth rejected ip=%s path=%s token=%s", clientIPFromRequest(r), r.URL.Path, tokenHint)
				unauthorized(w)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// remoteHostAuth authenticates operational Host routes with the credential
// issued specifically for the host in the URL. The global Hook Token is only
// accepted by the separate bootstrap/rotation/revocation routes.
func remoteHostAuth(service *remote.Service) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if service == nil || service.AuthenticateHost(chi.URLParam(r, "hostID"), got) != nil {
				unauthorized(w)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// clientAuth 校验 per-device CLIENT_TOKEN(查 devices 表)。
//   - devMode=true 且无 token 时放行(仅本地调试,SEREIN_ENV!=production)
//   - per-device token 命中 DB → 放行 + 异步刷新 last_seen
//   - globalToken 命中 → 放行(兼容 dev/测试后门,生产应留空)
//   - 其余 401
//
// 生产部署:globalToken 留空,依赖 per-device 校验,无设备则全部拒绝。
// 安全加固:生产环境下即使 globalToken 误传入也强制拒绝,双重保险。
func clientAuth(repo *store.DeviceRepo, globalToken string, devMode bool) func(http.Handler) http.Handler {
	// 生产环境下彻底禁用 globalToken 后门,防止误配置导致认证绕过
	if !devMode {
		globalToken = ""
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			// dev 模式无 token 放行(仅非生产环境调试)
			if devMode && got == "" {
				next.ServeHTTP(w, r)
				return
			}
			// per-device token 查 DB
			if got != "" && repo != nil {
				authCtx, authCancel := context.WithTimeout(r.Context(), 10*time.Second)
				defer authCancel()
				dev, err := repo.ByClientToken(authCtx, got)
				if err != nil {
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					w.Write([]byte(`{"error":"db error"}`))
					return
				}
				if dev != nil {
					go repo.TouchLastSeen(got)
					ctx := context.WithValue(r.Context(), authenticatedDeviceContextKey{}, dev)
					next.ServeHTTP(w, r.WithContext(ctx))
					return
				}
			}
			// 全局 token 后门(兼容测试/dev;生产留空不走此分支)
			if globalToken != "" && subtle.ConstantTimeCompare([]byte(got), []byte(globalToken)) == 1 {
				next.ServeHTTP(w, r)
				return
			}
			// 认证失败:记录 IP 和 token 前缀(脱敏)用于安全审计
			tokenHint := ""
			if len(got) > 8 {
				tokenHint = got[:8] + "..."
			} else if got != "" {
				tokenHint = "(short)"
			}
			log.Printf("[auth] clientAuth rejected ip=%s path=%s token=%s", clientIPFromRequest(r), r.URL.Path, tokenHint)
			unauthorized(w)
		})
	}
}

// deployAuth 部署操作二次授权验证。
// 先校验 X-Deploy-Token 是否为 HOOK_TOKEN，回退到 CLIENT_TOKEN（查 device 表）。
// 手机端一键部署时传 CLIENT_TOKEN 即可通过。
// 安全加固:生产环境下 HOOK_TOKEN 必须配置,否则拒绝所有部署请求。
func deployAuth(token string, devMode bool, deviceRepo *store.DeviceRepo) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// 生产环境下 HOOK_TOKEN 必须配置,否则拒绝所有部署请求
			if token == "" {
				if devMode {
					next.ServeHTTP(w, r)
					return
				}
				log.Printf("deployAuth: HOOK_TOKEN 未配置，生产环境拒绝部署请求")
				unauthorized(w)
				return
			}
			got := r.Header.Get("X-Deploy-Token")
			// 1) 校验 HOOK_TOKEN
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1 {
				next.ServeHTTP(w, r)
				return
			}
			// 2) 回退：校验 CLIENT_TOKEN（手机端一键部署用）
			if deviceRepo != nil && got != "" {
				authCtx, authCancel := context.WithTimeout(r.Context(), 10*time.Second)
				defer authCancel()
				if dev, err := deviceRepo.ByClientToken(authCtx, got); err == nil && dev != nil {
					next.ServeHTTP(w, r)
					return
				}
			}
			log.Printf("deployAuth: X-Deploy-Token 不匹配（路径: %s），返回 401", r.URL.Path)
			unauthorized(w)
		})
	}
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	w.Write([]byte(`{"error":"unauthorized"}`))
}
