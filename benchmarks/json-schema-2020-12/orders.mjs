// The large-document workload for bench.mjs: an order book schema that uses
// $ref, patterns, enum, const, if/then, multipleOf, uniqueItems and
// unevaluatedProperties, and a deterministic generator for matching documents.
export const orderSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: "https://example.com/orders.json",
  type: "object",
  required: ["generated", "orders"],
  properties: {
    generated: { type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$" },
    orders: { type: "array", minItems: 1, items: { $ref: "#/$defs/order" } },
  },
  additionalProperties: false,
  $defs: {
    order: {
      type: "object",
      required: ["id", "customer", "status", "lines"],
      properties: {
        id: { type: "integer", minimum: 1 },
        customer: { $ref: "#/$defs/customer" },
        status: { enum: ["pending", "paid", "shipped", "cancelled"] },
        lines: { type: "array", minItems: 1, items: { $ref: "#/$defs/line" } },
        tags: { type: "array", items: { type: "string" }, uniqueItems: true },
      },
      allOf: [{ if: { properties: { status: { const: "shipped" } } }, then: { required: ["tracking"], properties: { tracking: { type: "string", minLength: 8 } } } }],
      unevaluatedProperties: false,
    },
    customer: {
      type: "object",
      required: ["name", "email"],
      properties: {
        name: { type: "string", minLength: 1, maxLength: 100 },
        email: { type: "string", pattern: "^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$" },
        country: { type: "string", pattern: "^[A-Z]{2}$" },
      },
      additionalProperties: false,
    },
    line: {
      type: "object",
      required: ["sku", "qty", "price"],
      properties: {
        sku: { type: "string", pattern: "^[A-Z]{3}-\\d{4}$" },
        qty: { type: "integer", minimum: 1, maximum: 1000 },
        price: { type: "number", exclusiveMinimum: 0, multipleOf: 0.01 },
      },
      additionalProperties: false,
    },
  },
};

export function makeOrders(count) {
  let seed = 42;
  const rand = (n) => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed % n;
  };
  const statuses = ["pending", "paid", "shipped", "cancelled"];
  const orders = [];
  for (let i = 1; i <= count; i++) {
    const status = statuses[rand(4)];
    const lines = [];
    for (let j = 0, n = 1 + rand(4); j < n; j++) {
      lines.push({
        sku: `${String.fromCharCode(65 + rand(26), 65 + rand(26), 65 + rand(26))}-${String(rand(10000)).padStart(4, "0")}`,
        qty: 1 + rand(20),
        // Whole cents, written the way JSON.stringify writes them (e.g. 12.34).
        price: (100 + rand(99900)) / 100,
      });
    }
    const order = {
      id: i,
      customer: { name: `Customer ${rand(100000)}`, email: `user${rand(100000)}@example.com`, country: ["AU", "US", "GB", "DE"][rand(4)] },
      status,
      lines,
      tags: rand(2) ? ["gift", "priority"] : ["standard"],
    };
    if (status === "shipped") order.tracking = `TRK${String(rand(1e9)).padStart(9, "0")}`;
    orders.push(order);
  }
  return { generated: "2026-11-02T10:00:00Z", orders };
}
