package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const validPost = `---
title: "A test post"
date: 2026-11-24T00:00:00Z
author: Devin Flake
layout: post
permalink: /a-test-post/
tags: [test, jekyll]
ai_models:
  - MiMo-V2.6-Flash
verification: "Devin Flake read and verified every claim against the cluster and the repository before publishing."
---

AI models discussed: MiMo-V2.6-Flash

| Item | Value |
| --- | --- |
| Cluster | healthy |
`

func testServer(t *testing.T) *server {
	t.Helper()
	adminHash, err := bcrypt.GenerateFromPassword([]byte("admin-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	guestHash, err := bcrypt.GenerateFromPassword([]byte("guest-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	return &server{
		cfg: config{
			SessionKey:   bytes.Repeat([]byte("k"), 32),
			AdminHash:    adminHash,
			GuestHash:    guestHash,
			CookieSecure: false,
		},
		limiter:       newRateLimiter(10, time.Minute),
		actionLimiter: newRateLimiter(60, time.Minute),
	}
}

func doRequest(t *testing.T, s *server, method, path, body string, cookie *http.Cookie, csrf string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	if csrf != "" {
		req.Header.Set(csrfHeader, csrf)
	}
	w := httptest.NewRecorder()
	switch path {
	case "/post/api/login":
		s.handleLogin(w, req)
	case "/post/api/me":
		s.handleMe(w, req)
	case "/post/api/preview":
		s.handlePreview(w, req)
	default:
		t.Fatalf("unexpected path %s", path)
	}
	return w
}

func TestSessionRoundTripAndTamper(t *testing.T) {
	key := bytes.Repeat([]byte("s"), 32)
	original := session{Role: "admin", CSRF: "csrf-token", Expiry: time.Now().Add(time.Hour).Unix()}
	encoded, err := encodeSession(key, original)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeSession(key, encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Role != original.Role || decoded.CSRF != original.CSRF {
		t.Fatalf("session round trip changed values: %+v", decoded)
	}

	parts := strings.Split(encoded, ".")
	parts[1] = base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte("x"), 32))
	if _, err := decodeSession(key, strings.Join(parts, ".")); err == nil {
		t.Fatal("tampered session signature was accepted")
	}
}

func TestPostValidation(t *testing.T) {
	doc, err := parsePost(validPost)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err != nil {
		t.Fatalf("valid post rejected: %v", err)
	}
	if doc.slug() != "a-test-post" {
		t.Fatalf("unexpected slug %q", doc.slug())
	}

	// With no ai_models front matter, the body disclosure is optional.
	optional := strings.Replace(validPost, "  - MiMo-V2.6-Flash\nverification:", "verification:", 1)
	optional = strings.Replace(optional, "AI models discussed: MiMo-V2.6-Flash", "", 1)
	doc, err = parsePost(optional)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err != nil {
		t.Fatalf("post without AI disclosure was rejected: %v", err)
	}

	// Once ai_models is present, every listed model must still be credited.
	uncredited := strings.Replace(validPost, "AI models discussed: MiMo-V2.6-Flash", "AI models discussed:", 1)
	doc, err = parsePost(uncredited)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err == nil {
		t.Fatal("post listing an uncredited AI model was accepted")
	}

	badVerification := strings.Replace(validPost, verificationLine, "looks good to me", 1)
	doc, err = parsePost(badVerification)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err == nil {
		t.Fatal("post with wrong verification line was accepted")
	}
}

func TestMarkdownRenderUsesGFM(t *testing.T) {
	doc, err := parsePost(validPost)
	if err != nil {
		t.Fatal(err)
	}
	html, err := doc.render()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"<table>", "<td>Cluster</td>", "<td>healthy</td>"} {
		if !strings.Contains(html, want) {
			t.Fatalf("rendered HTML missing %q: %s", want, html)
		}
	}
}

