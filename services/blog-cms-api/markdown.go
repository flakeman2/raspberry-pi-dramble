package main

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
)

type postDocument struct {
	Title        string
	Date         string
	Author       string
	Layout       string
	Permalink    string
	Tags         []string
	AIModels     []string
	Verification string
	Body         string
	Raw          string
}

var slugPattern = regexp.MustCompile(`[^a-z0-9-]+`)

func parsePost(raw string) (*postDocument, error) {
	normalized := strings.ReplaceAll(raw, "\r\n", "\n")
	lines := strings.Split(normalized, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return nil, fmt.Errorf("post must start with YAML front matter delimited by ---")
	}
	end := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			end = i
			break
		}
	}
	if end < 0 {
		return nil, fmt.Errorf("front matter is missing its closing --- delimiter")
	}

	doc := &postDocument{Raw: normalized}
	currentList := ""
	for _, line := range lines[1:end] {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "- ") && currentList != "" {
			value := cleanScalar(strings.TrimPrefix(trimmed, "- "))
			if value != "" {
				if currentList == "tags" {
					doc.Tags = append(doc.Tags, value)
				} else {
					doc.AIModels = append(doc.AIModels, value)
				}
			}
			continue
		}
		key, value, ok := strings.Cut(trimmed, ":")
		if !ok {
			currentList = ""
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		switch key {
		case "title":
			doc.Title = cleanScalar(value)
		case "date":
			doc.Date = cleanScalar(value)
		case "author":
			doc.Author = cleanScalar(value)
		case "layout":
			doc.Layout = cleanScalar(value)
		case "permalink":
			doc.Permalink = cleanScalar(value)
		case "verification":
			doc.Verification = cleanScalar(value)
		case "tags", "ai_models":
			currentList = key
			values := parseScalarList(value)
			if key == "tags" {
				doc.Tags = append(doc.Tags, values...)
			} else {
				doc.AIModels = append(doc.AIModels, values...)
			}
		default:
			currentList = ""
		}
	}
	doc.Body = strings.TrimSpace(strings.Join(lines[end+1:], "\n"))
	return doc, nil
}

func cleanScalar(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) {
		return strings.TrimSpace(value[1 : len(value)-1])
	}
	return value
}

func parseScalarList(value string) []string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
		value = strings.TrimSpace(value[1 : len(value)-1])
	}
	if value == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if item := cleanScalar(part); item != "" {
			out = append(out, item)
		}
	}
	return out
}

func (d *postDocument) slug() string {
	slug := strings.Trim(strings.TrimSpace(d.Permalink), "/")
	slug = strings.ToLower(slug)
	slug = strings.ReplaceAll(slug, " ", "-")
	slug = slugPattern.ReplaceAllString(slug, "-")
	return strings.Trim(slug, "-")
}

func (d *postDocument) validate() error {
	var problems []string
	if d.Title == "" {
		problems = append(problems, "title is required")
	}
	if _, err := time.Parse(time.RFC3339, d.Date); err != nil {
		if _, err := time.Parse("2006-01-02", d.Date); err != nil {
			problems = append(problems, "date must be RFC 3339 or YYYY-MM-DD")
		}
	}
	if d.Author == "" {
		problems = append(problems, "author is required")
	}
	if d.Layout != "post" {
		problems = append(problems, "layout must be post")
	}
	if !strings.HasPrefix(d.Permalink, "/") || !strings.HasSuffix(d.Permalink, "/") || d.slug() == "" {
		problems = append(problems, "permalink must be a single /slug/ path")
	}
	if len(d.Tags) == 0 {
		problems = append(problems, "at least one tag is required")
	}
	if len(d.AIModels) == 0 {
		problems = append(problems, "ai_models must list every AI model used or discussed")
	}
	if d.Verification != verificationLine {
		problems = append(problems, "verification text does not match the required publishing statement")
	}

	var aiLine string
	for _, line := range strings.Split(d.Body, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "AI models discussed:") {
			aiLine = line
			break
		}
	}
	if aiLine == "" {
		problems = append(problems, "body must contain an 'AI models discussed:' line")
	} else {
		for _, model := range d.AIModels {
			if !strings.Contains(aiLine, model) {
				problems = append(problems, fmt.Sprintf("AI models discussed line does not credit %q", model))
			}
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s", strings.Join(problems, "; "))
	}
	return nil
}

func (d *postDocument) render() (string, error) {
	renderer := goldmark.New(goldmark.WithExtensions(extension.GFM))
	var out bytes.Buffer
	if err := renderer.Convert([]byte(d.Body), &out); err != nil {
		return "", err
	}
	return out.String(), nil
}
