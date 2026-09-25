function number(value, places = 2) {
  return Number(value.toFixed(places)).toString();
}

function attributeNumber(element, name) {
  return Number(element.getAttribute(name));
}

function color(stop) {
  const hex = stop.getAttribute("stop-color").toUpperCase();
  const opacity = Number(stop.getAttribute("stop-opacity") ?? "1");
  if (opacity >= 1) return hex;
  const red = Number.parseInt(hex.slice(1, 3), 16);
  const green = Number.parseInt(hex.slice(3, 5), 16);
  const blue = Number.parseInt(hex.slice(5, 7), 16);
  return `rgb(${red} ${green} ${blue} / ${number(opacity, 4)})`;
}

function stopsFor(gradient, position) {
  return Array.from(gradient.querySelectorAll("stop"), (stop) => {
    const raw = stop.getAttribute("offset");
    const offset = raw.endsWith("%") ? Number.parseFloat(raw) / 100 : Number(raw);
    return `  ${color(stop)} ${number(position(offset))}%`;
  }).join(",\n");
}

export function svgGradientCSS(svg) {
  const gradient = svg.querySelector("[data-qip-gradient-definition]");
  const swatch = svg.querySelector("[data-qip-gradient-swatch]");
  if (!gradient || !swatch) return "";

  const x = attributeNumber(swatch, "x");
  const y = attributeNumber(swatch, "y");
  const width = attributeNumber(swatch, "width");
  const height = attributeNumber(swatch, "height");

  if (gradient.localName === "radialGradient") {
    const cx = attributeNumber(gradient, "cx") - x;
    const cy = attributeNumber(gradient, "cy") - y;
    const radius = attributeNumber(gradient, "r");
    return `background: radial-gradient(\n  circle ${number(radius)}px at ${number(cx)}px ${number(cy)}px,\n${stopsFor(gradient, (offset) => offset * 100)}\n);`;
  }

  if (gradient.localName === "linearGradient") {
    const x1 = attributeNumber(gradient, "x1");
    const y1 = attributeNumber(gradient, "y1");
    const dx = attributeNumber(gradient, "x2") - x1;
    const dy = attributeNumber(gradient, "y2") - y1;
    const lengthSquared = dx * dx + dy * dy;
    if (lengthSquared === 0) return "";
    const angle = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
    const project = (px, py) => ((px - x1) * dx + (py - y1) * dy) / lengthSquared;
    const corners = [
      project(x, y), project(x + width, y),
      project(x, y + height), project(x + width, y + height),
    ];
    const first = Math.min(...corners);
    const last = Math.max(...corners);
    const position = (offset) => (offset - first) / (last - first) * 100;
    return `background: linear-gradient(\n  ${number(angle)}deg,\n${stopsFor(gradient, position)}\n);`;
  }

  return "";
}