func TestRateLimiter(t *testing.T) {
	limiter := newRateLimiter(2, time.Minute)
	if !limiter.take("192.0.2.1") || !limiter.take("192.0.2.1") {
		t.Fatal("first two attempts should be allowed")
	}
	if limiter.take("192.0.2.1") {
		t.Fatal("third attempt should be blocked")
	}
	if limiter.allow("192.0.2.1") {
		t.Fatal("allow must report an exhausted budget")
	}
	if !limiter.take("192.0.2.2") {
		t.Fatal("different IP should be allowed")
	}

	limiter.reset("192.0.2.1")
	if !limiter.allow("192.0.2.1") {
		t.Fatal("reset should clear the budget")
	}
}

func TestLoginMeAndCSRF(t *testing.T) {
	s := testServer(t)
	body := `{"role":"admin","password":"admin-password","website":""}`
	login := doRequest(t, s, http.MethodPost, "/post/api/login", body, nil, "")
	if login.Code != http.StatusOK {
		t.Fatalf("login status %d: %s", login.Code, login.Body.String())
	}
	var loginResult struct {
		Role string `json:"role"`
		CSRF string `json:"csrf"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &loginResult); err != nil {
		t.Fatal(err)
	}
	if loginResult.Role != "admin" || loginResult.CSRF == "" {
		t.Fatalf("unexpected login result: %+v", loginResult)
	}
	cookies := login.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != sessionCookie || !cookies[0].HttpOnly {
		t.Fatalf("unexpected session cookie: %+v", cookies)
	}
	cookie := cookies[0]

	me := doRequest(t, s, http.MethodGet, "/post/api/me", "", cookie, "")
	if me.Code != http.StatusOK || !strings.Contains(me.Body.String(), `"admin"`) {
		t.Fatalf("me status %d: %s", me.Code, me.Body.String())
	}

	previewBody, err := json.Marshal(map[string]string{"content": validPost})
	if err != nil {
		t.Fatal(err)
	}
	withoutCSRF := doRequest(t, s, http.MethodPost, "/post/api/preview", string(previewBody), cookie, "")
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("preview without CSRF status %d: %s", withoutCSRF.Code, withoutCSRF.Body.String())
	}
	withCSRF := doRequest(t, s, http.MethodPost, "/post/api/preview", string(previewBody), cookie, loginResult.CSRF)
	if withCSRF.Code != http.StatusOK || !strings.Contains(withCSRF.Body.String(), "a-test-post") {
		t.Fatalf("preview with CSRF status %d: %s", withCSRF.Code, withCSRF.Body.String())
	}

	badLogin := doRequest(t, s, http.MethodPost, "/post/api/login", `{"role":"admin","password":"wrong"}`, nil, "")
	if badLogin.Code != http.StatusUnauthorized {
		t.Fatalf("bad login status %d", badLogin.Code)
	}
}

func TestAppJWTSigning(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	token, err := appJWT("12345", key)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("unexpected JWT shape: %d parts", len(parts))
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(header), `"RS256"`) {
		t.Fatalf("unexpected JWT header: %s", header)
	}
	claims, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(claims), `"iss":"12345"`) {
		t.Fatalf("unexpected JWT claims: %s", claims)
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Fatalf("JWT signature did not verify: %v", err)
	}
}

func TestClientIPIgnoresSpoofedForwardedFor(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("10.42.0.0/16")}
	req := httptest.NewRequest(http.MethodPost, "/post/api/login", nil)
	req.RemoteAddr = "10.42.0.206:12345"
	req.Header.Set("X-Forwarded-For", "203.0.113.9, 10.42.0.206")
	req.Header.Set("X-Real-IP", "198.51.100.9")

	got := clientIP(req, trusted)
	if got != "203.0.113.9" {
		t.Fatalf("clientIP = %q, want rightmost untrusted XFF value", got)
	}

	direct := httptest.NewRequest(http.MethodPost, "/post/api/login", nil)
	direct.RemoteAddr = "198.51.100.20:54321"
	direct.Header.Set("X-Forwarded-For", "203.0.113.9")
	if got := clientIP(direct, trusted); got != "198.51.100.20" {
		t.Fatalf("clientIP = %q, want direct peer when it is not trusted", got)
	}
}

func TestSuccessfulLoginsDoNotConsumeFailureBudget(t *testing.T) {
	s := testServer(t)
	s.limiter = newRateLimiter(2, time.Minute)
	for i := 0; i < 5; i++ {
		login := doRequest(t, s, http.MethodPost, "/post/api/login", `{"role":"admin","password":"admin-password","website":""}`, nil, "")
		if login.Code != http.StatusOK {
			t.Fatalf("successful login %d returned %d: %s", i+1, login.Code, login.Body.String())
		}
	}
	for i := 0; i < 2; i++ {
		bad := doRequest(t, s, http.MethodPost, "/post/api/login", `{"role":"admin","password":"wrong","website":""}`, nil, "")
		if bad.Code != http.StatusUnauthorized {
			t.Fatalf("bad login %d status %d", i+1, bad.Code)
		}
	}
	blocked := doRequest(t, s, http.MethodPost, "/post/api/login", `{"role":"admin","password":"wrong","website":""}`, nil, "")
	if blocked.Code != http.StatusTooManyRequests {
		t.Fatalf("third bad login status %d", blocked.Code)
	}
}

func TestMeReturnsCSRF(t *testing.T) {
	s := testServer(t)
	login := doRequest(t, s, http.MethodPost, "/post/api/login", `{"role":"admin","password":"admin-password","website":""}`, nil, "")
	cookie := login.Result().Cookies()[0]
	var result struct {
		CSRF string `json:"csrf"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	me := doRequest(t, s, http.MethodGet, "/post/api/me", "", cookie, "")
	var meResult struct {
		Role string `json:"role"`
		CSRF string `json:"csrf"`
	}
	if err := json.Unmarshal(me.Body.Bytes(), &meResult); err != nil {
		t.Fatal(err)
	}
	if meResult.Role != "admin" || meResult.CSRF != result.CSRF {
		t.Fatalf("/me did not return the session CSRF token: %+v", meResult)
	}
}

func TestBumpPRRequiresTrustedHead(t *testing.T) {
	c := &githubClient{cfg: config{DrambleOwner: "flakeman2", DrambleRepo: "raspberry-pi-dramble"}}
	makePR := func(headRepo, state, base, ref string) pullRequest {
		var pr pullRequest
		pr.Number = 42
		pr.State = state
		pr.Base.Ref = base
		pr.Head.Ref = ref
		pr.Head.Repo.FullName = headRepo
		return pr
	}

	good := makePR("flakeman2/raspberry-pi-dramble", "open", "dev", "bump/jekyll-sha-abcdef0")
	if !c.isBumpPR(good) {
		t.Fatal("same-repository bump PR was rejected")
	}
	fork := makePR("attacker/raspberry-pi-dramble", "open", "dev", "bump/jekyll-sha-abcdef0")
	if c.isBumpPR(fork) {
		t.Fatal("fork bump PR was accepted")
	}
	wrongBase := makePR("flakeman2/raspberry-pi-dramble", "open", "master", "bump/jekyll-sha-abcdef0")
	if c.isBumpPR(wrongBase) {
		t.Fatal("PR against master was accepted")
	}
	closed := makePR("flakeman2/raspberry-pi-dramble", "closed", "dev", "bump/jekyll-sha-abcdef0")
	if c.isBumpPR(closed) {
		t.Fatal("closed PR was accepted")
	}
}

func TestFrontMatterRejectsDuplicateKeysAndLooseVerification(t *testing.T) {
	duplicate := strings.Replace(validPost, "title: \"A test post\"", "title: \"A test post\"\ntitle: \"Another title\"", 1)
	if _, err := parsePost(duplicate); err == nil {
		t.Fatal("duplicate front matter key was accepted")
	}

	looseVerification := strings.Replace(validPost, verificationLine, verificationLine+" ", 1)
	doc, err := parsePost(looseVerification)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err == nil {
		t.Fatal("verification statement with trailing space was accepted")
	}
}
