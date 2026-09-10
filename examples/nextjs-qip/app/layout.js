import "./styles.css";

export const metadata = {
  title: "Highlight TSX with QIP and Next.js",
  description: "One QIP syntax highlighter running on the server and in the browser",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
