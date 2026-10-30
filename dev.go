package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	qinternal "github.com/royalicing/qip/internal"
)

func devCmd(args []string) {
	opts := options{
		contentTypeChecking: ContentTypeCheckingStrong,
	}
	var recipesRoot string
	var componentsRoot string
	var modeRaw string
	port := 4000
	fs := flag.NewFlagSet("dev", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var devVerbose bool
	fs.BoolVar(&devVerbose, "v", false, "enable verbose logging")
	fs.BoolVar(&devVerbose, "verbose", false, "enable verbose logging")
	fs.StringVar(&recipesRoot, "recipes", "", "recipe QIP components root directory")
	fs.StringVar(&componentsRoot, "components", "", "browser-loadable QIP components root directory")
	fs.StringVar(&modeRaw, "mode", string(modeDev), "runtime mode: dev or prod")
	fs.BoolVar(&opts.viewSource, "view-source", false, "serve /view-source plus recipe source files from --recipes")
	fs.IntVar(&port, "p", 4000, "port")
	var contentRoot string
	qinternal.RegisterRouterCWDFlag(fs, &contentRoot)
	var filterFlags qinternal.ContentFilterFlags
	filterFlags.Register(fs)
	if err := fs.Parse(normalizeDevArgs(args)); err != nil {
		if err == flag.ErrHelp {
			fmt.Println(usageDev)
			return
		}
		gameOver("%s %v", usageDev, err)
	}

	mode, err := parseRuntimeMode(modeRaw)
	if err != nil {
		gameOver("%v", err)
	}
	contentFilter, err := filterFlags.Filter()
	if err != nil {
		gameOver("%v", err)
	}

	opts.verbose = devVerbose
	opts.mode = mode
	contentArgs := fs.Args()
	if err := qinternal.CheckRouterPositionalContentDir("dev", contentArgs, 0); err != nil {
		gameOver("%v", err)
	}
	if len(contentArgs) != 0 {
		gameOver(usageDev)
	}
	if port <= 0 || port > 65535 {
		gameOver("Invalid port: %d", port)
	}

	if err := validateContentRootArg(contentRoot); err != nil {
		gameOver("%v", err)
	}
	projectConfig, err := resolveRouteProjectConfig(contentRoot, recipesRoot, componentsRoot)
	if err != nil {
		gameOver("%v", err)
	}
	recipesRoot = projectConfig.RecipesRoot
	componentsRoot = projectConfig.ComponentsRoot
	if opts.viewSource && recipesRoot == "" {
		gameOver("--view-source requires --recipes <recipes_dir>")
	}
	layout := RouterFileLayout{
		ContentRoot:    contentRoot,
		RecipesRoot:    recipesRoot,
		ComponentsRoot: componentsRoot,
		ElementsRoot:   projectConfig.ElementsRoot,
		ViewSource:     opts.viewSource,
		ContentFilter:  contentFilter,
	}
	qipRuntime := newQIPRuntime(opts)

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	listener, devIdentity, err := listenOrReloadDevServer(addr, port)
	if errors.Is(err, errDevServerReloaded) {
		return
	}
	if err != nil {
		gameOver("dev server error: %v", err)
	}
	defer func() {
		_ = listener.Close()
		removeDevServerIdentity(port, devIdentity)
	}()

	routeOptions := qinternal.DefaultRouteOptions()
	handlerTimeouts := RouterServerTimeouts{
		contentRecipe:   defaultRouteRecipeTimeout,
		applicationWARC: defaultRouteWARCTransformTimeout,
	}
	state, err := loadRouterServerState(context.Background(), layout, qipRuntime, routeOptions)
	if err != nil {
		_ = listener.Close()
		removeDevServerIdentity(port, devIdentity)
		gameOver("%v", err)
	}
	state.derivedRoutes, err = discoverDevDerivedRoutes(context.Background(), state, handlerTimeouts)
	if err != nil {
		state.close(context.Background())
		_ = listener.Close()
		removeDevServerIdentity(port, devIdentity)
		gameOver("%v", err)
	}
	stateSlot := newRouterServerStateSlot(state)
	var reloadMu sync.Mutex
	swapRuntimeState := func(nextState *RouterServerState) {
		previous := stateSlot.swap(nextState)
		if previous != nil {
			previous.close(context.Background())
		}
	}
	reloadRuntimeState := func(reason string) {
		reloadMu.Lock()
		defer reloadMu.Unlock()

		reloadStart := time.Now()
		nextState, err := loadRouterServerState(context.Background(), layout, qipRuntime, routeOptions)
		if err != nil {
			log.Printf("dev: reload failed reason=%s error=%v", reason, err)
			return
		}
		nextState.derivedRoutes, err = discoverDevDerivedRoutes(context.Background(), nextState, handlerTimeouts)
		if err != nil {
			nextState.close(context.Background())
			log.Printf("dev: reload failed reason=%s error=%v", reason, err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=%s paths=%d recipe_mimes=%d components=%d elements=%d duration_ms=%d", reason, len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.componentAssets), len(nextState.elementAssets), time.Since(reloadStart).Milliseconds())
	}
	reloadRecipesIfChanged := func() {
		if opts.mode != modeDev || recipesRoot == "" {
			return
		}

		reloadMu.Lock()
		defer reloadMu.Unlock()

		stamps, err := scanRecipeModuleStamps(recipesRoot)
		if err != nil {
			log.Printf("dev: recipe change check failed: %v", err)
			return
		}

		stateSlot.mu.RLock()
		currentStamps := stateSlot.state.recipeStamps
		unchanged := recipeModuleStampsEqual(currentStamps, stamps)
		stateSlot.mu.RUnlock()
		if unchanged {
			return
		}

		reloadStart := time.Now()
		nextState, err := loadRouterServerState(context.Background(), layout, qipRuntime, routeOptions)
		if err != nil {
			log.Printf("dev: auto-reload failed reason=recipe_change error=%v", err)
			return
		}
		nextState.derivedRoutes, err = discoverDevDerivedRoutes(context.Background(), nextState, handlerTimeouts)
		if err != nil {
			nextState.close(context.Background())
			log.Printf("dev: auto-reload failed reason=recipe_change error=%v", err)
			return
		}

		swapRuntimeState(nextState)
		log.Printf("dev: reloaded reason=recipe_change paths=%d recipe_mimes=%d components=%d elements=%d duration_ms=%d", len(nextState.contentRoutes), len(nextState.recipeChains), len(nextState.componentAssets), len(nextState.elementAssets), time.Since(reloadStart).Milliseconds())
	}

	defer func() {
		current := stateSlot.clear()
		if current != nil {
			current.close(context.Background())
		}
	}()

	log.Printf("dev: indexed %d request paths from %s", len(state.contentRoutes), contentRoot)
	if recipesRoot != "" {
		log.Printf("dev: loaded %d recipe mime chains from %s", len(state.recipeChains), recipesRoot)
	}
	if componentsRoot != "" {
		log.Printf("dev: loaded %d browser components from %s", len(state.componentAssets), componentsRoot)
	}
	if state.derivedRoutes != nil {
		log.Printf("dev: discovered %d full-site routes", len(state.derivedRoutes.known))
	}
	reloadStateIfHardRefresh := func(r *http.Request) {
		if opts.mode != modeDev {
			return
		}
		if !qinternal.IsDevHardRefreshRequest(r) {
			return
		}
		reloadRuntimeState("request_hard_reload")
	}

	handler := newRouterRequestHandler("dev", stateSlot, reloadRecipesIfChanged, reloadStateIfHardRefresh, routeOptions, handlerTimeouts)
	handlerWithIdentity := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/.qip/dev-server" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(devIdentity)
			return
		}
		handler.ServeHTTP(w, r)
	})

	server := &http.Server{
		Addr:    addr,
		Handler: handlerWithIdentity,
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	hupCh := make(chan os.Signal, 1)
	signal.Notify(hupCh, syscall.SIGHUP)
	defer signal.Stop(hupCh)

	var reloadWG sync.WaitGroup
	reloadWG.Go(func() {
		for {
			select {
			case <-signalCtx.Done():
				return
			case <-hupCh:
				reloadRuntimeState("signal_hup")
			}
		}
	})
	defer func() {
		stop()
		reloadWG.Wait()
	}()

	go func() {
		<-signalCtx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("dev: listening on http://%s", addr)
	log.Printf("dev: send SIGHUP to reload routes, recipes, components, and elements: `kill -HUP %d`", os.Getpid())
	log.Printf("dev: browser hard reload (Cache-Control: no-cache/max-age=0) triggers full runtime reload")

	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		gameOver("dev server error: %v", err)
	}
}

var errDevServerReloaded = errors.New("existing qip router dev server reloaded")

type devServerIdentity struct {
	PID   int    `json:"pid"`
	Port  int    `json:"port"`
	Addr  string `json:"addr"`
	Token string `json:"token"`
}

func listenOrReloadDevServer(addr string, port int) (net.Listener, devServerIdentity, error) {
	listener, err := net.Listen("tcp", addr)
	if err == nil {
		identity, err := newDevServerIdentity(addr, port)
		if err != nil {
			_ = listener.Close()
			return nil, devServerIdentity{}, err
		}
		if err := writeDevServerIdentity(port, identity); err != nil {
			log.Printf("dev: reload metadata unavailable: %v", err)
		}
		return listener, identity, nil
	}

	if !errors.Is(err, syscall.EADDRINUSE) {
		return nil, devServerIdentity{}, err
	}
	reloaded, reloadErr := reloadExistingDevServer(addr, port)
	if reloadErr != nil {
		return nil, devServerIdentity{}, reloadErr
	}
	if reloaded {
		return nil, devServerIdentity{}, errDevServerReloaded
	}
	return nil, devServerIdentity{}, err
}

func newDevServerIdentity(addr string, port int) (devServerIdentity, error) {
	var tokenBytes [16]byte
	if _, err := rand.Read(tokenBytes[:]); err != nil {
		return devServerIdentity{}, fmt.Errorf("generate dev server token: %w", err)
	}
	return devServerIdentity{
		PID:   os.Getpid(),
		Port:  port,
		Addr:  addr,
		Token: hex.EncodeToString(tokenBytes[:]),
	}, nil
}

func reloadExistingDevServer(addr string, port int) (bool, error) {
	stored, err := readDevServerIdentity(port)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	if stored.PID <= 0 || stored.Addr != addr || stored.Port != port || stored.Token == "" {
		removeDevServerIdentity(port, stored)
		return false, nil
	}

	live, err := fetchDevServerIdentity(addr)
	if err != nil {
		removeDevServerIdentity(port, stored)
		return false, nil
	}
	if live.PID != stored.PID || live.Port != port || live.Addr != addr || live.Token != stored.Token {
		return false, nil
	}

	process, err := os.FindProcess(live.PID)
	if err != nil {
		removeDevServerIdentity(port, stored)
		return false, nil
	}
	if err := process.Signal(syscall.SIGHUP); err != nil {
		return false, fmt.Errorf("send SIGHUP to existing qip router dev server pid %d: %w", live.PID, err)
	}
	log.Printf("dev: reloaded existing qip router dev server on http://%s with SIGHUP pid=%d", addr, live.PID)
	return true, nil
}

func fetchDevServerIdentity(addr string) (devServerIdentity, error) {
	client := http.Client{Timeout: 250 * time.Millisecond}
	resp, err := client.Get("http://" + addr + "/.qip/dev-server")
	if err != nil {
		return devServerIdentity{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return devServerIdentity{}, fmt.Errorf("identity endpoint returned %s", resp.Status)
	}

	var identity devServerIdentity
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&identity); err != nil {
		return devServerIdentity{}, err
	}
	return identity, nil
}

func writeDevServerIdentity(port int, identity devServerIdentity) error {
	path, err := devServerIdentityPath(port)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(identity)
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o600)
}

func readDevServerIdentity(port int) (devServerIdentity, error) {
	path, err := devServerIdentityPath(port)
	if err != nil {
		return devServerIdentity{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return devServerIdentity{}, err
	}
	var identity devServerIdentity
	if err := json.Unmarshal(data, &identity); err != nil {
		return devServerIdentity{}, err
	}
	return identity, nil
}

func removeDevServerIdentity(port int, identity devServerIdentity) {
	if identity.Token == "" {
		return
	}
	current, err := readDevServerIdentity(port)
	if err != nil {
		return
	}
	if current.PID != identity.PID || current.Token != identity.Token {
		return
	}
	path, err := devServerIdentityPath(port)
	if err != nil {
		return
	}
	_ = os.Remove(path)
}

func devServerIdentityPath(port int) (string, error) {
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "qip", "dev", fmt.Sprintf("127.0.0.1-%d.json", port)), nil
}
