import { isTall } from "../data";
import type { Scheme } from "../types";
import { Img } from "./Img";

export function Thumb({
  picture,
  scheme,
  backdrop,
  cover = false,
}: {
  picture: { image: string; thumb?: string; width: number; height: number; scale?: number } | undefined;
  scheme: Scheme;
  backdrop?: string;
  cover?: boolean;
}) {
  const tall = picture ? isTall(picture) : false;
  return (
    <span className={"thumb" + (cover ? " thumb-scene" : "")} data-backdrop={backdrop ?? "transparent"} data-scheme={scheme} data-tall={tall || undefined}>
      {picture && (
        <Img
          src={picture.thumb ?? picture.image}
          width={picture.width}
          height={picture.height}
          alt=""
          style={cover ? undefined : { width: picture.width / (picture.scale ?? 2) }}
        />
      )}
    </span>
  );
}
