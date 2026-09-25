import assert from "node:assert/strict";
import test from "node:test";
import { svgGradientCSS } from "../site/svg-gradient-css.js";

function element(localName, attributes, children = []) {
  return {
    localName,
    getAttribute(name) { return attributes[name] ?? null; },
    querySelectorAll(name) { return name === "stop" ? children : []; },
  };
}

function svg(gradient, swatch) {
  return {
    querySelector(selector) {
      return selector === "[data-qip-gradient-definition]" ? gradient :
        selector === "[data-qip-gradient-swatch]" ? swatch : null;
    },
  };
}

test("CSS linear stops preserve the SVG colors at their canvas positions", () => {
  const gradient = element("linearGradient", { x1: "25", y1: "50", x2: "75", y2: "50" }, [
    element("stop", { offset: "0", "stop-color": "#112233", "stop-opacity": "1" }),
    element("stop", { offset: "0.5", "stop-color": "#445566", "stop-opacity": "0.5" }),
    element("stop", { offset: "1", "stop-color": "#778899", "stop-opacity": "1" }),
  ]);
  const swatch = element("rect", { x: "0", y: "0", width: "100", height: "100" });
  assert.equal(svgGradientCSS(svg(gradient, swatch)), [
    "background: linear-gradient(",
    "  90deg,",
    "  #112233 25%,",
    "  rgb(68 85 102 / 0.5) 50%,",
    "  #778899 75%",
    ");",
  ].join("\n"));
});

test("CSS radial center and radius use the swatch's local coordinates", () => {
  const gradient = element("radialGradient", { cx: "155", cy: "260", r: "300" }, [
    element("stop", { offset: "0", "stop-color": "#000000" }),
    element("stop", { offset: "100%", "stop-color": "#FFFFFF" }),
  ]);
  const swatch = element("rect", { x: "34", y: "72", width: "732", height: "342" });
  assert.equal(svgGradientCSS(svg(gradient, swatch)), [
    "background: radial-gradient(",
    "  circle 300px at 121px 188px,",
    "  #000000 0%,",
    "  #FFFFFF 100%",
    ");",
  ].join("\n"));
});
