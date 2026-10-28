import type { IncomingMessage, Server, ServerResponse } from "node:http";

export interface QIPRouterOptions {
  contentRoot?: string;
  root?: string;
  recipesRoot?: string;
  componentsRoot?: string;
  elementsRoot?: string;
  /**
   * Route only content files under these paths, relative to the content root.
   * With no include paths, every content file is a candidate.
   */
  include?: string[];
  /**
   * Do not route content files under these paths. Excludes apply after
   * includes; order does not matter. Either option also skips dot paths
   * unless an include path names them.
   */
  exclude?: string[];
}

export interface QIPContentFilter {
  readonly active: boolean;
  /** Whether the content file at relPath, relative to the content root, is routed. */
  allows(relPath: string): boolean;
}

export function createContentFilter(options?: { include?: string[]; exclude?: string[] }): QIPContentFilter;

export interface ListenOptions {
  hostname?: string;
  port?: number;
}

export interface QIPResponse {
  status: number;
  headers: Headers;
  body: Uint8Array;
}

export interface QIPRouteEntry {
  method: "GET" | "HEAD";
  path: string;
  contentType: string;
}

export interface QIPKindredRouteEntry {
  method: "GET";
  path: string;
}

export interface QIPWarcOptions {
  /**
   * Rerun each page's application/warc recipes with only its Kindred Routes
   * and reject if any page's status, headers, or body differ.
   */
  checkKindred?: boolean;
  /**
   * With checkKindred, how long one page's application/warc recipes may run.
   * A page that runs longer stops the check and rejects; nothing is retried.
   * Defaults to 5000.
   */
  kindredPageTimeoutMs?: number;
}

export interface QIPRouter {
  readonly contentRoot: string;
  readonly recipesRoot: string;
  reload(): Promise<QIPRouter>;
  resolve(method: string, requestTarget: string): Promise<QIPResponse>;
  get(requestTarget: string): Promise<QIPResponse>;
  /** Returns response headers with an empty Uint8Array body. */
  head(requestTarget: string): Promise<QIPResponse>;
  kindred(requestTarget: string): Promise<QIPKindredRouteEntry[]>;
  list(): QIPRouteEntry[];
  warc(options?: QIPWarcOptions): Promise<Uint8Array>;
  fetch(request: Request): Promise<Response>;
  handler(request: IncomingMessage, response: ServerResponse): Promise<void>;
  listen(options?: ListenOptions): Promise<Server>;
}

export function createQIPRouter(options?: QIPRouterOptions): Promise<QIPRouter>;

export function main(argv?: string[]): Promise<void>;
