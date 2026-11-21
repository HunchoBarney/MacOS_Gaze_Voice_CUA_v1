export type Area = "Voice" | "Gaze" | "Guide" | "Agents" | "Proactive" | "Menu bar" | "Windows" | "Onboarding" | "Eye tracker";
export const AREAS: Area[] = ["Voice", "Gaze", "Guide", "Agents", "Proactive", "Menu bar", "Windows", "Onboarding", "Eye tracker"];

export type Scheme = "light" | "dark";
export type Severity = "P0" | "P1" | "P2" | "P3";
export const SEVERITIES: Severity[] = ["P0", "P1", "P2", "P3"];

export type Variant = {
  scheme: Scheme;
  reduceMotion: boolean;
  image: string;
  width: number;
  height: number;
  scale: number;
  backdrop?: "transparent" | "desktop" | "window";
  thumb?: string;
};

export type Clip = {
  scheme: Scheme;
  reduceMotion: boolean;
  video: string;
  poster: string;
  width: number;
  height: number;
  durationMs: number;
  caption?: string;
};

export type State = {
  id: string;
  title: string;
  note?: string;
  kind?: "current" | "proposed" | "reference";
  variants: Variant[];
  clips?: Clip[];
};

export type Component = {
  id: string;
  title: string;
  area: Area;
  summary: string;
  sources: string[];
  owner?: string;
  producer?: string;
  states: State[];
};

export type SceneVariant = {
  scheme: Scheme;
  image: string;
  width: number;
  height: number;
  thumb?: string;
  clip?: Clip;
};

export type Scene = {
  id: string;
  title: string;
  summary: string;
  components: string[];
  image: string;
  width: number;
  height: number;
  thumb?: string;
  clip?: Clip;
  kind?: "current" | "proposed";
  variants?: SceneVariant[];
};

export type Finding = {
  id: string;
  component: string;
  severity: Severity;
  title: string;
  where: string;
  problem: string;
  fix: string;
  library?: string;
  skills: string[];
  proposedState?: string;
};

export type Gallery = {
  generatedAt: string;
  producers: { producer: string; commit: string; generatedAt: string }[];
  skills: string[];
  findingsGeneratedAt: string | null;
  components: Component[];
  scenes: Scene[];
  findings: Finding[];
};
