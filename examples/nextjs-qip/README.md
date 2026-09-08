# QIP With Next.js

This small application runs the same QIP E.164 component in a React Server
Component and a React Client Component.

From this directory:

```bash
npm install
npm test
npm run build
npm run dev
```

Open <http://localhost:3000>. The preparation scripts copy
`components/text/e164.wasm` from the repository into `public/qip-components`.
The generated copy is not tracked.
