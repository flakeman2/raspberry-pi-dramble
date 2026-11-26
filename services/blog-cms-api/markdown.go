package main

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"gopkg.in/yaml.v3"
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

	var node yaml.Node
	frontMatter := strings.Join(lines[1:end], "\n")
	if err := yaml.Unmarshal([]byte(frontMatter), &node); err != nil {
		return nil, fmt.Errorf("invalid front matter YAML: %w", err)
	}
	if len(node.Content) != 1 || node.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("front matter must be a YAML mapping")
	}

	doc := &postDocument{Raw: normalized}
	mapping := node.Content[0]
	seen := make(map[string]bool, len(mapping.Content)/2)
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		keyNode, valueNode := mapping.Content[i], mapping.Content[i+1]
		if keyNode.Kind != yaml.ScalarNode {
			return nil, fmt.Errorf("front matter keys must be strings")
		}
		key := keyNode.Value
		if seen[key] {
			return nil, fmt.Errorf("duplicate front matter key %q", key)
		}
		seen[key] = true

		switch key {
		case "title", "date", "author", "layout", "permalink", "verification":
			value, err := scalarValue(valueNode)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", key, err)
			}
			switch key {
			case "title":
				doc.Title = value
			case "date":
				doc.Date = value
			case "author":
				doc.Author = value
			case "layout":
				doc.Layout = value
			case "permalink":
				doc.Permalink = value
			case "verification":
				doc.Verification = value
			}
		case "tags", "ai_models":
			values, err := listValues(valueNode)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", key, err)
			}
			if key == "tags" {
				doc.Tags = values
			} else {
				doc.AIModels = values
			}
		}
	}

	doc.Body = strings.TrimSpace(strings.Join(lines[end+1:], "\n"))
	return doc, nil
}

func scalarValue(node *yaml.Node) (string, error) {
	if node.Kind != yaml.ScalarNode {
		return "", fmt.Errorf("must be a scalar value")
	}
	if node.Tag == "!!null" {
		return "", nil
	}
	return node.Value, nil
}

func listValues(node *yaml.Node) ([]string, error) {
	if node.Kind == yaml.ScalarNode && node.Tag == "!!null" {
		return nil, nil
	}
	if node.Kind == yaml.ScalarNode {
		return parseScalarList(node.Value), nil
	}
	if node.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("must be a list")
	}
	values := make([]string, 0, len(node.Content))
	for _, item := range node.Content {
		value, err := scalarValue(item)
		if err != nil {
			return nil, fmt.Errorf("list items must be scalars")
		}
		if value != "" {
			values = append(values, value)
		}
	}
	return values, nil
}

func cleanScalar(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) {
		return value[1 : len(value)-1]
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
	if d.Verification != verificationLine {
		problems = append(problems, "verification text does not match the required publishing statement")
	}

	// AI disclosure is optional, but a post that lists models must credit every
	// one of them in the body.
	if len(d.AIModels) > 0 {
		discussed := []string(nil)
		for _, line := range strings.Split(d.Body, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "AI models discussed:") {
				discussed = parseScalarList(strings.TrimSpace(strings.TrimPrefix(trimmed, "AI models discussed:")))
				break
			}
		}
		if len(discussed) == 0 {
			problems = append(problems, "body must contain an 'AI models discussed:' line")
		} else {
			for _, model := range d.AIModels {
				found := false
				for _, item := range discussed {
					if strings.EqualFold(item, model) {
						found = true
						break
					}
				}
				if !found {
					problems = append(problems, fmt.Sprintf("AI models discussed line does not credit %q", model))
				}
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
