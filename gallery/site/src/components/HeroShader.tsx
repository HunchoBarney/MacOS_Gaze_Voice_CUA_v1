import { MeshGradient } from "@paper-design/shaders-react";
import { useEffect, useRef, useState } from "react";
import { useTheme } from "../theme";

const reduce = matchMedia("(prefers-reduced-motion: reduce)");

export default function HeroShader() {
  const { resolved } = useTheme();
  const host = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(true);
  const [still, setStill] = useState(reduce.matches);

  useEffect(() => {
    const onChange = () => setStill(reduce.matches);
    reduce.addEventListener("change", onChange);
    const observer = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting));
    if (host.current) observer.observe(host.current);
    return () => {
      reduce.removeEventListener("change", onChange);
      observer.disconnect();
    };
  }, []);

  const colors =
    resolved === "dark" ? ["#0a0a0b", "#14203f", "#2b1d3f", "#0a0a0b", "#0f2a33"] : ["#fbfbfd", "#dfe6fb", "#efe2f3", "#fbfbfd", "#dcf0f2"];

  return (
    <div ref={host} className="hero-shader" aria-hidden="true">
      <MeshGradient
        colors={colors}
        distortion={0.55}
        swirl={0.2}
        grainMixer={0}
        grainOverlay={resolved === "dark" ? 0.06 : 0.03}
        speed={still || !visible ? 0 : 0.12}
        frame={8000}
        minPixelRatio={1}
        maxPixelCount={1280 * 720}
        style={{ width: "100%", height: "100%" }}
      />
    </div>
  );
}
