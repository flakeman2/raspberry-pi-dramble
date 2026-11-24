package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
)

type draftRequest struct {
	Slug    string `json:"slug"`
	Content string `json:"content"`
}

type submitRequest struct {
	Slug    string `json:"slug"`
	Content string `json:"content"`
}

type publishRequest struct {
	Slug    string `json:"slug"`
	Content string `json:"content"`
}

type approveRequest struct {
	Number int `json:"number"`
}

func (s *server) handlePreview(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireSession(w, r); !ok {
		return
	}
	var req struct {
		Content string `json:"content"`
	}
	if err := readJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	doc, err := parsePost(req.Content)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := doc.validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	html, err := doc.render()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not render preview")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"title":        doc.Title,
		"permalink":    doc.Permalink,
		"slug":         doc.slug(),
		"tags":         doc.Tags,
		"ai_models":    doc.AIModels,
		"verification": doc.Verification,
		"html":         html,
	})
}

func (s *server) handleSaveDraft(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.requireSession(w, r)
	if !ok {
		return
	}
	var req draftRequest
	if err := readJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	branch, err := s.saveDraft(r.Context(), req.Slug, req.Content)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"role":   sess.Role,
		"slug":   strings.TrimPrefix(branch, "cms/"),
		"branch": branch,
		"saved":  true,
	})
}

func (s *server) saveDraft(ctx context.Context, requestedSlug, content string) (string, error) {
	doc, err := parsePost(content)
	if err != nil {
		return "", err
	}
	if err := doc.validate(); err != nil {
		return "", err
	}
	slug := doc.slug()
	if requestedSlug != "" && requestedSlug != slug {
		return "", fmt.Errorf("slug in request does not match front matter permalink")
	}
	branch := "cms/" + slug

	exists, err := s.gh.branchExists(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, branch)
	if err != nil {
		return "", err
	}
	if !exists {
		baseSHA, err := s.gh.refSHA(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, "master")
		if err != nil {
			return "", err
		}
		if err := s.gh.createBranch(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, branch, baseSHA); err != nil {
			return "", err
		}
	}

	path := "_drafts/" + slug + ".md"
	fileSHA, err := s.gh.getFileSHA(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, path, branch)
	if err != nil {
		return "", err
	}
	message := "Create blog post draft " + slug
	if fileSHA != "" {
		message = "Update blog post draft " + slug
	}
	if err := s.gh.putFile(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, path, branch, doc.Raw, message, fileSHA); err != nil {
		return "", err
	}
	return branch, nil
}

func (s *server) ensurePR(ctx context.Context, req draftRequest, role string) (*pullRequest, *postDocument, error) {
	branch, err := s.saveDraft(ctx, req.Slug, req.Content)
	if err != nil {
		return nil, nil, err
	}
	doc, err := parsePost(req.Content)
	if err != nil {
		return nil, nil, err
	}

	prs, err := s.gh.listOpenPRs(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, "master")
	if err != nil {
		return nil, nil, err
	}
	for _, pr := range prs {
		if pr.Head.Ref == branch {
			return &pr, doc, nil
		}
	}

	body := fmt.Sprintf("Submitted from the blog post editor by the **%s** role.\n\n- Branch: `%s`\n- Permalink: `%s`\n\nVerification: %s", role, branch, doc.Permalink, verificationLine)
	pr, err := s.gh.createPR(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, branch, "master", doc.Title, body)
	if err != nil {
		return nil, nil, err
	}
	label := "cms/admin"
	if role == "guest" {
		label = "cms/guest"
	}
	if err := s.gh.addLabels(ctx, s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, pr.Number, label); err != nil {
		return nil, nil, err
	}
	if role == "guest" {
		s.notify(context.Background(), fmt.Sprintf("New guest post submitted for review: %s (#%d)", doc.Title, pr.Number))
	}
	return pr, doc, nil
}

func (s *server) handleSubmit(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.requireSession(w, r)
	if !ok {
		return
	}
	var req submitRequest
	if err := readJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	pr, _, err := s.ensurePR(r.Context(), draftRequest{Slug: req.Slug, Content: req.Content}, sess.Role)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	message := "Post submitted for admin review."
	if sess.Role == "admin" {
		message = "Post is ready to publish."
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"number":  pr.Number,
		"url":     pr.HTMLURL,
		"status":  "pending",
		"role":    sess.Role,
		"message": message,
	})
}

