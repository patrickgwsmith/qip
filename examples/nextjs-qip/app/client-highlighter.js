"use client";

import { useEffect, useState } from "react";

import { createTSXHighlighter } from "../lib/qip-content.js";

let highlighterPromise;

function loadHighlighter() {
  highlighterPromise ??= WebAssembly.instantiateStreaming(
    fetch("/qip-components/html-code-syntax-highlight-tsx.wasm"),
    {},
  ).then(({ instance }) => createTSXHighlighter(instance.exports));
  return highlighterPromise;
}

export function ClientHighlighter({ initialValue }) {
  const [source, setSource] = useState(initialValue);
  const [highlight, setHighlight] = useState(null);
  const [loadError, setLoadError] = useState("");

  useEffect(() => {
    let active = true;

    loadHighlighter().then(
      (loaded) => {
        if (active) setHighlight(() => loaded);
      },
      (error) => {
        if (active) setLoadError(error.message);
      },
    );

    return () => {
      active = false;
    };
  }, []);

  let output = "";
  let renderError = "";
  if (highlight) {
    try {
      output = highlight(source);
    } catch (error) {
      output = "";
      renderError = error.message;
    }
  }

  return (
    <section>
      <h2>Client Component</h2>
      <p>
        Edit the TSX. The browser highlights each change with the same Wasm
        component.
      </p>
      <label htmlFor="tsx-source">TSX source</label>
      <textarea
        id="tsx-source"
        rows="8"
        value={source}
        onChange={(event) => setSource(event.target.value)}
      />
      {loadError || renderError ? (
        <p role="alert">Could not run component: {loadError || renderError}</p>
      ) : null}
      {output ? (
        <div
          className="highlighted-code"
          dangerouslySetInnerHTML={{ __html: output }}
        />
      ) : (
        <p aria-live="polite">Loading component…</p>
      )}
    </section>
  );
}
