import { useState, type CSSProperties } from "react";
import { asset } from "../data";

export function Img({
  src,
  width,
  height,
  alt,
  eager = false,
  className,
  style,
}: {
  src: string;
  width: number;
  height: number;
  alt: string;
  eager?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  const [failedSrc, setFailedSrc] = useState<string>();
  if (failedSrc === src)
    return (
      <span
        className={"img-missing " + (className ?? "")}
        style={{ aspectRatio: width + " / " + height, ...style }}
        role="img"
        aria-label={alt + " (render missing)"}
      >
        Render missing
      </span>
    );
  return (
    <img
      className={className}
      style={style}
      src={asset(src)}
      width={width}
      height={height}
      alt={alt}
      loading={eager ? "eager" : "lazy"}
      decoding="async"
      draggable={false}
      onError={() => setFailedSrc(src)}
    />
  );
}
