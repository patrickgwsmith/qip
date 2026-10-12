package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/textproto"
	"slices"
	"strconv"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	qwarc "github.com/royalicing/qip/internal/warc"
)

func scaleRouteWARCTransformTimeout(base time.Duration, routeCount int) time.Duration {
	if routeCount <= 1 || base <= 0 {
		return base
	}
	if base > time.Duration(math.MaxInt64/int64(routeCount)) {
		panic("route WARC transform timeout overflow")
	}
	return base * time.Duration(routeCount)
}

func processApplicationWARCArchive(ctx context.Context, pipeline *qinternal.Pipeline, warc []byte, requestID uint64) ([]byte, error) {
	if pipeline == nil {
		if err := qwarc.ValidateArchive(warc); err != nil {
			return nil, fmt.Errorf("invalid WARC archive: %w", err)
		}
		return warc, nil
	}
	// Hash payloads natively so recipes can read WARC-Payload-Digest instead of
	// hashing in wasm, and so a recipe that leaves a stale digest is named.
	digester := qwarc.NewPayloadDigester()
	warc, err := digester.Apply(warc)
	if err != nil {
		return nil, fmt.Errorf("invalid WARC archive: %w", err)
	}
	input := qinternal.NewRawBytesContentWithType(warc, applicationWARCRecipeMIME)
	result, err := pipeline.ProcessWithCheck(ctx, input, requestID, func(output qinternal.Content) (qinternal.Content, error) {
		_, raw, err := ensureRawContent(output)
		if err != nil {
			return nil, err
		}
		digested, err := digester.Apply(raw)
		if err != nil {
			return nil, err
		}
		if len(digested) == len(raw) {
			return output, nil
		}
		return qinternal.NewRawBytesContentWithType(digested, applicationWARCRecipeMIME), nil
	})
	if err != nil {
		return nil, err
	}
	_, output, err := ensureRawContent(result)
	if err != nil {
		return nil, err
	}
	if err := qwarc.ValidateArchive(output); err != nil {
		return nil, fmt.Errorf("WARC recipe returned an invalid archive: %w", err)
	}
	return output, nil
}

func transformRouteResponseWithApplicationWARC(
	ctx context.Context,
	pipeline *qinternal.Pipeline,
	requestPath string,
	response qinternal.InProcessHTTPResponse,
	requestID uint64,
) (qinternal.InProcessHTTPResponse, error) {
	if pipeline == nil {
		return response, nil
	}
	requestURI := buildWARCRequestURI("qip.local", requestPath)
	record, err := buildMinimalWARCResponseRecord(requestURI, response)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to build WARC record for %q: %w", requestPath, err)
	}
	transformedWARC, err := processApplicationWARCArchive(ctx, pipeline, record, requestID)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}
	transformedResponse, err := extractWARCResponseRecordByTargetURI(transformedWARC, requestURI)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to parse transformed WARC response for %q: %w", requestPath, err)
	}
	return transformedResponse, nil
}

func buildWARCRequestURI(host string, requestPath string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		host = "qip.local"
	}
	requestPath = strings.TrimSpace(requestPath)
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	return "http://" + host + requestPath
}

func buildMinimalWARCResponseRecord(targetURI string, response qinternal.InProcessHTTPResponse) ([]byte, error) {
	return qwarc.BuildHTTPResponseRecord(targetURI, response.StatusCode, response.Header, response.Body)
}

func extractFirstWARCResponseRecord(warc []byte) (qinternal.InProcessHTTPResponse, error) {
	return extractWARCResponseRecordByTargetURI(warc, "")
}

func extractWARCResponseRecordByTargetURI(warc []byte, targetURI string) (qinternal.InProcessHTTPResponse, error) {
	records, err := parseWARCResponseRecords(warc)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}
	for _, record := range records {
		if targetURI == "" || record.targetURI == targetURI {
			return record.response, nil
		}
	}
	if targetURI != "" {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("WARC archive has no response record for %s", targetURI)
	}
	return qinternal.InProcessHTTPResponse{}, errors.New("WARC archive has no response record")
}

type warcResponseRecord struct {
	targetURI string
	response  qinternal.InProcessHTTPResponse
}

