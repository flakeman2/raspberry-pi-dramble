package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"crypto/x509"
)

type githubAppAuth struct {
	id             string
	installationID string
	key            *rsa.PrivateKey
	mu             sync.Mutex
	token          string
	expires        time.Time
}

type githubClient struct {
	cfg       config
	writer    *githubAppAuth
	publisher *githubAppAuth
	approver  *githubAppAuth
	http      *http.Client
	apiURL    string
}

type githubError struct {
	StatusCode int
	Status     string
	Message    string
}

func (e *githubError) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("github %s", e.Status)
	}
	return fmt.Sprintf("github %s: %s", e.Status, e.Message)
}

type gitRef struct {
	Ref    string `json:"ref"`
	Object struct {
		SHA string `json:"sha"`
	} `json:"object"`
}

type contentFile struct {
	SHA      string `json:"sha"`
	Content  string `json:"content"`
	Encoding string `json:"encoding"`
}

type pullRequest struct {
	Number  int    `json:"number"`
	Title   string `json:"title"`
	HTMLURL string `json:"html_url"`
	State   string `json:"state"`
	Head    struct {
		Ref  string `json:"ref"`
		SHA  string `json:"sha"`
		Repo struct {
			FullName string `json:"full_name"`
		} `json:"repo"`
		User struct {
			Login string `json:"login"`
		} `json:"user"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
	Labels []struct {
		Name string `json:"name"`
	} `json:"labels"`
}

func newGitHubClient(cfg config) (*githubClient, error) {
	writer, err := newAppAuth(cfg.Writer)
	if err != nil {
		return nil, fmt.Errorf("cms-writer private key: %w", err)
	}
	publisher, err := newAppAuth(cfg.Publisher)
	if err != nil {
		return nil, fmt.Errorf("cms-publisher private key: %w", err)
	}
	approver, err := newAppAuth(cfg.Approver)
	if err != nil {
		return nil, fmt.Errorf("cms-approver private key: %w", err)
	}
	return &githubClient{
		cfg:       cfg,
		writer:    writer,
		publisher: publisher,
		approver:  approver,
		http:      &http.Client{Timeout: 20 * time.Second},
		apiURL:    strings.TrimRight(cfg.GitHubAPIURL, "/"),
	}, nil
}

func newAppAuth(cfg gitHubAppConfig) (*githubAppAuth, error) {
	key, err := parsePrivateKey(cfg.PrivateKey)
	if err != nil {
		return nil, err
	}
	return &githubAppAuth{
		id:             cfg.ID,
		installationID: cfg.InstallationID,
		key:            key,
	}, nil
}

func parsePrivateKey(raw string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(raw))
	if block == nil {
		return nil, fmt.Errorf("no PEM block found")
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("private key is not RSA")
	}
	return key, nil
}

func appJWT(appID string, key *rsa.PrivateKey) (string, error) {
	now := time.Now()
	header, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{
		"iat": now.Add(-time.Minute).Unix(),
		"exp": now.Add(9 * time.Minute).Unix(),
		"iss": appID,
	})
	if err != nil {
		return "", err
	}
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func (a *githubAppAuth) installationToken(ctx context.Context, client *http.Client, apiURL string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.token != "" && time.Now().Add(time.Minute).Before(a.expires) {
		return a.token, nil
	}
	jwt, err := appJWT(a.id, a.key)
	if err != nil {
		return "", err
	}
	endpoint := apiURL + "/app/installations/" + url.PathEscape(a.installationID) + "/access_tokens"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader("{}"))
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return "", &githubError{StatusCode: resp.StatusCode, Status: resp.Status, Message: strings.TrimSpace(string(body))}
	}
	var result struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.Token == "" {
		return "", fmt.Errorf("github returned an empty installation token")
	}
	a.token = result.Token
	a.expires = result.ExpiresAt
	return a.token, nil
}

func (a *githubAppAuth) invalidate() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.token = ""
	a.expires = time.Time{}
}

func (c *githubClient) do(ctx context.Context, app *githubAppAuth, method, path string, body any, out any) error {
	var payload []byte
	if body != nil {
		var err error
		payload, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	for attempt := 0; attempt < 2; attempt++ {
		token, err := app.installationToken(ctx, c.http, c.apiURL)
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, method, c.apiURL+path, bytes.NewReader(payload))
		if err != nil {
			return err
		}
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		if payload != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := c.http.Do(req)
		if err != nil {
			return err
		}
		if resp.StatusCode == http.StatusUnauthorized && attempt == 0 {
			_ = resp.Body.Close()
			app.invalidate()
			continue
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			responseBody, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
			return &githubError{
				StatusCode: resp.StatusCode,
				Status:     resp.Status,
				Message:    strings.TrimSpace(string(responseBody)),
			}
		}
		if out != nil {
			return json.NewDecoder(resp.Body).Decode(out)
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 8<<10))
		return nil
	}
	return fmt.Errorf("github request failed after token refresh")
}

func isGitHubNotFound(err error) bool {
	var ghErr *githubError
	return errors.As(err, &ghErr) && ghErr.StatusCode == http.StatusNotFound
}

func (c *githubClient) refSHA(ctx context.Context, app *githubAppAuth, owner, repo, branch string) (string, error) {
	var ref gitRef
	path := fmt.Sprintf("/repos/%s/%s/git/ref/heads/%s", owner, repo, url.PathEscape(branch))
	if err := c.do(ctx, app, http.MethodGet, path, nil, &ref); err != nil {
		return "", err
	}
	return ref.Object.SHA, nil
}

func (c *githubClient) branchExists(ctx context.Context, app *githubAppAuth, owner, repo, branch string) (bool, error) {
	_, err := c.refSHA(ctx, app, owner, repo, branch)
	if err == nil {
		return true, nil
	}
	if isGitHubNotFound(err) {
		return false, nil
	}
	return false, err
}

func (c *githubClient) createBranch(ctx context.Context, app *githubAppAuth, owner, repo, branch, sha string) error {
	path := fmt.Sprintf("/repos/%s/%s/git/refs", owner, repo)
	body := map[string]string{"ref": "refs/heads/" + branch, "sha": sha}
	return c.do(ctx, app, http.MethodPost, path, body, nil)
}

func (c *githubClient) getFileSHA(ctx context.Context, app *githubAppAuth, owner, repo, path, branch string) (string, error) {
	endpoint := fmt.Sprintf("/repos/%s/%s/contents/%s?ref=%s", owner, repo, path, url.QueryEscape(branch))
	var file contentFile
	if err := c.do(ctx, app, http.MethodGet, endpoint, nil, &file); err != nil {
		if isGitHubNotFound(err) {
			return "", nil
		}
		return "", err
	}
	return file.SHA, nil
}

func (c *githubClient) putFile(ctx context.Context, app *githubAppAuth, owner, repo, path, branch, content, message, sha string) error {
	endpoint := fmt.Sprintf("/repos/%s/%s/contents/%s", owner, repo, path)
	body := map[string]any{
		"message": message,
		"content": base64.StdEncoding.EncodeToString([]byte(content)),
		"branch":  branch,
	}
	if sha != "" {
		body["sha"] = sha
	}
	return c.do(ctx, app, http.MethodPut, endpoint, body, nil)
}

func (c *githubClient) createPR(ctx context.Context, app *githubAppAuth, owner, repo, head, base, title, body string) (*pullRequest, error) {
	endpoint := fmt.Sprintf("/repos/%s/%s/pulls", owner, repo)
	payload := map[string]any{
		"title": title,
		"head":  head,
		"base":  base,
		"body":  body,
		"draft": false,
	}
	var pr pullRequest
	if err := c.do(ctx, app, http.MethodPost, endpoint, payload, &pr); err != nil {
		return nil, err
	}
	return &pr, nil
}

func (c *githubClient) listOpenPRs(ctx context.Context, app *githubAppAuth, owner, repo, base string) ([]pullRequest, error) {
	var all []pullRequest
	for page := 1; page <= 10; page++ {
		endpoint := fmt.Sprintf("/repos/%s/%s/pulls?state=open&base=%s&per_page=100&page=%d", owner, repo, url.QueryEscape(base), page)
		var pagePRs []pullRequest
		if err := c.do(ctx, app, http.MethodGet, endpoint, nil, &pagePRs); err != nil {
			return nil, err
		}
		all = append(all, pagePRs...)
		if len(pagePRs) < 100 {
			return all, nil
		}
	}
	return all, nil
}

func (c *githubClient) getPR(ctx context.Context, app *githubAppAuth, owner, repo string, number int) (*pullRequest, error) {
	endpoint := fmt.Sprintf("/repos/%s/%s/pulls/%d", owner, repo, number)
	var pr pullRequest
	if err := c.do(ctx, app, http.MethodGet, endpoint, nil, &pr); err != nil {
		return nil, err
	}
	return &pr, nil
}

func (c *githubClient) approvePR(ctx context.Context, app *githubAppAuth, owner, repo string, number int) error {
	endpoint := fmt.Sprintf("/repos/%s/%s/pulls/%d/reviews", owner, repo, number)
	return c.do(ctx, app, http.MethodPost, endpoint, map[string]string{"event": "APPROVE"}, nil)
}

func (c *githubClient) mergePR(ctx context.Context, app *githubAppAuth, owner, repo string, number int) error {
	endpoint := fmt.Sprintf("/repos/%s/%s/pulls/%d/merge", owner, repo, number)
	body := map[string]any{
		"merge_method":   "squash",
		"commit_message": fmt.Sprintf("Merge blog CMS pull request #%d", number),
	}
	return c.do(ctx, app, http.MethodPut, endpoint, body, nil)
}

func (c *githubClient) addLabels(ctx context.Context, app *githubAppAuth, owner, repo string, number int, labels ...string) error {
	endpoint := fmt.Sprintf("/repos/%s/%s/issues/%d/labels", owner, repo, number)
	return c.do(ctx, app, http.MethodPost, endpoint, map[string]any{"labels": labels}, nil)
}

func (s *server) bumpPRPoller(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		s.reconcileBumpPRs(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *server) reconcileBumpPRs(ctx context.Context) {
	pollCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	prs, err := s.gh.listOpenPRs(pollCtx, s.gh.approver, s.cfg.DrambleOwner, s.cfg.DrambleRepo, "dev")
	if err != nil {
		log.Printf("bump PR poll failed: %v", err)
		return
	}
	for _, pr := range prs {
		if !s.gh.isBumpPR(pr) {
			continue
		}
		if err := s.gh.approvePR(pollCtx, s.gh.approver, s.cfg.DrambleOwner, s.cfg.DrambleRepo, pr.Number); err != nil {
			log.Printf("could not approve bump PR #%d: %v", pr.Number, err)
			continue
		}
		if err := s.gh.mergePR(pollCtx, s.gh.approver, s.cfg.DrambleOwner, s.cfg.DrambleRepo, pr.Number); err != nil {
			log.Printf("could not merge bump PR #%d: %v", pr.Number, err)
			continue
		}
		log.Printf("auto-approved and merged bump PR #%d", pr.Number)
		s.notify(context.Background(), fmt.Sprintf("Blog deployment bump PR #%d merged; Argo will roll out the new image.", pr.Number))
	}
}

func isBumpBranch(ref string) bool {
	return strings.HasPrefix(ref, "bump/jekyll-sha-") || strings.HasPrefix(ref, "bump/blog-cms-api-sha-")
}

func (c *githubClient) isTrustedHead(pr pullRequest, owner, repo string) bool {
	fullName := strings.ToLower(strings.TrimSpace(pr.Head.Repo.FullName))
	expected := strings.ToLower(owner + "/" + repo)
	return fullName == expected
}

func (c *githubClient) isBumpPR(pr pullRequest) bool {
	return pr.State == "open" &&
		pr.Base.Ref == "dev" &&
		isBumpBranch(pr.Head.Ref) &&
		c.isTrustedHead(pr, c.cfg.DrambleOwner, c.cfg.DrambleRepo)
}

func (s *server) notify(ctx context.Context, message string) {
	if s.cfg.NtfyURL == "" || s.cfg.NtfyTopic == "" {
		return
	}
	endpoint := strings.TrimRight(s.cfg.NtfyURL, "/") + "/" + url.PathEscape(s.cfg.NtfyTopic)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(message))
	if err != nil {
		log.Printf("notification request failed: %v", err)
		return
	}
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	resp, err := s.httpClient().Do(req)
	if err != nil {
		log.Printf("notification delivery failed: %v", err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
}

func (s *server) httpClient() *http.Client {
	if s.gh != nil && s.gh.http != nil {
		return s.gh.http
	}
	return &http.Client{Timeout: 10 * time.Second}
}
