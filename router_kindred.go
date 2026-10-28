package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"

	qinternal "github.com/royalicing/qip/internal"
)

// resolveRouterBaseResponse renders a content route before the WARC recipes.
// It also resolves routes outside the content filter, because they can be
// parent pages of routes inside it.
func resolveRouterBaseResponse(ctx context.Context, current *RouterServerState, requestPath string, requestID uint64, timeouts RouterServerTimeouts) (qinternal.InProcessHTTPResponse, bool, error) {
	if current == nil {
		return qinternal.InProcessHTTPResponse{}, false, errors.New("runtime state is unavailable")
	}
	route, ok := qinternal.ResolveContentRoute(current.allContentRoutes(), requestPath, current.routeOptions)
	if !ok {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	contentRead := current.contentRead
	if contentRead == nil {
		contentRead = func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
			return os.ReadFile(route.FilePath)
		}
	}
	inputBytes, err := contentRead(ctx, route)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, false, err
	}

	hasRecipes := shouldApplyRecipesForRequestPath(requestPath, route, current.recipeChains)
	var result qinternal.Content = qinternal.NewRawBytesContentWithType(inputBytes, route.SourceMIME)
	if hasRecipes {
		pipeline := current.recipeChains[route.SourceMIME]
		execCtx, cancel := withExecutionTimeout(ctx, timeouts.contentRecipe)
		defer cancel()
		result, err = pipeline.Process(execCtx, result, requestID)
		if err != nil {
			return qinternal.InProcessHTTPResponse{}, false, err
		}
	}
	result, body, err := ensureRawContent(result)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, false, err
	}
	contentType := routerResponseContentType(route.SourceMIME, hasRecipes, result, body)
	return qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       body,
	}, true, nil
}

func resolveElementAssetResponse(ctx context.Context, current *RouterServerState, requestPath string, requestID uint64, timeouts RouterServerTimeouts) (qinternal.InProcessHTTPResponse, bool, error) {
	if current == nil {
		return qinternal.InProcessHTTPResponse{}, false, errors.New("runtime state is unavailable")
	}
	asset, ok := current.elementAssets[requestPath]
	if !ok {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	body, err := os.ReadFile(asset.filePath)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, false, err
	}
	contentType := "text/javascript"
	if pipeline := current.recipeChains[contentType]; pipeline != nil {
		execCtx, cancel := withExecutionTimeout(ctx, timeouts.contentRecipe)
		defer cancel()
		result, err := pipeline.Process(execCtx, qinternal.NewRawBytesContentWithType(body, contentType), requestID)
		if err != nil {
			return qinternal.InProcessHTTPResponse{}, false, err
		}
		result, body, err = ensureRawContent(result)
		if err != nil {
			return qinternal.InProcessHTTPResponse{}, false, err
		}
		contentType = routerResponseContentType("text/javascript", true, result, body)
	}
	return qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       body,
	}, true, nil
}

func (state *RouterFileState) allContentRoutes() map[string]qinternal.ContentRoute {
	if state.contextRoutes != nil {
		return state.contextRoutes
	}
	return state.contentRoutes
}

// filteredParentPaths lists the parent pages of requestPaths that exist but
// that the content filter leaves out. A whole-site WARC includes them while
// the WARC recipes run, so their layouts apply as they do in dev mode.
func filteredParentPaths(state *RouterServerState, requestPaths []string) []string {
	if state.contextRoutes == nil || len(state.contextRoutes) == len(state.contentRoutes) {
		return nil
	}
	seen := make(map[string]struct{})
	var out []string
	for _, requestPath := range requestPaths {
		for _, parentPath := range qinternal.KindredParentPaths(requestPath) {
			if _, ok := seen[parentPath]; ok {
				continue
			}
			seen[parentPath] = struct{}{}
			if _, ok := qinternal.ResolveContentRoute(state.contentRoutes, parentPath, state.routeOptions); ok {
				continue
			}
			if _, ok := qinternal.ResolveContentRoute(state.contextRoutes, parentPath, state.routeOptions); ok {
				out = append(out, parentPath)
			}
		}
	}
	sort.Strings(out)
	return out
}

