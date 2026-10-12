package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateDeclaredContentTypeAcceptsCanonicalMultipartRelated(t *testing.T) {
	related := `multipart/related;type="image/svg+xml";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`
	if got, err := validateDeclaredContentType(related); err != nil || got != related {
		t.Fatalf("canonical multipart/related result=%q error=%v", got, err)
	}
	if got := normalizeIncomingContentType(related); got != related {
		t.Fatalf("normalized multipart/related=%q, want %q", got, related)
	}
	for _, value := range []string{
		"multipart/related;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef",
		`multipart/related;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef;type="image/svg+xml"`,
		"multipart/related;type=image/svg+xml;boundary=uuid-12345678-90ab-cdef-1234-567890abcdef",
		`multipart/related; type="image/svg+xml";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`,
		`multipart/related;type="Image/SVG+xml";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`,
		`multipart/related;type="image/svg+xml;charset=utf-8";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`,
		`multipart/related;type="multipart/mixed";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`,
		`multipart/related;type="image/svg+xml";start="<root>";boundary=uuid-12345678-90ab-cdef-1234-567890abcdef`,
		`multipart/related;type="image/svg+xml";boundary=uuid-12345678-90AB-cdef-1234-567890abcdef`,
		`multipart/related;type="image/svg+xml";boundary=uuid-12345678-90ab-cdef-1234-567890abcde`,
	} {
		if _, err := validateDeclaredContentType(value); err == nil {
			t.Fatalf("validateDeclaredContentType(%q) succeeded, want canonical-form error", value)
		}
	}
}

func TestDeclaredContentTypeAcceptsComparesMultipartRelatedRootType(t *testing.T) {
	svg := canonicalRelatedContentType("image/svg+xml")
	if err := declaredContentTypeAccepts(svg, svg); err != nil {
		t.Fatalf("same multipart/related type: %v", err)
	}
	html := canonicalRelatedContentType("text/html")
	err := declaredContentTypeAccepts(svg, html)
	if err == nil || !strings.Contains(err.Error(), "type expected image/svg+xml got text/html") {
		t.Fatalf("error=%v, want root type mismatch", err)
	}
	if err := declaredContentTypeAccepts(svg, canonicalFormContentType); err == nil {
		t.Fatal("multipart/form-data satisfied multipart/related")
	}
}

func TestBuildMultipartRelatedInput(t *testing.T) {
	dir := t.TempDir()
	fontPath := filepath.Join(dir, "Inter.ttf")
	if err := os.WriteFile(fontPath, []byte("font"), 0o644); err != nil {
		t.Fatal(err)
	}
	declared := canonicalRelatedContentType("image/svg+xml")
	actual, contentType, err := buildMultipartRelatedInput([]byte("<svg/>"), declared, []string{"font=@" + fontPath + ";type=font/ttf"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if contentType != declared {
		t.Fatalf("content type=%q", contentType)
	}
	want := "--" + canonicalFormBoundary + "\r\nContent-Type: image/svg+xml\r\n\r\n<svg/>\r\n" +
		"--" + canonicalFormBoundary + "\r\nContent-Type: font/ttf\r\n\r\nfont\r\n" +
		"--" + canonicalFormBoundary + "--\r\n"
	if string(actual) != want {
		t.Fatalf("actual=%q want=%q", actual, want)
	}
}

func TestBuildMultipartRelatedInputRejectsInvalidParts(t *testing.T) {
	declared := canonicalRelatedContentType("image/svg+xml")
	for _, value := range []string{"a=b", "a=<file;type=font/ttf", "a=@file"} {
		if _, _, err := buildMultipartRelatedInput([]byte("root"), declared, []string{value}, nil); err == nil {
			t.Errorf("accepted %q", value)
		}
	}
	if _, _, err := buildMultipartRelatedInput([]byte("root"), "", []string{"a=@file;type=font/ttf"}, nil); err == nil {
		t.Fatal("accepted missing declaration")
	}
	marker := "before\r\n--" + canonicalFormBoundary + "--\r\nafter"
	if _, _, err := buildMultipartRelatedInput([]byte(marker), declared, nil, nil); err == nil {
		t.Fatal("accepted delimiter")
	}
}

func TestMultipartBodyContainsBoundaryAtEdges(t *testing.T) {
	delimiter := "--" + canonicalFormBoundary
	for _, body := range []string{
		delimiter,
		delimiter + "\r\nrest",
		delimiter + "--",
		"abc\r\n" + delimiter,
		"abc\r\n" + delimiter + "--",
	} {
		if !multipartBodyContainsBoundary([]byte(body)) {
			t.Errorf("missed delimiter in %q", body)
		}
	}
	for _, body := range []string{"", delimiter + "-x", "abc" + delimiter, "abc\r\n" + delimiter + "x"} {
		if multipartBodyContainsBoundary([]byte(body)) {
			t.Errorf("rejected %q", body)
		}
	}
}

func TestParseRunCommandArgsRelatedInput(t *testing.T) {
	config, err := parseRunCommandArgs([]string{"-i", "logo.svg", "-F", "font=@Inter.ttf;type=font/ttf", "bytes/identity.wasm"}, "run")
	if err != nil {
		t.Fatal(err)
	}
	if config.inputPath != "logo.svg" || len(config.formValues) != 1 {
		t.Fatalf("config=%+v", config)
	}
}
