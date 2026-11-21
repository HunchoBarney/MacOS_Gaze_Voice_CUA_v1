import type { CSSProperties, ReactNode } from "react";
import type { Scheme } from "../types";
import { Img } from "./Img";

export type Zoom = "fit" | "1x" | "2x";
export const ZOOMS: Zoom[] = ["fit", "1x", "2x"];

export type Picture = {
  image: string;
  width: number;
  height: number;
  scale: number;
  backdrop?: "transparent" | "desktop" | "window";
};

export function pictureWidth(picture: Pick<Picture, "width" | "height" | "scale">, zoom: Zoom): CSSProperties {
  const css = picture.width / picture.scale;
  if (zoom === "1x") return { width: css + "px" };
  if (zoom === "2x") return { width: css * 2 + "px" };
  if (picture.height / picture.width > 1.2) return { width: "min(100%, " + css + "px)" };
  return { width: "min(100%, " + picture.width + "px, calc(var(--stage-max-h) * " + (picture.width / picture.height).toFixed(4) + "))" };
}

export function Stage({
  picture,
  alt,
  zoom,
  scheme,
  overlay,
}: {
  picture: Picture;
  alt: string;
  zoom: Zoom;
  scheme: Scheme;
  overlay?: ReactNode;
}) {
  return (
    <div className="stage" data-backdrop={picture.backdrop ?? "transparent"} data-scheme={scheme} data-zoom={zoom} data-lenis-prevent>
      <div className="stage-inner">
        <Img src={picture.image} width={picture.width} height={picture.height} alt={alt} eager style={pictureWidth(picture, zoom)} className="stage-img" />
      </div>
      {overlay}
    </div>
  );
}
