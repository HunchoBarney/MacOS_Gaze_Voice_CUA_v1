import { MotionConfig } from "motion/react";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { Toaster } from "sonner";
import { App } from "./App";
import { startSmoothScroll } from "./scroll";
import { useTheme } from "./theme";
import "./styles.css";

function Toasts() {
  const { resolved } = useTheme();
  return <Toaster theme={resolved} position="bottom-center" offset={24} toastOptions={{ className: "toast", duration: 2400 }} />;
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <MotionConfig reducedMotion="user">
      <App />
      <Toasts />
    </MotionConfig>
  </StrictMode>,
);

void startSmoothScroll();
