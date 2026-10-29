package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"log"
	"net/http"
	"os"
	"slices"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

type RouterServerTimeouts struct {
	contentRecipe   time.Duration
	applicationWARC time.Duration
}

func newRouterRequestHandler(logPrefix string, stateSlot *routerServerStateSlot, reloadRecipesIfChanged func(), reloadStateForRequest func(*http.Request), routeOptions qinternal.RouteOptions, timeouts RouterServerTimeouts) http.Handler {
	return qinternal.NewRequestHandler(qinternal.RequestHandlerConfig{
		LogPrefix:    logPrefix,
		RouteOptions: routeOptions,
		Reload:       reloadRecipesIfChanged,
		WriteError: func(w http.ResponseWriter, err error) {
			writeDevError(w, err)
		},
		FormatDuration: formatDurationParts,
		Logf: func(format string, args ...any) {
			log.Printf(format, args...)
		},
		Resolve: func(r *http.Request, reqID uint64) (qinternal.RoutedResponse, error) {
			if reloadStateForRequest != nil {
				reloadStateForRequest(r)
			}

			stateSlot.mu.RLock()
			current := stateSlot.state
			if current == nil {
				stateSlot.mu.RUnlock()
				return qinternal.RoutedResponse{}, errors.New("runtime state is unavailable")
			}
			if current.derivedRoutes != nil {
				current.derivedRoutes.start()
				response, known, err := current.derivedRoutes.resolve(r.Context(), r.URL.Path)
				if err != nil {
					stateSlot.mu.RUnlock()
					return qinternal.RoutedResponse{}, err
				}
				if known {
					stateSlot.mu.RUnlock()
					headers := response.Header.Clone()
					headers.Del("Content-Length")
					return qinternal.RoutedResponse{
						StatusCode:             response.StatusCode,
						Header:                 headers,
						Body:                   response.Body,
						ModuleDurations:        []time.Duration{},
						InstantiationDurations: []time.Duration{},
					}, nil
				}
			}
			if response, ok := resolveRecipeSourceResponse(r.URL.Path, current); ok {
				stateSlot.mu.RUnlock()
				return response, nil
			}
			if response, ok := resolveComponentAssetResponse(r.URL.Path, current); ok {
				stateSlot.mu.RUnlock()
				return response, nil
			}
			if _, ok := current.elementAssets[r.URL.Path]; ok {
				response, _, err := resolveElementAssetResponse(r.Context(), current, r.URL.Path, reqID, timeouts)
				stateSlot.mu.RUnlock()
				if err != nil {
					return qinternal.RoutedResponse{}, err
				}
				return qinternal.RoutedResponse{StatusCode: response.StatusCode, Header: response.Header, Body: response.Body}, nil
			}

			route, ok := qinternal.ResolveContentRoute(current.contentRoutes, r.URL.Path, current.routeOptions)
			if !ok {
				response, handled, err := current.derivedRoutes.resolveMissing(r.Context(), r.URL.Path)
				stateSlot.mu.RUnlock()
				if err != nil {
					return qinternal.RoutedResponse{}, err
				}
				if handled {
					headers := response.Header.Clone()
					headers.Del("Content-Length")
					return qinternal.RoutedResponse{
						StatusCode:             response.StatusCode,
						Header:                 headers,
						Body:                   response.Body,
						ModuleDurations:        []time.Duration{},
						InstantiationDurations: []time.Duration{},
					}, nil
				}
				return qinternal.RoutedResponse{
					StatusCode: http.StatusNotFound,
					Header:     http.Header{"Content-Type": []string{"text/plain; charset=utf-8"}},
					Body:       []byte("404 page not found\n"),
				}, nil
			}

			contentRead := current.contentRead
			if contentRead == nil {
				contentRead = func(_ context.Context, route qinternal.ContentRoute) ([]byte, error) {
					return os.ReadFile(route.FilePath)
				}
			}
			inputBytes, err := contentRead(r.Context(), route)
			if err != nil {
				stateSlot.mu.RUnlock()
				return qinternal.RoutedResponse{}, err
			}
			sourceDigest := sha256.Sum256(inputBytes)

			hasRecipes := shouldApplyRecipesForRequestPath(r.URL.Path, route, current.recipeChains)
			var result qinternal.Content = qinternal.NewRawBytesContentWithType(inputBytes, route.SourceMIME)
			if hasRecipes {
				pipeline := current.recipeChains[route.SourceMIME]
				ctx := r.Context()
				ctx, cancel := withExecutionTimeout(ctx, timeouts.contentRecipe)
				defer cancel()
				result, err = pipeline.Process(ctx, result, reqID)
				if err != nil {
					stateSlot.mu.RUnlock()
					return qinternal.RoutedResponse{}, err
				}
			}

			result, body, err := ensureRawContent(result)
			if err != nil {
				stateSlot.mu.RUnlock()
				return qinternal.RoutedResponse{}, err
			}

			contentType := routerResponseContentType(route.SourceMIME, hasRecipes, result, body)
			response := qinternal.InProcessHTTPResponse{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{contentType}},
				Body:       body,
			}
			applicationWARCPipeline := current.recipeChains[applicationWARCRecipeMIME]
			if applicationWARCPipeline != nil {
				ctx := r.Context()
				ctx, cancel := withExecutionTimeout(ctx, timeouts.applicationWARC)
				defer cancel()
				response, err = transformRouteResponseWithKindredRoutes(ctx, applicationWARCPipeline, r.URL.Path, response, reqID, func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
					return resolveRouterBaseResponse(ctx, current, requestPath, reqID, timeouts)
				}, func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
					return resolveKindredStaticRoute(ctx, current, requestPath)
				}, current.elementEntryPaths, func(requestPath string) (qinternal.InProcessHTTPResponse, bool, error) {
					return resolveElementAssetResponse(ctx, current, requestPath, reqID, timeouts)
				})
				if err != nil {
					stateSlot.mu.RUnlock()
					return qinternal.RoutedResponse{}, err
				}
			}

			headers := response.Header.Clone()
			if headers == nil {
				headers = make(http.Header)
			}
			headers.Del("Content-Length")
			var recipeDigests [][32]byte
			if hasRecipes {
				recipeDigests = slices.Clone(current.recipeDigests[route.SourceMIME])
			}
			if applicationRecipeDigests := current.recipeDigests[applicationWARCRecipeMIME]; len(applicationRecipeDigests) > 0 {
				recipeDigests = append(recipeDigests, applicationRecipeDigests...)
			}
			responseMediaType := mediaTypeOnly(headers.Get("Content-Type"))
			canUseDevETag := response.StatusCode >= http.StatusOK &&
				response.StatusCode < http.StatusMultipleChoices &&
				responseMediaType != "text/html" &&
				responseMediaType != "application/xhtml+xml"
			if canUseDevETag {
				etag := buildDevETag(sourceDigest, recipeDigests)
				if etag != "" {
					headers.Set("ETag", etag)
					if r.Header.Get("If-None-Match") == etag {
						stateSlot.mu.RUnlock()
						return qinternal.RoutedResponse{
							StatusCode:             http.StatusNotModified,
							Header:                 headers,
							ModuleDurations:        []time.Duration{},
							InstantiationDurations: []time.Duration{},
						}, nil
					}
				}
			}
			stateSlot.mu.RUnlock()

			statusCode := response.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusOK
			}
			return qinternal.RoutedResponse{
				StatusCode:             statusCode,
				Header:                 headers,
				Body:                   response.Body,
				ModuleDurations:        []time.Duration{},
				InstantiationDurations: []time.Duration{},
			}, nil
		},
	})
}

func resolveRecipeSourceResponse(requestPath string, state *RouterServerState) (qinternal.RoutedResponse, bool) {
	if state == nil || len(state.recipeSourceIndex) == 0 {
		return qinternal.RoutedResponse{}, false
	}
	switch requestPath {
	case "/view-source", "/view-source/":
		return qinternal.RoutedResponse{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
			Body:       state.recipeSourceIndex,
		}, true
	}
	asset, ok := state.recipeSourceByPath[requestPath]
	if !ok {
		return qinternal.RoutedResponse{}, false
	}
	return qinternal.RoutedResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{asset.ContentType}},
		Body:       asset.Body,
	}, true
}

func resolveComponentAssetResponse(requestPath string, state *RouterServerState) (qinternal.RoutedResponse, bool) {
	if state == nil || len(state.componentAssets) == 0 {
		return qinternal.RoutedResponse{}, false
	}
	asset, ok := state.componentAssets[requestPath]
	if !ok {
		return qinternal.RoutedResponse{}, false
	}
	return qinternal.RoutedResponse{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{asset.contentType}},
		Body:       asset.body,
	}, true
}