func parseWARCResponseRecords(warc []byte) ([]warcResponseRecord, error) {
	records := make([]warcResponseRecord, 0)
	cursor := 0
	for cursor < len(warc) {
		for cursor < len(warc) && (warc[cursor] == '\r' || warc[cursor] == '\n') {
			cursor++
		}
		if cursor >= len(warc) {
			break
		}

		headerEnd := findHeaderBlockEnd(warc[cursor:])
		if headerEnd == -1 {
			return nil, errors.New("WARC header terminator not found")
		}
		headerBlock := warc[cursor : cursor+headerEnd]

		warcType := ""
		recordTargetURI := ""
		contentLength := -1
		lines := bytes.Split(headerBlock, []byte("\n"))
		for i, rawLine := range lines {
			line := bytes.TrimSpace(rawLine)
			if len(line) == 0 || i == 0 {
				continue
			}
			colon := bytes.IndexByte(line, ':')
			if colon <= 0 {
				continue
			}
			key := strings.TrimSpace(string(line[:colon]))
			value := strings.TrimSpace(string(line[colon+1:]))
			switch {
			case strings.EqualFold(key, "WARC-Type"):
				warcType = value
			case strings.EqualFold(key, "WARC-Target-URI"):
				recordTargetURI = value
			case strings.EqualFold(key, "Content-Length"):
				n, err := strconv.Atoi(value)
				if err != nil || n < 0 {
					return nil, fmt.Errorf("invalid WARC Content-Length %q", value)
				}
				contentLength = n
			}
		}
		if contentLength < 0 {
			return nil, errors.New("WARC record is missing Content-Length")
		}

		payloadStart := cursor + headerEnd
		payloadEnd := payloadStart + contentLength
		if payloadEnd > len(warc) {
			return nil, errors.New("WARC record payload exceeds archive length")
		}
		payload := warc[payloadStart:payloadEnd]
		if strings.EqualFold(warcType, "response") {
			response, err := parseWARCHTTPResponsePayload(payload)
			if err != nil {
				return nil, err
			}
			records = append(records, warcResponseRecord{targetURI: recordTargetURI, response: response})
		}
		cursor = payloadEnd
	}
	return records, nil
}

func parseWARCHTTPResponsePayload(payload []byte) (qinternal.InProcessHTTPResponse, error) {
	headerEnd := findHeaderBlockEnd(payload)
	if headerEnd == -1 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload header terminator not found")
	}
	headerBlock := payload[:headerEnd]
	body := slices.Clone(payload[headerEnd:])

	lines := bytes.Split(headerBlock, []byte("\n"))
	if len(lines) == 0 {
		return qinternal.InProcessHTTPResponse{}, errors.New("HTTP payload is missing status line")
	}
	statusLine := strings.TrimSpace(string(lines[0]))
	parts := strings.Fields(statusLine)
	if len(parts) < 2 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status line %q", statusLine)
	}
	statusCode, err := strconv.Atoi(parts[1])
	if err != nil || statusCode < 100 {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("invalid HTTP status code in %q", statusLine)
	}

	headers := make(http.Header)
	for _, rawLine := range lines[1:] {
		line := bytes.TrimSpace(rawLine)
		if len(line) == 0 {
			continue
		}
		colon := bytes.IndexByte(line, ':')
		if colon <= 0 {
			continue
		}
		key := textproto.CanonicalMIMEHeaderKey(strings.TrimSpace(string(line[:colon])))
		if key == "" {
			continue
		}
		value := strings.TrimSpace(string(line[colon+1:]))
		headers.Add(key, value)
	}
	if headers.Get("Content-Length") == "" {
		headers.Set("Content-Length", strconv.Itoa(len(body)))
	}

	return qinternal.InProcessHTTPResponse{
		StatusCode: statusCode,
		Header:     headers,
		Body:       body,
	}, nil
}

func findHeaderBlockEnd(data []byte) int {
	if idx := bytes.Index(data, []byte("\r\n\r\n")); idx >= 0 {
		return idx + 4
	}
	if idx := bytes.Index(data, []byte("\n\n")); idx >= 0 {
		return idx + 2
	}
	return -1
}
