"use client";

import { useEffect, useState } from "react";

import { createTextRenderer } from "../lib/qip-content.js";

let rendererPromise;

function loadRenderer() {
  rendererPromise ??= WebAssembly.instantiateStreaming(
    fetch("/qip-components/e164.wasm"),
    {},
  ).then(({ instance }) => createTextRenderer(instance.exports));
  return rendererPromise;
}

export function ClientNormalizer({ initialValue }) {
  const [source, setSource] = useState(initialValue);
  const [normalize, setNormalize] = useState(null);
  const [loadError, setLoadError] = useState("");

  useEffect(() => {
    let active = true;

    loadRenderer().then(
      (loaded) => {
        if (active) setNormalize(() => loaded);
      },
      (error) => {
        if (active) setLoadError(error.message);
      },
    );

    return () => {
      active = false;
    };
  }, []);

  let output = "Loading component…";
  if (loadError) {
    output = `Could not load component: ${loadError}`;
  } else if (normalize) {
    try {
      output = normalize(source);
    } catch (error) {
      output = error.message;
    }
  }

  return (
    <section>
      <h2>Client Component</h2>
      <label htmlFor="phone-number">Phone number</label>
      <input
        id="phone-number"
        value={source}
        onChange={(event) => setSource(event.target.value)}
      />
      <p aria-live="polite">
        Output: <output htmlFor="phone-number">{output}</output>
      </p>
    </section>
  );
}
