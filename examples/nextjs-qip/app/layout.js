import "./styles.css";

export const metadata = {
  title: "QIP with Next.js",
  description: "One QIP component running on the server and in the browser",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
