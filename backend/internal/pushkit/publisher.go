// Package pushkit sends minimal HarmonyOS notification messages through
// Huawei Push Kit. Push tokens and OAuth credentials are never logged.
package pushkit

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"serein/internal/store"
)

const (
	defaultOAuthURL  = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
	defaultAPIBase   = "https://push-api.cloud.huawei.com/v1"
	defaultAttempts  = 3
	defaultRetryBase = 350 * time.Millisecond
)

type deliveryError struct {
	err       error
	retryable bool
}

func (e *deliveryError) Error() string { return e.err.Error() }
func (e *deliveryError) Unwrap() error { return e.err }

func failDelivery(err error, retryable bool) error {
	return &deliveryError{err: err, retryable: retryable}
}

func canRetry(err error) bool {
	var deliveryErr *deliveryError
	return errors.As(err, &deliveryErr) && deliveryErr.retryable
}

// Config contains only environment-injected server credentials. None of these
// values belongs in the mobile app, public source archive, or application log.
type Config struct {
	ClientID     string
	ClientSecret string
	OAuthURL     string
	APIBaseURL   string
}

type approvalJob struct {
	ID        string
	RiskLevel string
	Project   string
}

// Dispatcher owns one bounded worker so an upstream Push outage cannot block
// approval creation or create an unbounded number of goroutines.
type Dispatcher struct {
	cfg        Config
	repo       *store.DeviceRepo
	httpClient *http.Client
	jobs       chan approvalJob

	tokenMu      sync.Mutex
	accessToken  string
	tokenExpires time.Time

	dedupeMu sync.Mutex
	seen     map[string]time.Time

	maxAttempts int
	retryBase   time.Duration
}

func New(cfg Config, repo *store.DeviceRepo) *Dispatcher {
	cfg.ClientID = strings.TrimSpace(cfg.ClientID)
	cfg.ClientSecret = strings.TrimSpace(cfg.ClientSecret)
	if strings.TrimSpace(cfg.OAuthURL) == "" {
		cfg.OAuthURL = defaultOAuthURL
	}
	if strings.TrimSpace(cfg.APIBaseURL) == "" {
		cfg.APIBaseURL = defaultAPIBase
	}
	d := &Dispatcher{
		cfg:         cfg,
		repo:        repo,
		httpClient:  &http.Client{Timeout: 8 * time.Second},
		jobs:        make(chan approvalJob, 64),
		seen:        make(map[string]time.Time),
		maxAttempts: defaultAttempts,
		retryBase:   defaultRetryBase,
	}
	if d.Configured() {
		go d.run()
	}
	return d
}

func (d *Dispatcher) Configured() bool {
	return d != nil && d.repo != nil && d.cfg.ClientID != "" && d.cfg.ClientSecret != ""
}

// EnqueueApproval accepts only non-sensitive routing data. The command,
// working directory, diff, and credentials never enter Push Kit.
func (d *Dispatcher) EnqueueApproval(id, riskLevel, project string) bool {
	if !d.Configured() || strings.TrimSpace(id) == "" {
		return false
	}
	if !d.markOnce(id) {
		return true
	}
	select {
	case d.jobs <- approvalJob{ID: id, RiskLevel: riskLevel, Project: project}:
		return true
	default:
		d.unmark(id)
		slog.Warn("push kit queue full", "approval_id", id)
		return false
	}
}

func (d *Dispatcher) run() {
	for job := range d.jobs {
		err := d.deliverApproval(job)
		if err != nil {
			d.unmark(job.ID)
			// No token or credential is included in the error path.
			slog.Warn("push kit notification failed", "approval_id", job.ID, "error", err)
		}
	}
}

func (d *Dispatcher) deliverApproval(job approvalJob) error {
	var lastErr error
	for attempt := 1; attempt <= d.maxAttempts; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		lastErr = d.sendApproval(ctx, job)
		cancel()
		if lastErr == nil {
			return nil
		}
		if attempt == d.maxAttempts || !canRetry(lastErr) {
			return lastErr
		}
		time.Sleep(d.retryBase * time.Duration(attempt))
	}
	return lastErr
}

