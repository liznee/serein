package config

import (
	"os"
	"strconv"
)

// Config 持有后端运行配置,全部通过环境变量注入。
type Config struct {
	Listen             string // HTTP 监听地址
	DBPath             string // SQLite 文件路径
	HookToken          string // hook 认证 token
	ClientToken        string // 客户端认证 token(Phase 2,dev 模式空=放行)
	PairCode           string // 设备配对码(换 CLIENT_TOKEN)，生产环境必须显式设置
	NtfyURL            string // ntfy 服务地址
	NtfyTopic          string // ntfy 推送 topic
	HuaweiPushClientID string // AppGallery Connect OAuth client ID
	HuaweiPushSecret   string // AppGallery Connect OAuth client secret
	HuaweiPushOAuthURL string // 测试/私有部署可覆盖；默认华为 OAuth
	HuaweiPushAPIBase  string // 测试/私有部署可覆盖；默认华为 Push API
	ApprovalTimeoutSec int    // 审批超时秒数(默认 300=5min)
	LogPath            string // 日志文件路径(空=仅 stdout)
	TLSCert            string // TLS 证书文件路径(空=不启用 TLS/HTTPS/WSS)
	TLSKey             string // TLS 私钥文件路径(空=不启用 TLS/HTTPS/WSS)
}

func Load() Config {
	return Config{
		Listen:             getenv("SEREIN_LISTEN", ":8080"),
		DBPath:             getenv("SEREIN_DB", "serein.db"),
		HookToken:          os.Getenv("SEREIN_HOOK_TOKEN"),
		ClientToken:        getenv("SEREIN_CLIENT_TOKEN", ""),
		PairCode:           os.Getenv("SEREIN_PAIR_CODE"),
		NtfyURL:            getenv("SEREIN_NTFY_URL", "http://localhost:8090"),
		NtfyTopic:          getenv("SEREIN_NTFY_TOPIC", "serein-approvals"),
		HuaweiPushClientID: os.Getenv("SEREIN_HUAWEI_PUSH_CLIENT_ID"),
		HuaweiPushSecret:   os.Getenv("SEREIN_HUAWEI_PUSH_CLIENT_SECRET"),
		HuaweiPushOAuthURL: os.Getenv("SEREIN_HUAWEI_PUSH_OAUTH_URL"),
		HuaweiPushAPIBase:  os.Getenv("SEREIN_HUAWEI_PUSH_API_BASE"),
		ApprovalTimeoutSec: getenvInt("SEREIN_APPROVAL_TIMEOUT", 300),
		LogPath:            os.Getenv("SEREIN_LOG"),
		TLSCert:            os.Getenv("SEREIN_TLS_CERT"),
		TLSKey:             os.Getenv("SEREIN_TLS_KEY"),
	}
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func getenvInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return d
}
