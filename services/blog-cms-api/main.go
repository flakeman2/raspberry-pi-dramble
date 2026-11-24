package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	csrfHeader       = "X-CSRF-Token"
	sessionCookie    = "blog_cms_session"
	sessionTTL       = 12 * time.Hour
	verificationLine = "Devin Flake read and verified every claim against the cluster and the repository before publishing."
)

type gitHubAppConfig struct {
	ID             string
	InstallationID string
	PrivateKey     string
}

type config struct {
	Addr             string
	CookieSecure     bool
	SessionKey       []byte
	AdminHash        []byte
	GuestHash        []byte
	RateLimit        int
	RateWindow       time.Duration
	ActionRateLimit  int
	ActionRateWindow time.Duration
	TrustedProxies   []netip.Prefix
	EphesusOwner     string
	EphesusRepo      string
	DrambleOwner     string
	DrambleRepo      string
	GitHubAPIURL     string
	NtfyURL          string
	NtfyTopic        string
	Writer           gitHubAppConfig
	Publisher        gitHubAppConfig
	Approver         gitHubAppConfig
}

type server struct {
	cfg           config
	gh            *githubClient
	limiter       *rateLimiter
	actionLimiter *rateLimiter
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("configuration: %v", err)
	}

	gh, err := newGitHubClient(cfg)
	if err != nil {
		log.Fatalf("github client: %v", err)
	}

	s := &server{
		cfg:           cfg,
		gh:            gh,
		limiter:       newRateLimiter(cfg.RateLimit, cfg.RateWindow),
		actionLimiter: newRateLimiter(cfg.ActionRateLimit, cfg.ActionRateWindow),
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go s.bumpPRPoller(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /post/api/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /post/api/login", s.handleLogin)
	mux.HandleFunc("POST /post/api/logout", s.handleLogout)
	mux.HandleFunc("GET /post/api/me", s.handleMe)
	mux.HandleFunc("GET /post/api/drafts", s.handleListDrafts)
	mux.HandleFunc("POST /post/api/drafts", s.handleSaveDraft)
	mux.HandleFunc("POST /post/api/preview", s.handlePreview)
	mux.HandleFunc("POST /post/api/submit", s.handleSubmit)
	mux.HandleFunc("GET /post/api/review", s.handleReview)
	mux.HandleFunc("POST /post/api/approve", s.handleApprove)
	mux.HandleFunc("POST /post/api/publish", s.handlePublish)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           recoverMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	log.Printf("blog-cms-api listening on %s", cfg.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
}

func loadConfig() (config, error) {
	get := func(name string, required bool) (string, error) {
		v := strings.TrimSpace(os.Getenv(name))
		if required && v == "" {
			return "", fmt.Errorf("%s is required", name)
		}
		return v, nil
	}

	var cfg config
	var err error
	if cfg.Addr, err = get("ADDR", false); err != nil || cfg.Addr == "" {
		cfg.Addr = ":8080"
	}
	cfg.CookieSecure = strings.ToLower(strings.TrimSpace(os.Getenv("COOKIE_SECURE"))) != "false"

	key, err := get("SESSION_KEY", true)
	if err != nil {
		return cfg, err
	}
	if cfg.SessionKey, err = base64.StdEncoding.DecodeString(key); err != nil {
		return cfg, fmt.Errorf("SESSION_KEY must be base64: %w", err)
	}
	if len(cfg.SessionKey) < 32 {
		return cfg, fmt.Errorf("SESSION_KEY must decode to at least 32 bytes")
	}

	adminHash, err := get("ADMIN_PASSWORD_HASH", true)
	if err != nil {
		return cfg, err
	}
	guestHash, err := get("GUEST_PASSWORD_HASH", true)
	if err != nil {
		return cfg, err
	}
	cfg.AdminHash = []byte(adminHash)
	cfg.GuestHash = []byte(guestHash)
	for name, hash := range map[string][]byte{"ADMIN_PASSWORD_HASH": cfg.AdminHash, "GUEST_PASSWORD_HASH": cfg.GuestHash} {
		if _, err := bcrypt.Cost(hash); err != nil {
			return cfg, fmt.Errorf("%s is not a bcrypt hash: %w", name, err)
		}
	}

	if cfg.RateLimit, err = envInt("LOGIN_RATE_LIMIT", 5); err != nil {
		return cfg, err
	}
	if cfg.RateWindow, err = envDuration("LOGIN_RATE_WINDOW", time.Minute); err != nil {
		return cfg, err
	}
	if cfg.ActionRateLimit, err = envInt("ACTION_RATE_LIMIT", 60); err != nil {
		return cfg, err
	}
	if cfg.ActionRateWindow, err = envDuration("ACTION_RATE_WINDOW", time.Minute); err != nil {
		return cfg, err
	}
	if cfg.TrustedProxies, err = envPrefixes("TRUSTED_PROXY_CIDRS"); err != nil {
		return cfg, err
	}

	defaulted := map[string]*string{
		"EPHESUS_OWNER":  &cfg.EphesusOwner,
		"EPHESUS_REPO":   &cfg.EphesusRepo,
		"DRAMBLE_OWNER":  &cfg.DrambleOwner,
		"DRAMBLE_REPO":   &cfg.DrambleRepo,
		"GITHUB_API_URL": &cfg.GitHubAPIURL,
	}
	defaults := map[string]string{
		"EPHESUS_OWNER":  "flakeman2",
		"EPHESUS_REPO":   "Ephesus",
		"DRAMBLE_OWNER":  "flakeman2",
		"DRAMBLE_REPO":   "raspberry-pi-dramble",
		"GITHUB_API_URL": "https://api.github.com",
	}
	for name, target := range defaulted {
		v, err := get(name, false)
		if err != nil {
			return cfg, err
		}
		if v == "" {
			v = defaults[name]
		}
		*target = v
	}
	cfg.NtfyURL, _ = get("NTFY_URL", false)
	cfg.NtfyTopic, _ = get("NTFY_TOPIC", false)

	apps := []struct {
		name   string
		target *gitHubAppConfig
	}{
		{"WRITER", &cfg.Writer},
		{"PUBLISHER", &cfg.Publisher},
		{"APPROVER", &cfg.Approver},
	}
	for _, app := range apps {
		if app.target.ID, err = get(app.name+"_APP_ID", true); err != nil {
			return cfg, err
		}
		if app.target.InstallationID, err = get(app.name+"_INSTALLATION_ID", true); err != nil {
			return cfg, err
		}
		if app.target.PrivateKey, err = get(app.name+"_PRIVATE_KEY", true); err != nil {
			return cfg, err
		}
	}
	return cfg, nil
}

func envInt(name string, fallback int) (int, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return n, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", name)
	}
	return d, nil
}

func envPrefixes(name string) ([]netip.Prefix, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return nil, nil
	}
	var prefixes []netip.Prefix
	for _, item := range strings.Split(v, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(item)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func readJSON(w http.ResponseWriter, r *http.Request, target any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("request body must contain one JSON object")
	}
	return nil
}

func recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("panic serving %s: %v", r.URL.Path, rec)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