func (d *Dispatcher) sendApproval(ctx context.Context, job approvalJob) error {
	targets, err := d.repo.PushTargets(ctx)
	if err != nil {
		return failDelivery(fmt.Errorf("load targets: %w", err), true)
	}
	if len(targets) == 0 {
		return nil
	}
	tokens := make([]string, 0, len(targets))
	for _, target := range targets {
		if target.Token != "" {
			tokens = append(tokens, target.Token)
		}
	}
	if len(tokens) == 0 {
		return nil
	}

	accessToken, err := d.getAccessToken(ctx)
	if err != nil {
		return err
	}
	title := "Serein 待审批"
	body := "有一项操作需要你确认"
	project := sanitizeProjectForNotification(job.Project)
	if project != "" && project != "default" {
		body = project + " 有一项操作需要你确认"
	}
	if job.RiskLevel == "red" {
		title = "Serein 高风险审批"
	}
	dataRaw, err := json.Marshal(map[string]string{
		"kind": "approval",
		"id":   job.ID,
	})
	if err != nil {
		return failDelivery(fmt.Errorf("encode notification data: %w", err), false)
	}
	payload := map[string]interface{}{
		"validate_only": false,
		"message": map[string]interface{}{
			"android": map[string]interface{}{
				"notification": map[string]interface{}{
					"title":           title,
					"body":            body,
					"foreground_show": false,
					"click_action": map[string]interface{}{
						"type": 3,
					},
				},
			},
			"data":  string(dataRaw),
			"token": tokens,
		},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return failDelivery(fmt.Errorf("encode request: %w", err), false)
	}
	endpoint := strings.TrimRight(d.cfg.APIBaseURL, "/") + "/" + url.PathEscape(d.cfg.ClientID) + "/messages:send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return failDelivery(fmt.Errorf("create request: %w", err), false)
	}
	req.Header.Set("Content-Type", "application/json; charset=UTF-8")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return failDelivery(fmt.Errorf("send request: %w", err), true)
	}
	defer resp.Body.Close()
	respRaw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return failDelivery(fmt.Errorf("read response: %w", err), true)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp.StatusCode == http.StatusUnauthorized {
			d.invalidateAccessToken()
		}
		retryable := resp.StatusCode == http.StatusRequestTimeout || resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500
		return failDelivery(fmt.Errorf("send status %d", resp.StatusCode), retryable)
	}
	var result struct {
		Code string `json:"code"`
		Msg  string `json:"msg"`
	}
	if len(respRaw) > 0 && json.Unmarshal(respRaw, &result) == nil && result.Code != "" && result.Code != "80000000" {
		return failDelivery(fmt.Errorf("send rejected: code=%s", result.Code), false)
	}
	return nil
}

func sanitizeProjectForNotification(project string) string {
	project = strings.Join(strings.Fields(project), " ")
	if project == "" {
		return ""
	}
	runes := []rune(project)
	const maxProjectRunes = 48
	if len(runes) > maxProjectRunes {
		return string(runes[:maxProjectRunes]) + "…"
	}
	return project
}

func (d *Dispatcher) getAccessToken(ctx context.Context) (string, error) {
	d.tokenMu.Lock()
	defer d.tokenMu.Unlock()
	if d.accessToken != "" && time.Now().Add(2*time.Minute).Before(d.tokenExpires) {
		return d.accessToken, nil
	}
	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", d.cfg.ClientID)
	form.Set("client_secret", d.cfg.ClientSecret)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.cfg.OAuthURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", failDelivery(fmt.Errorf("create oauth request: %w", err), false)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := d.httpClient.Do(req)
	if err != nil {
		return "", failDelivery(fmt.Errorf("oauth request: %w", err), true)
	}
	defer resp.Body.Close()
	respRaw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return "", failDelivery(fmt.Errorf("read oauth response: %w", err), true)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		retryable := resp.StatusCode == http.StatusRequestTimeout || resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500
		return "", failDelivery(fmt.Errorf("oauth status %d", resp.StatusCode), retryable)
	}
	var result struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(respRaw, &result); err != nil {
		return "", failDelivery(fmt.Errorf("decode oauth response: %w", err), false)
	}
	if result.AccessToken == "" {
		return "", failDelivery(errors.New("oauth response missing access token"), false)
	}
	if result.ExpiresIn <= 0 {
		result.ExpiresIn = 3600
	}
	d.accessToken = result.AccessToken
	d.tokenExpires = time.Now().Add(time.Duration(result.ExpiresIn) * time.Second)
	return d.accessToken, nil
}

func (d *Dispatcher) invalidateAccessToken() {
	d.tokenMu.Lock()
	d.accessToken = ""
	d.tokenExpires = time.Time{}
	d.tokenMu.Unlock()
}

func (d *Dispatcher) markOnce(id string) bool {
	d.dedupeMu.Lock()
	defer d.dedupeMu.Unlock()
	if _, exists := d.seen[id]; exists {
		return false
	}
	now := time.Now()
	d.seen[id] = now
	if len(d.seen) > 512 {
		cutoff := now.Add(-24 * time.Hour)
		for key, seenAt := range d.seen {
			if seenAt.Before(cutoff) {
				delete(d.seen, key)
			}
		}
	}
	return true
}

func (d *Dispatcher) unmark(id string) {
	d.dedupeMu.Lock()
	delete(d.seen, id)
	d.dedupeMu.Unlock()
}
