import { useEffect } from "react";
import { go, useRoute } from "./lib/router";
import { Breadcrumbs } from "./shell/Breadcrumbs";
import { ActivityPill } from "./shell/Activity";
import { ModelsPill } from "./shell/Models";
import { useApp } from "./state/app";
import { useDesign } from "./state/design";
import { FindStage } from "./stages/find/FindStage";
import { GatherStage } from "./stages/gather/GatherStage";
import { DesignStage } from "./stages/design/DesignStage";
import { ReviewStage } from "./stages/review/ReviewStage";
import { StatusSlot, TitleActions } from "./shell/slots";

export function App() {
  const route = useRoute();
  const loadProgram = useApp((s) => s.loadProgram);
  const transport = useApp((s) => s.transport);
  const toast = useApp((s) => s.toast);
  const programError = useApp((s) => s.programError);

  useEffect(() => { if (route.slug) void loadProgram(route.slug); }, [route.slug, loadProgram]);
  useEffect(() => {
    if (route.slug && (route.stage === "design" || route.stage === "review")) void useDesign.getState().load(route.slug);
  }, [route.slug, route.stage]);

  return (
    <div className="app">
      <header className="titlebar">
        <div className="brand"><i /> Icon Lab {transport === "mock" && <span className="tag" title="The engine didn't answer, so this is the in-browser mock">mock</span>}</div>
        <Breadcrumbs route={route} />
        <div className="tb-right"><TitleActions.Slot /></div>
      </header>
      <main className="main">
        {programError && route.slug ? (
          <div className="empty">Couldn't open “{route.slug}”: {programError}<br /><button className="btn" style={{ marginTop: 8 }} onClick={() => go(null, "find")}>Choose a program</button></div>
        ) : route.stage === "find" || !route.slug ? <FindStage route={route} />
          : route.stage === "gather" ? <GatherStage slug={route.slug} />
          : route.stage === "review" ? <ReviewStage slug={route.slug} />
          : <DesignStage slug={route.slug} />}
      </main>
      <footer className="statusbar">
        <StatusSlot.Slot />
        <ModelsPill />
        <ActivityPill />
      </footer>
      {toast && <div className={"toast " + toast.kind} role="status">{toast.text}{toast.action && <button className="toast-act" onClick={() => { toast.action!.run(); useApp.setState({ toast: null }); }}>{toast.action.label}</button>}</div>}
    </div>
  );
}
