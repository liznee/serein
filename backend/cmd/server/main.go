package main

import (
	"log/slog"
	"net/http"
	"os"
	"strings"

	"serein/internal/api"
	"serein/internal/approval"
	"serein/internal/config"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/pushkit"
	"serein/internal/risk"
	"serein/internal/store"
)

// BuildVersion 编译时注入 (go build -ldflags "-X main.BuildVersion=x.y.z")
var BuildVersion = "1.0.0"

func main() {
	cfg := config.Load()

	logger, err := rdplog.Open(cfg.LogPath)
	if err != nil {
		panic("open log: " + err.Error())
	}
	logger.Event(rdplog.EventStartup, "serein backend v"+BuildVersion)

	db, err := store.Open(cfg.DBPath)
	if err != nil {
		panic("open db: " + err.Error())
	}
	defer db.Close()

	svc := approval.NewService(db, cfg.ApprovalTimeoutSec)
	pub := notify.New(cfg.NtfyURL, cfg.NtfyTopic)

	wlRepo := store.NewWhitelistRepo(db)
	blRepo := store.NewBlacklistRepo(db)
	sessionRepo := store.NewSessionRepo(db)
	engine := risk.New(blRepo, wlRepo, sessionRepo)

	deviceRepo := store.NewDeviceRepo(db)
	devHandler := api.NewDeviceHandler(deviceRepo, cfg.PairCode)
	pushDispatcher := pushkit.New(pushkit.Config{
		ClientID:     cfg.HuaweiPushClientID,
		ClientSecret: cfg.HuaweiPushSecret,
		OAuthURL:     cfg.HuaweiPushOAuthURL,
		APIBaseURL:   cfg.HuaweiPushAPIBase,
	}, deviceRepo)
	devHandler.SetPushDeliveryEnabled(pushDispatcher.Configured())

	cfgHandler := api.NewConfigHandler(wlRepo, blRepo, engine)
	sysInfoRepo := store.NewSysInfoRepo(db)

	envMode := strings.ToLower(strings.TrimSpace(os.Getenv("SEREIN_ENV")))
	// Development mode must be explicitly selected. An unset/unknown value is
	// treated as production so a deployment cannot silently disable auth.
	devMode := envMode == "development" || envMode == "dev"
	tlsEnabled := cfg.TLSCert != "" && cfg.TLSKey != ""
	router := api.NewRouter(api.RouterConfig{
		HookToken:         cfg.HookToken,
		GlobalClientToken: cfg.ClientToken,
		PairCode:          cfg.PairCode,
		DevMode:           devMode,
		TLS:               tlsEnabled,
		Svc:               svc,
		Pub:               pub,
		Engine:            engine,
		SessionRepo:       sessionRepo,
		DeviceRepo:        deviceRepo,
		DevHandler:        devHandler,
		CfgHandler:        cfgHandler,
		Logger:            logger,
		Version:           BuildVersion,
		SysInfoRepo:       sysInfoRepo,
		PushDispatcher:    pushDispatcher,
	})

	logger.Event(rdplog.EventStartup, "serein backend starting",
		slog.String("listen", cfg.Listen),
		slog.String("db", cfg.DBPath),
		slog.String("ntfy_url", cfg.NtfyURL),
		slog.String("ntfy_topic", cfg.NtfyTopic),
		slog.Bool("dev_mode", devMode),
		slog.Bool("tls", tlsEnabled),
		slog.Bool("huawei_push", pushDispatcher.Configured()),
	)
	if cfg.HookToken == "" {
		if !devMode {
			panic("SEREIN_HOOK_TOKEN must be set in production (refusing to start)")
		}
		slog.Warn("SEREIN_HOOK_TOKEN not set, hook auth disabled (dev mode only; set SEREIN_ENV=production to enforce)")
	}
	if !devMode && (cfg.PairCode == "" || cfg.PairCode == "serein-pair-me") {
		panic("SEREIN_PAIR_CODE must be set to a non-default value in production (refusing to start)")
	}
	// CLIENT_TOKEN 现为 per-device(查 DB),不再强制 env;生产靠配对设备 token 鉴权。
	// globalClientToken 仅作 dev/测试后门,生产必须留空——否则构成全局认证后门。
	if cfg.ClientToken != "" && !devMode {
		panic("SEREIN_CLIENT_TOKEN (global backdoor) must be empty in production — refusing to start")
	}
	// 生产模式强制 TLS: 阻止明文 HTTP 暴露 token(包括 WS 升级前的 Authorization 头
	// 和 join 消息中的 token 字段)。如果使用反向代理终止 TLS,可不设 TLSCert/TLSKey,
	// 但必须确保代理到后端的链路是可信网络(localhost/UNIX socket)。
	if !devMode && !tlsEnabled {
		slog.Warn("TLS not enabled in production mode — tokens may be exposed in plaintext. Set SEREIN_TLS_CERT and SEREIN_TLS_KEY, or use a reverse proxy with TLS.")
	}
	if tlsEnabled {
		slog.Info("starting HTTPS/WSS server", slog.String("cert", cfg.TLSCert))
		if err := http.ListenAndServeTLS(cfg.Listen, cfg.TLSCert, cfg.TLSKey, router); err != nil {
			panic("server: " + err.Error())
		}
	} else {
		if err := http.ListenAndServe(cfg.Listen, router); err != nil {
			panic("server: " + err.Error())
		}
	}
}
