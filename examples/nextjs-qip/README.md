# QIP With Next.js

This small application runs the same QIP TSX syntax-highlighting component in
a React Server Component and a React Client Component. The server result uses
Next.js Cache Components and is included in the prerendered page. The client
result updates as you edit the source.

From this directory:

```bash
npm install
npm test
npm run build
npm run dev
```

Open <http://localhost:3000>. The preparation scripts copy
`components/text/html/html-code-syntax-highlight-tsx.wasm` from the repository
into `public/qip-components`. The generated copy is not tracked.