func (s *server) handleListDrafts(w http.ResponseWriter, r *http.Request) {
	sess, ok := s.requireSession(w, r)
	if !ok {
		return
	}
	prs, err := s.gh.listOpenPRs(r.Context(), s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, "master")
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not list drafts")
		return
	}
	out := make([]map[string]any, 0, len(prs))
	for _, pr := range prs {
		if !strings.HasPrefix(pr.Head.Ref, "cms/") {
			continue
		}
		if sess.Role == "guest" && !prHasLabel(pr, "cms/guest") {
			continue
		}
		out = append(out, prResponse(pr))
	}
	writeJSON(w, http.StatusOK, map[string]any{"drafts": out})
}

func (s *server) handleReview(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireSession(w, r, "admin"); !ok {
		return
	}
	prs, err := s.gh.listOpenPRs(r.Context(), s.gh.writer, s.cfg.EphesusOwner, s.cfg.EphesusRepo, "master")
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not list the review queue")
		return
	}
	out := make([]map[string]any, 0, len(prs))
	for _, pr := range prs {
		if strings.HasPrefix(pr.Head.Ref, "cms/") {
			out = append(out, prResponse(pr))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"reviews": out})
}

func (s *server) handleApprove(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireSession(w, r, "admin"); !ok {
		return
	}
	var req approveRequest
	if err := readJSON(w, r, &req); err != nil || req.Number <= 0 {
		writeError(w, http.StatusBadRequest, "a positive pull request number is required")
		return
	}
	pr, err := s.gh.getPR(r.Context(), s.gh.publisher, s.cfg.EphesusOwner, s.cfg.EphesusRepo, req.Number)
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not load pull request")
		return
	}
	if !strings.HasPrefix(pr.Head.Ref, "cms/") || !prHasLabel(*pr, "cms/guest") {
		writeError(w, http.StatusBadRequest, "only guest post PRs can be approved here")
		return
	}
	if err := s.gh.mergePR(r.Context(), s.gh.publisher, s.cfg.EphesusOwner, s.cfg.EphesusRepo, pr.Number); err != nil {
		writeError(w, http.StatusBadGateway, "could not merge guest post")
		return
	}
	s.notify(context.Background(), fmt.Sprintf("Guest post approved and published: %s (#%d)", pr.Title, pr.Number))
	writeJSON(w, http.StatusOK, map[string]any{
		"number":  pr.Number,
		"merged":  true,
		"message": "Guest post approved. Image build and deployment are in progress.",
	})
}

func (s *server) handlePublish(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireSession(w, r, "admin"); !ok {
		return
	}
	var req publishRequest
	if err := readJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	pr, _, err := s.ensurePR(r.Context(), draftRequest{Slug: req.Slug, Content: req.Content}, "admin")
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.gh.mergePR(r.Context(), s.gh.publisher, s.cfg.EphesusOwner, s.cfg.EphesusRepo, pr.Number); err != nil {
		writeError(w, http.StatusBadGateway, "could not merge post PR")
		return
	}
	s.notify(context.Background(), fmt.Sprintf("Admin post published: %s (#%d)", pr.Title, pr.Number))
	writeJSON(w, http.StatusOK, map[string]any{
		"number":  pr.Number,
		"merged":  true,
		"message": "Post published. Image build and deployment are in progress.",
	})
}

func prHasLabel(pr pullRequest, label string) bool {
	for _, item := range pr.Labels {
		if item.Name == label {
			return true
		}
	}
	return false
}

func prResponse(pr pullRequest) map[string]any {
	labels := make([]string, 0, len(pr.Labels))
	for _, item := range pr.Labels {
		labels = append(labels, item.Name)
	}
	return map[string]any{
		"number": pr.Number,
		"title":  pr.Title,
		"url":    pr.HTMLURL,
		"branch": pr.Head.Ref,
		"labels": labels,
	}
}
