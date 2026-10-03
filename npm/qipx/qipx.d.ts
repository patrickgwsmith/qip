declare const contentTypeBrand: unique symbol;
declare const contentComponentContractBrand: unique symbol;

export interface ContentType {
  readonly [contentTypeBrand]: true;
  readonly encoding: "bytes" | "utf8";
  readonly mediaType?: string;
}

export interface ContentComponentContractOptions {
  label?: string;
  maxMemory?: number | string;
  inputType?: ContentType;
  outputType?: ContentType;
}

export interface ContentComponentContract {
  readonly [contentComponentContractBrand]: true;
  readonly label?: string;
  readonly maxMemory?: number;
  readonly inputType?: ContentType;
  readonly outputType?: ContentType;
}

export interface RecipeOptions {
  capacitiesMustFit?: boolean;
}

export interface ContentComponent {
  label: string;
  instance: WebAssembly.Instance;
  exports: WebAssembly.Exports;
  inputType: ContentType;
  outputType: ContentType;
  inputCapacity: number;
  outputCapacity: number;
}

export interface RecipeStageSpec {
  component: ContentComponent;
  label?: string;
  uniforms?: Array<[key: string, value: string | number]>;
}

export type RecipeStep = ContentComponent | RecipeStageSpec | Recipe;

export interface RenderResult {
  readonly outputBytes: Uint8Array;
  readonly outputString?: string;
  readonly outputType: ContentType;
}

export class ContentRejection extends Error {
  constructor(label: string, inputOffset?: number, failureMode?: number);
  readonly label: string;
  readonly inputOffset?: number;
  readonly failureMode?: number;
}

export interface RecipeStage {
  label: string;
  uniforms: Array<[key: string, value: string | number]>;
  component: ContentComponent;
  inputType: ContentType;
  outputType: ContentType;
  inputCapacity: number;
  outputCapacity: number;
}

export interface Recipe {
  stages: readonly RecipeStage[];
  outputType: ContentType;
}

export function contentTypeUTF8(optionalMIMEType?: string): ContentType;
export function contentTypeBytes(optionalMIMEType?: string): ContentType;
export function newContentComponentContract(options?: ContentComponentContractOptions): ContentComponentContract;
export function wasmMustComplyWithComponentContract(wasm: Uint8Array | ArrayBuffer, contract?: ContentComponentContract): void;
export function newComponent(wasm: Uint8Array | ArrayBuffer, instance: WebAssembly.Instance, contract?: ContentComponentContract): ContentComponent;
export function createRecipe(steps: RecipeStep[], options?: RecipeOptions): Recipe;
export function render(target: ContentComponent | Recipe, input: Uint8Array | ArrayBuffer | string): RenderResult;
