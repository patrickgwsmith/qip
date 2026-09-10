import { ClientHighlighter } from "./client-highlighter.js";
import { highlightTSX } from "../lib/tsx-server.js";

const initialSource = `export function Greeting({ name }) {
  return <button className="primary">Hello, {name}!</button>;
}`;

export default async function Page() {
  const highlighted = await highlightTSX(initialSource);

  return (
    <main>
      <h1>Highlight TSX with QIP</h1>
      <p>
        The server and browser run the same syntax-highlighting WebAssembly
        component.
      </p>

      <section>
        <h2>Server Component</h2>
        <p>This result is cached and included in the prerendered page.</p>
        <div
          className="highlighted-code"
          dangerouslySetInnerHTML={{ __html: highlighted }}
        />
      </section>

      <ClientHighlighter initialValue={initialSource} />
    </main>
  );
}
