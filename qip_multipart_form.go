package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
)

const canonicalFormBoundary = "uuid-00000000-0000-0000-0000-000000000000"
const canonicalFormContentType = "multipart/form-data;boundary=" + canonicalFormBoundary

type formAssignment struct {
	name     string
	value    string
	filePath string
	fileMode byte
}

type formAssignmentList []string

type multipartFormFieldPlan struct {
	assignment formAssignment
	sourcePlan qinternal.ComponentSourcePlan
}

type multipartFormPlan struct {
	fields []multipartFormFieldPlan
}

func (values *formAssignmentList) String() string {
	return strings.Join(*values, ",")
}

func (values *formAssignmentList) Set(value string) error {
	*values = append(*values, value)
	return nil
}

func parseFormAssignment(value string) (formAssignment, error) {
	name, body, ok := strings.Cut(value, "=")
	if !ok || name == "" {
		return formAssignment{}, fmt.Errorf("-F requires <name=value>, got %q", value)
	}
	if err := validateFormQuotedValue(name, "field name"); err != nil {
		return formAssignment{}, err
	}
	part := formAssignment{name: name, value: body}
	if strings.HasPrefix(body, "@") || strings.HasPrefix(body, "<") {
		part.fileMode = body[0]
		part.filePath = body[1:]
		part.value = ""
		if part.filePath == "" {
			return formAssignment{}, fmt.Errorf("-F %q has an empty file path", value)
		}
	}
	return part, nil
}

func validateFormQuotedValue(value string, label string) error {
	for _, byteValue := range []byte(value) {
		if byteValue < 0x20 || byteValue > 0x7e || byteValue == '"' || byteValue == '\\' {
			return fmt.Errorf("multipart %s %q must use printable ASCII without quotes or backslashes", label, value)
		}
	}
	return nil
}

func canonicalFormFilename(filePath string) (string, error) {
	separator := strings.LastIndexAny(filePath, "/\\")
	filename := filePath[separator+1:]
	if filename == "" {
		return "", fmt.Errorf("multipart file path %q has no filename", filePath)
	}
	if err := validateFormQuotedValue(filename, "filename"); err != nil {
		return "", err
	}
	return filename, nil
}

func multipartBodyContainsBoundary(body []byte) bool {
	marker := []byte("\r\n--" + canonicalFormBoundary)
	for offset := 0; ; {
		index := bytes.Index(body[offset:], marker)
		if index < 0 {
			return false
		}
		after := offset + index + len(marker)
		if after+2 <= len(body) && (bytes.Equal(body[after:after+2], []byte("\r\n")) || bytes.Equal(body[after:after+2], []byte("--"))) {
			return true
		}
		offset += index + 1
	}
}

func planMultipartFormInput(values []string, hosts []qinternal.ComponentHost) (multipartFormPlan, error) {
	fields := make([]multipartFormFieldPlan, len(values))
	stdinParts := 0
	for index, value := range values {
		assignment, err := parseFormAssignment(value)
		if err != nil {
			return multipartFormPlan{}, err
		}
		if assignment.filePath == "-" {
			stdinParts++
		}
		field := multipartFormFieldPlan{assignment: assignment}
		if assignment.filePath != "" && assignment.filePath != "-" {
			field.sourcePlan = qinternal.PlanComponentSources(assignment.filePath, hosts)
		}
		fields[index] = field
	}
	if stdinParts > 1 {
		return multipartFormPlan{}, errors.New("only one -F field may read from stdin with @- or <-")
	}
	return multipartFormPlan{fields: fields}, nil
}

func buildMultipartFormInput(values []string, stdin io.Reader) ([]byte, string, error) {
	plan, err := planMultipartFormInput(values, nil)
	if err != nil {
		return nil, "", err
	}
	return buildMultipartFormInputFromPlan(plan, stdin)
}

func buildMultipartFormInputFromPlan(plan multipartFormPlan, stdin io.Reader) ([]byte, string, error) {
	var output bytes.Buffer
	for _, field := range plan.fields {
		assignment := field.assignment
		var body []byte
		filename := ""
		if assignment.filePath == "" {
			body = []byte(assignment.value)
		} else {
			var err error
			if assignment.filePath == "-" {
				body, err = io.ReadAll(stdin)
				if assignment.fileMode == '@' {
					filename = "-"
				}
			} else {
				body, err = resolveMultipartFormFile(assignment.filePath, field.sourcePlan)
				if err == nil && assignment.fileMode == '@' {
					filename, err = canonicalFormFilename(assignment.filePath)
				}
			}
			if err != nil {
				return nil, "", fmt.Errorf("read -F %s=%c%s: %w", assignment.name, assignment.fileMode, assignment.filePath, err)
			}
		}
		if multipartBodyContainsBoundary(body) {
			return nil, "", fmt.Errorf("-F field %q contains the multipart boundary as a delimiter line", assignment.name)
		}

		output.WriteString("--" + canonicalFormBoundary + "\r\n")
		output.WriteString("Content-Disposition: form-data; name=\"")
		output.WriteString(assignment.name)
		output.WriteByte('"')
		if filename != "" {
			output.WriteString("; filename=\"")
			output.WriteString(filename)
			output.WriteString("\"\r\nContent-Type: application/octet-stream")
		}
		output.WriteString("\r\n\r\n")
		output.Write(body)
		output.WriteString("\r\n")
	}
	output.WriteString("--" + canonicalFormBoundary + "--\r\n")
	return output.Bytes(), canonicalFormContentType, nil
}
