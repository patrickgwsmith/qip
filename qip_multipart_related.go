package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// multipart/related input follows a narrow profile: the first part is the root, every part
// carries an explicit Content-Type, and the root's bare media type is the type parameter.
// The boundary stays last so hosts can patch exactly the final 36 bytes.
const multipartRelatedContentTypePrefix = "multipart/related;type=\""
const multipartRelatedBoundaryInfix = "\";boundary=uuid-"

func canonicalRelatedContentType(rootType string) string {
	return multipartRelatedContentTypePrefix + rootType + "\";boundary=" + canonicalFormBoundary
}

// isCanonicalMultipartRelatedContentType accepts
// multipart/related;type="<type>/<subtype>";boundary=uuid-<lowercase UUID>, where the root
// type is a bare lowercase media type that is not itself multipart.
func isCanonicalMultipartRelatedContentType(value string) bool {
	rest, ok := strings.CutPrefix(value, multipartRelatedContentTypePrefix)
	if !ok {
		return false
	}
	end := strings.Index(rest, multipartRelatedBoundaryInfix)
	if end < 0 || !isBareRelatedRootType(rest[:end]) {
		return false
	}
	return isCanonicalBoundaryUUID(rest[end+len(multipartRelatedBoundaryInfix):])
}

func isBareRelatedRootType(value string) bool {
	main, sub, ok := strings.Cut(value, "/")
	if !ok || main == "" || sub == "" || main == "multipart" {
		return false
	}
	for _, token := range []string{main, sub} {
		for i := 0; i < len(token); i++ {
			c := token[i]
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || strings.IndexByte("!#$&^_.+-", c) >= 0) {
				return false
			}
		}
	}
	return true
}

func relatedRootType(declared string) (string, error) {
	if !isCanonicalMultipartRelatedContentType(declared) {
		return "", errors.New("-i with -F requires the first component to declare multipart/related with a root type")
	}
	rest := strings.TrimPrefix(declared, multipartRelatedContentTypePrefix)
	root, _, _ := strings.Cut(rest, multipartRelatedBoundaryInfix)
	return root, nil
}

func buildMultipartRelatedInput(root []byte, declared string, values []string, stdin io.Reader) ([]byte, string, error) {
	rootType, err := relatedRootType(declared)
	if err != nil {
		return nil, "", err
	}
	_, boundary, _ := strings.Cut(declared, ";boundary=")
	var output bytes.Buffer
	writePart := func(body []byte, contentType, label string) error {
		if multipartBodyContainsBoundaryWith(body, boundary) {
			return fmt.Errorf("%s contains the multipart boundary as a delimiter line", label)
		}
		output.WriteString("--" + boundary + "\r\n")
		output.WriteString("Content-Type: " + contentType + "\r\n\r\n")
		output.Write(body)
		output.WriteString("\r\n")
		return nil
	}
	if err := writePart(root, rootType, "-i root"); err != nil {
		return nil, "", err
	}
	stdinParts := 0
	for _, value := range values {
		part, err := parseRelatedAssignment(value)
		if err != nil {
			return nil, "", err
		}
		if part.filePath == "-" {
			stdinParts++
			if stdinParts > 1 {
				return nil, "", errors.New("only one related -F part may read stdin")
			}
		}
		var body []byte
		if part.filePath == "-" {
			if stdin == nil {
				return nil, "", errors.New("related -F @- cannot read stdin here")
			}
			body, err = io.ReadAll(stdin)
		} else {
			body, err = os.ReadFile(part.filePath)
		}
		if err != nil {
			return nil, "", fmt.Errorf("read related -F %s: %w", part.filePath, err)
		}
		if err := writePart(body, part.contentType, "-F part"); err != nil {
			return nil, "", err
		}
	}
	output.WriteString("--" + boundary + "--\r\n")
	return output.Bytes(), declared, nil
}

func declaredRelatedTypeForInvocations(ctx context.Context, invocations []ComponentInvocation, opts options) (string, error) {
	prepared, err := prepareRunPipelineFromInvocations(ctx, invocations, opts, "")
	if err != nil {
		return "", err
	}
	defer prepared.pipeline.Close(context.Background())
	if len(prepared.plan.steps) == 0 {
		return "", errors.New("-i with -F requires a Content component")
	}
	declared := prepared.plan.steps[0].inputType
	if _, err := relatedRootType(declared); err != nil {
		return "", err
	}
	return declared, nil
}

// parseCLIFormValue parses one -F value. With -i the value is a related part, which may omit
// its unused name, as in -F '@Inter.ttf;type=font/ttf'; otherwise it is a form field.
func parseCLIFormValue(value string, related bool) (formAssignment, error) {
	if related {
		return parseRelatedAssignment(value)
	}
	if strings.HasPrefix(value, "@") {
		return formAssignment{}, fmt.Errorf("-F %q has no field name; only related parts with -i may omit it", value)
	}
	return parseFormAssignment(value)
}

func parseRelatedAssignment(value string) (formAssignment, error) {
	partValue := value
	if strings.HasPrefix(value, "@") {
		partValue = "part=" + value
	}
	part, err := parseFormAssignment(partValue)
	if err != nil {
		return formAssignment{}, err
	}
	if part.fileMode != '@' || part.contentType == "" {
		return formAssignment{}, fmt.Errorf("related -F %q requires [name=]@path;type=<content-type>", value)
	}
	return part, nil
}

func validateRelatedFields(rootPath string, values []string) error {
	stdinParts := 0
	if rootPath == "" || len(values) == 0 {
		return nil
	}
	for _, value := range values {
		part, err := parseRelatedAssignment(value)
		if err != nil {
			return err
		}
		if part.filePath == "-" {
			stdinParts++
			if stdinParts > 1 {
				return errors.New("only one related -F part may read stdin")
			}
		}
		if rootPath == "-" && part.filePath == "-" {
			return errors.New("-i - and related -F @- cannot both read stdin")
		}
	}
	return nil
}
