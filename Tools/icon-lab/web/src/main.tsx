import { createRoot } from "react-dom/client";
import { chooseTransport, setTransport } from "./api";
import { App } from "./App";
import { useApp } from "./state/app";
import { connectEvents } from "./state/jobs";
import "./styles.css";

async function start() {
  const t = await chooseTransport();
  setTransport(t);
  useApp.setState({ transport: t.kind });
  connectEvents();
  void useApp.getState().loadPrograms();
  createRoot(document.getElementById("root")!).render(<App />);
}

void start();
