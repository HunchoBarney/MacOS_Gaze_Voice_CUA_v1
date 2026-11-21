import type { CSSProperties } from "react";
import { ArrowUpRightIcon } from "../components/Icons";

type Reference = { title: string; source: string; href: string; steal: string; hue: [number, number]; lead?: boolean };

// Links only: nothing here is rehosted. Every URL was checked live on 2026-11-21.
const REFERENCES: Reference[] = [
  {
    title: "Dynamic Island",
    source: "Apple Newsroom · iPhone 14 Pro",
    href: "https://www.apple.com/newsroom/2022/09/apple-debuts-iphone-14-pro-and-iphone-14-pro-max/",
    steal: "One black shape that grows out of the hardware and morphs between states instead of swapping views.",
    hue: [250, 290],
    lead: true,
  },
  {
    title: "Siri’s edge glow",
    source: "Apple Newsroom · Apple Intelligence",
    href: "https://www.apple.com/newsroom/2024/06/introducing-apple-intelligence-for-iphone-ipad-and-mac/",
    steal: "Listening shown as light around the edge of the screen, so the work in the middle stays untouched.",
    hue: [320, 30],
    lead: true,
  },
  {
    title: "Apple Intelligence and Siri",
    source: "apple.com",
    href: "https://www.apple.com/apple-intelligence/",
    steal: "How Apple shows the glow in motion: colour that reacts to the voice, never a spinner.",
    hue: [200, 330],
  },
  {
    title: "Live Activities",
    source: "Human Interface Guidelines",
    href: "https://developer.apple.com/design/human-interface-guidelines/live-activities",
    steal: "The compact, minimal and expanded sizes of the island, and what content earns each one.",
    hue: [210, 250],
  },
  {
    title: "Motion",
    source: "Human Interface Guidelines",
    href: "https://developer.apple.com/design/human-interface-guidelines/motion",
    steal: "Motion that is brief, purposeful and optional: every movement has to survive Reduce Motion.",
    hue: [170, 220],
  },
  {
    title: "Designing Fluid Interfaces",
    source: "WWDC18 · Apple Developer video",
    href: "https://developer.apple.com/videos/play/wwdc2018/803/",
    steal: "Interruptible, velocity-carrying motion: the interface follows the hand and can be caught mid-flight.",
    hue: [190, 260],
  },
  {
    title: "Animate with springs",
    source: "WWDC23 · Apple Developer video",
    href: "https://developer.apple.com/videos/play/wwdc2023/10158/",
    steal: "Duration and bounce as the two spring knobs; zero bounce unless a gesture threw it.",
    hue: [140, 200],
  },
  {
    title: "Raycast",
    source: "raycast.com",
    href: "https://www.raycast.com/",
    steal: "A keyboard-first Mac surface with no open or close animation, because it’s used a hundred times a day.",
    hue: [0, 20],
  },
  {
    title: "Arc",
    source: "arc.net (now a farewell page; Arc sunsets on 2026-12-22)",
    href: "https://arc.net/",
    steal: "Playful details kept out of the way of the page, and a sidebar that never fights the content.",
    hue: [330, 270],
  },
  {
    title: "How we redesigned the Linear UI",
    source: "Linear · Now",
    href: "https://linear.app/now/how-we-redesigned-the-linear-ui",
    steal: "Calm chrome, fewer colours and a strict grid, so the content carries the contrast.",
    hue: [235, 260],
  },
  {
    title: "Invisible Details of Interaction Design",
    source: "Rauno Freiberg",
    href: "https://rauno.me/craft/interaction-design",
    steal: "Why interactions feel right: metaphors from the physical world, frequency and fidelity.",
    hue: [30, 60],
  },
  {
    title: "Building a toast component",
    source: "Emil Kowalski · Sonner",
    href: "https://emilkowal.ski/ui/building-a-toast-component",
    steal: "The small decisions behind Sonner: interruptible transitions, swipe that matches the entrance, nothing default.",
    hue: [0, 0],
  },
  {
    title: "Vaul",
    source: "Emil Kowalski",
    href: "https://vaul.emilkowal.ski/",
    steal: "A sheet that tracks the finger 1:1 and dismisses on velocity; the picks sheet on this site uses it.",
    hue: [260, 200],
  },
  {
    title: "Family Values",
    source: "Benji Taylor · Family",
    href: "https://benji.org/family-values",
    steal: "Simplicity, fluidity and delight as three rules, with every transition explained by where things come from.",
    hue: [100, 160],
  },
  {
    title: "libraries.dev",
    source: "Beam, Orb, Voice glow",
    href: "https://libraries.dev/",
    steal: "Ready-made glows and orbs with SwiftUI builds, so the voice surface starts from craft, not from scratch.",
    hue: [280, 180],
  },
  {
    title: "DynamicNotchKit",
    source: "GitHub · MIT",
    href: "https://github.com/MrKai77/DynamicNotchKit",
    steal: "A Dynamic Island for the MacBook notch in SwiftUI: the hardware-anchored shape, done natively.",
    hue: [220, 300],
  },
];

export function References() {
  return (
    <div className="page rd-refs">
      <header className="rd-head">
        <p className="eyebrow">Redesign</p>
        <h1 className="title-1">The bar</h1>
        <p className="lede">The work these directions are measured against. Each card links to the original and names the one thing worth taking from it.</p>
      </header>
      <ul className="rd-ref-grid">
        {REFERENCES.map((ref) => (
          <li key={ref.href} data-lead={ref.lead || undefined}>
            <a className="rd-ref" href={ref.href} target="_blank" rel="noreferrer" style={{ "--h1": ref.hue[0], "--h2": ref.hue[1] } as CSSProperties}>
              <span className="rd-ref-art" aria-hidden="true" />
              <span className="rd-ref-text">
                <span className="rd-ref-source">{ref.source}</span>
                <span className="rd-ref-title">
                  {ref.title} <ArrowUpRightIcon size={14} />
                </span>
                <span className="rd-ref-steal">{ref.steal}</span>
              </span>
            </a>
          </li>
        ))}
      </ul>
    </div>
  );
}
