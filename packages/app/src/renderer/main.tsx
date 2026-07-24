import { createRoot } from "react-dom/client";
import { App } from "./App";
// Tokens first: island.css consumes the type scale defined here.
import "./styles/tokens.css";
import "./styles/island.css";
import "./styles/weather.css";

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(<App />);
}
