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
  superseded?: string;
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
  superseded?: string;
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
  redesign?: Redesign;
};

export type MediaKey = "dark" | "light" | "dark-rm" | "light-rm";
export type Media = { kind: "clip" | "still"; src: string; poster?: string; width: number; height: number; fps?: number; duration?: number };
export type MediaSet = Partial<Record<MediaKey, Media>>;
export type Library = { name: string; version: string; license: string; url: string; role: string };
export type DirectionId = "A" | "B" | "C";
export type RedesignState = { id: string; title: string; caption?: string; media: MediaSet };

export type Direction = {
  id: DirectionId;
  name: string;
  axis: string;
  pitch: string;
  cost: string;
  libraries: Library[];
  custom?: string;
  skills: { skill: string; change: string }[];
  perf?: { cpu: string; gpu: string; idle: string; note: string };
  alwaysOn?: boolean;
  states: RedesignState[];
  flow?: MediaSet;
};

export type RedesignComponent = {
  id: string;
  batch: 1 | 2 | 3;
  title: string;
  summary: string;
  current: { componentIds: string[]; note?: string };
  directions: Direction[];
};

export type RedesignScene = { id: string; title: string; caption: string; picks: Record<string, string>; media: MediaSet };

export type Redesign = {
  generatedAt: string;
  producers: { producer: string; commit: string; generatedAt: string }[];
  components: RedesignComponent[];
  scenes: RedesignScene[];
};
