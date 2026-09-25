const URL_PATTERN = /https?:\/\/[^\s<>\x22\x27]+/gi;
const TRAILING_PUNCTUATION = /[.,;:!?]$/;

function trimURL(value) {
  let end = value.length;
  while (end > 0) {
    const last = value[end - 1];
    if (TRAILING_PUNCTUATION.test(last)) {
      end--;
      continue;
    }
    const pair = { ")": "(", "]": "[", "}": "{" }[last];
    if (!pair) break;
    const body = value.slice(0, end);
    if (body.split(last).length <= body.split(pair).length) break;
    end--;
  }
  return value.slice(0, end);
}

function httpLinks(text) {
  const links = [];
  for (const match of text.matchAll(URL_PATTERN)) {
    const start = match.index;
    if (start > 0 && /[\p{L}\p{N}_]/u.test(text[start - 1])) continue;
    const label = trimURL(match[0]);
    if (label.length > 2048) continue;
    let url;
    try { url = new URL(label); }
    catch { continue; }
    if (!url.hostname || !["http:", "https:"].includes(url.protocol) ||
        url.username || url.password) continue;
    links.push({ start, end: start + label.length, label, href: url.href });
  }
  return links;
}

function linkifyHttpURLs(root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node);
  for (const node of nodes) {
    const value = node.textContent;
    const links = httpLinks(value);
    if (links.length === 0) continue;
    const replacement = document.createDocumentFragment();
    let cursor = 0;
    for (const link of links) {
      replacement.append(document.createTextNode(value.slice(cursor, link.start)));
      const anchor = document.createElement("a");
      anchor.href = link.href;
      anchor.textContent = link.label;
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
      anchor.referrerPolicy = "no-referrer";
      anchor.style.color = "#8ecbff";
      anchor.style.textDecoration = "underline";
      replacement.append(anchor);
      cursor = link.end;
    }
    replacement.append(document.createTextNode(value.slice(cursor)));
    node.replaceWith(replacement);
  }
}

export { httpLinks, linkifyHttpURLs };