func resolveKindredStaticRoute(ctx context.Context, current *RouterServerState, requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
	if current == nil {
		return qinternal.InProcessHTTPResponse{}, false, errors.New("runtime state is unavailable")
	}
	if asset, ok := current.componentAssets[requestPath]; ok {
		return qinternal.InProcessHTTPResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{asset.contentType}},
			Body:       asset.body,
		}, true, nil
	}

	route, ok := qinternal.ResolveContentRoute(current.contentRoutes, requestPath, current.routeOptions)
	if !ok {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	sourceMIME := mediaTypeOnly(route.SourceMIME)
	if sourceMIME == "text/html" || sourceMIME == "application/xhtml+xml" || shouldApplyRecipesForRequestPath(requestPath, route, current.recipeChains) {
		return qinternal.InProcessHTTPResponse{}, false, nil
	}
	contentRead := current.contentRead
	if contentRead == nil {
		contentRead = func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
			return os.ReadFile(route.FilePath)
		}
	}
	body, err := contentRead(ctx, route)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, false, err
	}
	contentType := route.SourceMIME
	if contentType == "" {
		contentType = "application/octet-stream"
	} else if strings.HasPrefix(contentType, "text/") {
		contentType += "; charset=utf-8"
	}
	return qinternal.InProcessHTTPResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{contentType}},
		Body:       body,
	}, true, nil
}

func transformRouteResponseWithKindredRoutes(
	ctx context.Context,
	pipeline *qinternal.Pipeline,
	requestPath string,
	response qinternal.InProcessHTTPResponse,
	requestID uint64,
	resolveParent qinternal.KindredRouteResolver,
	resolveStatic qinternal.KindredRouteResolver,
	elementEntryPaths []string,
	resolveElement qinternal.KindredRouteResolver,
) (qinternal.InProcessHTTPResponse, error) {
	if pipeline == nil {
		return response, nil
	}
	requestURI := buildWARCRequestURI("qip.local", requestPath)
	archive, err := buildKindredWARCArchive("http://qip.local", requestPath, response, resolveParent, resolveStatic, elementEntryPaths, resolveElement)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}

	transformedWARC, err := processApplicationWARCArchive(ctx, pipeline, archive, requestID)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, err
	}
	transformedResponse, err := extractWARCResponseRecordByTargetURI(transformedWARC, requestURI)
	if err != nil {
		return qinternal.InProcessHTTPResponse{}, fmt.Errorf("failed to parse transformed WARC response for %q: %w", requestPath, err)
	}
	return transformedResponse, nil
}

// buildKindredWARCArchive builds the archive an application/warc recipe sees
// for one route. Each record's WARC-Target-URI is origin followed by its path.
func buildKindredWARCArchive(
	origin string,
	requestPath string,
	response qinternal.InProcessHTTPResponse,
	resolveParent qinternal.KindredRouteResolver,
	resolveStatic qinternal.KindredRouteResolver,
	elementEntryPaths []string,
	resolveElement qinternal.KindredRouteResolver,
) ([]byte, error) {
	routes, err := qinternal.KindredRoutes(requestPath, response, resolveParent, resolveStatic)
	if err != nil {
		return nil, err
	}
	if len(routes) > 0 && resolveElement != nil {
		target := routes[len(routes)-1]
		routes = routes[:len(routes)-1]
		seen := make(map[string]struct{}, len(routes)+1)
		for _, route := range routes {
			seen[route.RequestPath] = struct{}{}
		}
		seen[target.RequestPath] = struct{}{}
		for _, elementPath := range elementEntryPaths {
			if _, ok := seen[elementPath]; ok {
				continue
			}
			elementResponse, ok, err := resolveElement(elementPath)
			if err != nil {
				return nil, err
			}
			if !ok || elementResponse.StatusCode != http.StatusOK {
				continue
			}
			routes = append(routes, qinternal.KindredRoute{RequestPath: elementPath, Response: elementResponse})
			seen[elementPath] = struct{}{}
		}
		routes = append(routes, target)
	}
	var archive bytes.Buffer
	for _, route := range routes {
		record, err := buildMinimalWARCResponseRecord(origin+route.RequestPath, route.Response)
		if err != nil {
			return nil, fmt.Errorf("failed to build Kindred Route WARC record for %q: %w", route.RequestPath, err)
		}
		archive.Write(record)
	}
	return archive.Bytes(), nil
}
