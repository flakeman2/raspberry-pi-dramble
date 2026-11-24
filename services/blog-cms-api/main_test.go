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
		limiter: newRateLimiter(10, time.Minute),
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

	bad := strings.Replace(validPost, "  - MiMo-V2.6-Flash\nverification:", "verification:", 1)
	bad = strings.Replace(bad, "AI models discussed: MiMo-V2.6-Flash", "AI models discussed:", 1)
	doc, err = parsePost(bad)
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.validate(); err == nil {
		t.Fatal("post missing AI disclosure was accepted")
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
	if !limiter.allow("192.0.2.1") || !limiter.allow("192.0.2.1") {
		t.Fatal("first two attempts should be allowed")
	}
	if limiter.allow("192.0.2.1") {
		t.Fatal("third attempt should be blocked")
	}
	if !limiter.allow("192.0.2.2") {
		t.Fatal("different IP should be allowed")
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
