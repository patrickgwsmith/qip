// Times one RegExp.test call per input length off the main thread, so the
// page can stop a backtracking engine that runs too long by terminating this
// worker.
self.onmessage = (event) => {
  const { source, char, tail, lengths } = event.data;
  const re = new RegExp(source, "u");
  for (const n of lengths) {
    const text = char.repeat(n) + tail;
    const started = performance.now();
    let matched;
    try {
      matched = re.test(text);
    } catch (error) {
      self.postMessage({ n, error: String(error?.message ?? error) });
      return;
    }
    self.postMessage({ n, ms: performance.now() - started, matched });
  }
  self.postMessage({ done: true });
};
