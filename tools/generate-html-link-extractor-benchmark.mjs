import { fileURLToPath } from "node:url";

export function generateHTMLLinkExtractorBenchmark() {
  let html = "";
  for (let i = 0; i < 128; i++) {
    html += `<span id=l${i}>Label ${i}</span>`;
  }
  for (let i = 0; i < 128; i++) {
    html += `<a href=/p${i} aria-labelledby="l${i} l${(i + 17) % 128} l${(i + 53) % 128} l${(i + 91) % 128}">ignored</a>`;
  }
  return html;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.stdout.write(generateHTMLLinkExtractorBenchmark());
}
