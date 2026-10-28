package main

import (
	"context"
	"sync"

	qinternal "github.com/royalicing/qip/internal"
)

type componentAsset struct {
	body        []byte
	contentType string
}

type elementAsset struct {
	filePath string
}

// RouterFileLayout names the source roots used by QIP Router's file-based
// routing context. Empty optional roots disable that source category.
type RouterFileLayout struct {
	ContentRoot    string
	RecipesRoot    string
	ComponentsRoot string
	ElementsRoot   string
	ViewSource     bool
	// ContentFilter limits which content files are routed.
	ContentFilter qinternal.ContentPathFilter
}

// RouterFileState is a complete snapshot of the file-based router inputs.
// It contains discovered source data, but no live WASM runtime resources.
type RouterFileState struct {
	// contentRoutes are the routes the content filter allows.
	contentRoutes map[string]qinternal.ContentRoute
	// contextRoutes are all content routes. Parent pages outside the content
	// filter still supply their layouts as Kindred Routes.
	contextRoutes         map[string]qinternal.ContentRoute
	contentRead           contentReadFunc
	routeOptions          qinternal.RouteOptions
	recipeFiles           recipeFileSet
	recipeDigests         map[string][][32]byte
	recipeStamps          map[string]moduleFileStamp
	recipeSourceAssets    []qinternal.RecipeSourceAsset
	recipeSourceByPath    map[string]qinternal.RecipeSourceAsset
	recipeSourceIndex     []byte
	componentAssets       map[string]componentAsset
	componentRequestPaths []string
	elementAssets         map[string]elementAsset
	elementRequestPaths   []string
	elementEntryPaths     []string
}

// RouterServerState is an immutable, ready-to-serve router generation.
// Reloads build a replacement generation before atomically swapping it in.
type RouterServerState struct {
	*RouterFileState
	recipeChains  map[string]*qinternal.Pipeline
	recipeOutput  map[string]string
	derivedRoutes *devDerivedRouteSet
}

// routerServerStateSlot keeps a generation alive while requests use it and
// makes replacement a single atomic operation from the router's perspective.
type routerServerStateSlot struct {
	mu    sync.RWMutex
	state *RouterServerState
}

func newRouterServerStateSlot(state *RouterServerState) *routerServerStateSlot {
	return &routerServerStateSlot{state: state}
}

func (slot *routerServerStateSlot) swap(next *RouterServerState) *RouterServerState {
	slot.mu.Lock()
	previous := slot.state
	slot.state = next
	slot.mu.Unlock()
	return previous
}

func (slot *routerServerStateSlot) clear() *RouterServerState {
	return slot.swap(nil)
}

func loadRouterFileState(ctx context.Context, layout RouterFileLayout, routeOptions qinternal.RouteOptions) (*RouterFileState, error) {
	contextRoutes, contentRead, err := loadContentRoutesAndReader(ctx, layout.ContentRoot, routeOptions)
	if err != nil {
		return nil, err
	}
	contentRoutes := qinternal.FilterContentRoutes(contextRoutes, layout.ContentFilter)
	recipeFiles, recipeDigests, err := loadRecipeFileSet(layout.RecipesRoot)
	if err != nil {
		return nil, err
	}
	recipeStamps, err := scanRecipeModuleStamps(layout.RecipesRoot)
	if err != nil {
		return nil, err
	}
	componentAssets, componentRequestPaths, err := loadComponentAssets(layout.ComponentsRoot)
	if err != nil {
		return nil, err
	}
	elementAssets, elementRequestPaths, elementEntryPaths, err := loadElementAssets(layout.ElementsRoot)
	if err != nil {
		return nil, err
	}

	recipeSourceAssets := make([]qinternal.RecipeSourceAsset, 0)
	componentSourceAssets := make([]qinternal.RecipeSourceAsset, 0)
	recipeSourceByPath := make(map[string]qinternal.RecipeSourceAsset)
	var recipeSourceIndex []byte
	if layout.ViewSource && layout.RecipesRoot != "" {
		recipeSourceAssets, err = qinternal.CollectRecipeSourceAssets(layout.RecipesRoot)
		if err != nil {
			return nil, err
		}
		componentSourceAssets, err = qinternal.CollectComponentSourceAssets(layout.ComponentsRoot)
		if err != nil {
			return nil, err
		}
		markdownPaths := qinternal.CollectMarkdownRequestPathsFromRoutes(contentRoutes)
		recipeSourceIndex = qinternal.BuildViewSourceIndexHTML(recipeSourceAssets, markdownPaths, componentRequestPaths, componentSourceAssets)
		recipeSourceByPath = make(map[string]qinternal.RecipeSourceAsset, len(recipeSourceAssets)+len(componentSourceAssets))
		for _, asset := range recipeSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
		for _, asset := range componentSourceAssets {
			recipeSourceByPath[asset.RequestPath] = asset
		}
	}

	return &RouterFileState{
		contentRoutes:         contentRoutes,
		contextRoutes:         contextRoutes,
		contentRead:           contentRead,
		routeOptions:          routeOptions,
		recipeFiles:           recipeFiles,
		recipeDigests:         recipeDigests,
		recipeStamps:          recipeStamps,
		recipeSourceAssets:    recipeSourceAssets,
		recipeSourceByPath:    recipeSourceByPath,
		recipeSourceIndex:     recipeSourceIndex,
		componentAssets:       componentAssets,
		componentRequestPaths: componentRequestPaths,
		elementAssets:         elementAssets,
		elementRequestPaths:   elementRequestPaths,
		elementEntryPaths:     elementEntryPaths,
	}, nil
}

func buildRouterServerState(ctx context.Context, files *RouterFileState, compiler PipelineCompiler) (*RouterServerState, error) {
	recipeChains, err := compileRecipeFileSet(ctx, files.recipeFiles, compiler)
	if err != nil {
		return nil, err
	}
	return &RouterServerState{
		RouterFileState: files,
		recipeChains:    recipeChains,
		recipeOutput:    inferRecipeOutputContentTypes(ctx, recipeChains),
	}, nil
}

func loadRouterServerState(ctx context.Context, layout RouterFileLayout, compiler PipelineCompiler, routeOptions qinternal.RouteOptions) (*RouterServerState, error) {
	files, err := loadRouterFileState(ctx, layout, routeOptions)
	if err != nil {
		return nil, err
	}
	return buildRouterServerState(ctx, files, compiler)
}

func (state *RouterServerState) close(ctx context.Context) {
	if state == nil {
		return
	}
	if state.derivedRoutes != nil {
		state.derivedRoutes.close()
	}
	closePipelines(ctx, state.recipeChains)
}
