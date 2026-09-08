import { ClientNormalizer } from "./client-normalizer.js";
import { normalizeE164 } from "../lib/e164-server.js";

const initialPhoneNumber = "+1 (212) 555-0100";

export default function Page() {
  const normalized = normalizeE164(initialPhoneNumber);

  return (
    <main>
      <h1>QIP with Next.js</h1>
      <p>
        The server and browser run the same deterministic WebAssembly
        component.
      </p>

      <section>
        <h2>Server Component</h2>
        <dl>
          <dt>Input</dt>
          <dd>{initialPhoneNumber}</dd>
          <dt>Output</dt>
          <dd>{normalized}</dd>
        </dl>
      </section>

      <ClientNormalizer initialValue={initialPhoneNumber} />
    </main>
  );
}
