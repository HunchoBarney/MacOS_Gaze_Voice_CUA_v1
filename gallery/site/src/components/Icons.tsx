import type { SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Icon({ size = 16, children, ...rest }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const SearchIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="7" cy="7" r="4.5" />
    <path d="M10.5 10.5 14 14" />
  </Icon>
);
export const SunIcon = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="8" cy="8" r="2.75" />
    <path d="M8 1.5v1.25M8 13.25v1.25M1.5 8h1.25M13.25 8h1.25M3.4 3.4l.9.9M11.7 11.7l.9.9M3.4 12.6l.9-.9M11.7 4.3l.9-.9" />
  </Icon>
);
export const MoonIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M13.5 9.6A5.75 5.75 0 0 1 6.4 2.5a5.75 5.75 0 1 0 7.1 7.1Z" />
  </Icon>
);
export const DisplayIcon = (p: IconProps) => (
  <Icon {...p}>
    <rect x="1.75" y="2.5" width="12.5" height="8.5" rx="1.75" />
    <path d="M5.5 13.75h5M8 11v2.75" />
  </Icon>
);
export const PlayIcon = (p: IconProps) => (
  <Icon {...p} fill="currentColor" stroke="none">
    <path d="M4.5 2.9c0-.6.66-.97 1.17-.65l7.6 4.66a.76.76 0 0 1 0 1.3l-7.6 4.66a.76.76 0 0 1-1.17-.65Z" />
  </Icon>
);
export const PauseIcon = (p: IconProps) => (
  <Icon {...p} fill="currentColor" stroke="none">
    <rect x="3.75" y="2.5" width="3" height="11" rx="1" />
    <rect x="9.25" y="2.5" width="3" height="11" rx="1" />
  </Icon>
);
export const LoopIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M2.5 8V7a3 3 0 0 1 3-3h8M11.5 2l2 2-2 2M13.5 8v1a3 3 0 0 1-3 3h-8M4.5 14l-2-2 2-2" />
  </Icon>
);
export const LinkIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6.75 9.25a2.75 2.75 0 0 0 3.9 0l2.1-2.1a2.75 2.75 0 0 0-3.9-3.9l-.6.6M9.25 6.75a2.75 2.75 0 0 0-3.9 0l-2.1 2.1a2.75 2.75 0 0 0 3.9 3.9l.6-.6" />
  </Icon>
);
export const ArrowUpRightIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5 11 11 5M6 5h5v5" />
  </Icon>
);
export const ChevronLeftIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="M10 3.5 5.5 8l4.5 4.5" />
  </Icon>
);
export const ChevronRightIcon = (p: IconProps) => (
  <Icon {...p}>
    <path d="m6 3.5 4.5 4.5L6 12.5" />
  </Icon>
);
export const Waveform = (p: IconProps) => (
  <Icon {...p}>
    <path d="M2.5 6.5v3M5 4.5v7M7.5 2.5v11M10 5v6M12.5 7v2" />
  </Icon>
);
