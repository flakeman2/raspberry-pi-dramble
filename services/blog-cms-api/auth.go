package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const maxRateKeys = 4096

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
	if limit <= 0 {
		limit = 1
	}
	if window <= 0 {
		window = time.Minute
	}
	return &rateLimiter{
		attempts: make(map[string]*rateAttempt),
		limit:    limit,
		window:   window,
	}
}

func (l *rateLimiter) cleanup(now time.Time) {
	for key, attempt := range l.attempts {
		if now.After(attempt.reset) {
			delete(l.attempts, key)
		}
	}
}

// allow reports whether another attempt is currently permitted without
// consuming the budget. Login uses it before bcrypt verification so successful
// logins do not count as failures.
func (l *rateLimiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	l.cleanup(now)
	attempt, ok := l.attempts[key]
	if !ok {
		return len(l.attempts) < maxRateKeys
	}
	return attempt.count < l.limit
}

// take checks and consumes one unit of budget. It is used for authenticated
// state-changing routes, where every request is itself the event being limited.
func (l *rateLimiter) take(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	l.cleanup(now)
	attempt, ok := l.attempts[key]
	if !ok {
		if len(l.attempts) >= maxRateKeys {
			return false
		}
		l.attempts[key] = &rateAttempt{count: 1, reset: now.Add(l.window)}
		return true
	}
	if attempt.count >= l.limit {
		return false
	}
	attempt.count++
	return true
}

func (l *rateLimiter) recordFailure(key string) {
	l.take(key)
}

func (l *rateLimiter) reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
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
		key := clientIP(r, s.cfg.TrustedProxies) + "|" + sess.Role
		if !s.actionLimiter.take(key) {
			writeError(w, http.StatusTooManyRequests, "too many requests")
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

func remoteIP(remote string) netip.Addr {
	if addrPort, err := netip.ParseAddrPort(remote); err == nil {
		return addrPort.Addr()
	}
	if addr, err := netip.ParseAddr(remote); err == nil {
		return addr
	}
	return netip.Addr{}
}

func trustedIP(ip netip.Addr, prefixes []netip.Prefix) bool {
	if !ip.IsValid() {
		return false
	}
	for _, prefix := range prefixes {
		if prefix.Contains(ip) {
			return true
		}
	}
	return false
}

// clientIP only trusts X-Forwarded-For when the direct peer is a configured
// proxy. It walks the list right-to-left so a client-supplied leftmost value
// cannot reset the login budget.
func clientIP(r *http.Request, trusted []netip.Prefix) string {
	peer := remoteIP(r.RemoteAddr)
	if !peer.IsValid() {
		return r.RemoteAddr
	}
	if !trustedIP(peer, trusted) {
		return peer.String()
	}
	forwarded := strings.Join(r.Header.Values("X-Forwarded-For"), ",")
	parts := strings.Split(forwarded, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		candidate := strings.TrimSpace(parts[i])
		if candidate == "" {
			continue
		}
		ip, err := netip.ParseAddr(candidate)
		if err != nil {
			continue
		}
		if !trustedIP(ip, trusted) {
			return ip.String()
		}
	}
	return peer.String()
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
	key := clientIP(r, s.cfg.TrustedProxies)
	if !s.limiter.allow(key) {
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
		s.limiter.recordFailure(key)
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if req.Website != "" || bcrypt.CompareHashAndPassword(hash, []byte(req.Password)) != nil {
		s.limiter.recordFailure(key)
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	s.limiter.reset(key)

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
	writeJSON(w, http.StatusOK, map[string]string{"role": sess.Role, "csrf": sess.CSRF})
}
