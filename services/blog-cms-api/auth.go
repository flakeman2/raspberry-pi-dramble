package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type session struct {
	Role   string `json:"role"`
	CSRF   string `json:"csrf"`
	Expiry int64  `json:"exp"`
}

type rateLimiter struct {
	mu       sync.Mutex
	attempts map[string]*rateAttempt
	limit    int
	window   time.Duration
}

type rateAttempt struct {
	count int
	reset time.Time
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	return &rateLimiter{
		attempts: make(map[string]*rateAttempt),
		limit:    limit,
		window:   window,
	}
}

func (l *rateLimiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	for ip, attempt := range l.attempts {
		if now.After(attempt.reset) {
			delete(l.attempts, ip)
		}
	}
	attempt, ok := l.attempts[key]
	if !ok {
		l.attempts[key] = &rateAttempt{count: 1, reset: now.Add(l.window)}
		return true
	}
	if attempt.count >= l.limit {
		return false
	}
	attempt.count++
	return true
}

func encodeSession(key []byte, s session) (string, error) {
	payload, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(encoded))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return encoded + "." + signature, nil
}

func decodeSession(key []byte, raw string) (session, error) {
	var s session
	parts := strings.Split(raw, ".")
	if len(parts) != 2 {
		return s, fmt.Errorf("malformed session cookie")
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(parts[0]))
	expected := mac.Sum(nil)
	actual, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || subtle.ConstantTimeCompare(expected, actual) != 1 {
		return s, fmt.Errorf("invalid session signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return s, fmt.Errorf("invalid session payload")
	}
	if err := json.Unmarshal(payload, &s); err != nil {
		return s, fmt.Errorf("invalid session payload")
	}
	if s.Expiry <= time.Now().Unix() {
		return s, fmt.Errorf("session expired")
	}
	if s.Role != "admin" && s.Role != "guest" {
		return s, fmt.Errorf("unknown session role")
	}
	return s, nil
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func (s *server) setSession(w http.ResponseWriter, role string) (string, error) {
	csrf, err := randomToken()
	if err != nil {
		return "", err
	}
	expiry := time.Now().Add(sessionTTL)
	value, err := encodeSession(s.cfg.SessionKey, session{
		Role:   role,
		CSRF:   csrf,
		Expiry: expiry.Unix(),
	})
	if err != nil {
		return "", err
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    value,
		Path:     "/post",
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteLaxMode,
		Expires:  expiry,
		MaxAge:   int(sessionTTL.Seconds()),
	})
	return csrf, nil
}

func (s *server) clearSession(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/post",
		HttpOnly: true,
		Secure:   s.cfg.CookieSecure,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
}

func (s *server) sessionFromRequest(r *http.Request) (session, error) {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return session{}, err
	}
	return decodeSession(s.cfg.SessionKey, cookie.Value)
}

func (s *server) requireSession(w http.ResponseWriter, r *http.Request, roles ...string) (session, bool) {
	sess, err := s.sessionFromRequest(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication required")
		return sess, false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		provided := r.Header.Get(csrfHeader)
		if subtle.ConstantTimeCompare([]byte(provided), []byte(sess.CSRF)) != 1 {
			writeError(w, http.StatusForbidden, "invalid CSRF token")
			return sess, false
		}
	}
	if len(roles) > 0 && !contains(roles, sess.Role) {
		writeError(w, http.StatusForbidden, "insufficient role")
		return sess, false
	}
	return sess, true
}

func contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func clientIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		if parts := strings.Split(forwarded, ","); len(parts) > 0 {
			if ip := strings.TrimSpace(parts[0]); ip != "" {
				return ip
			}
		}
	}
	if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
		return real
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

type loginRequest struct {
	Role     string `json:"role"`
	Password string `json:"password"`
	Website  string `json:"website"`
}

func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := readJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !s.limiter.allow(clientIP(r)) {
		writeError(w, http.StatusTooManyRequests, "too many login attempts")
		return
	}

	var hash []byte
	switch req.Role {
	case "admin":
		hash = s.cfg.AdminHash
	case "guest":
		hash = s.cfg.GuestHash
	default:
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if req.Website != "" || bcrypt.CompareHashAndPassword(hash, []byte(req.Password)) != nil {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	csrf, err := s.setSession(w, req.Role)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"role": req.Role, "csrf": csrf})
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireSession(w, r); !ok {
		return
	}
	s.clearSession(w)
	writeJSON(w, http.StatusOK, map[string]string{"status": "logged out"})
}

func (s *server) handleMe(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.requireSession(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"role": sess.Role})
}
