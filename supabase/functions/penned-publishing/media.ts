import { PublishingError } from "./contract.ts";

export function validateMedia(bytes: Uint8Array, mime: string): void {
  const prefix = new TextDecoder().decode(bytes.slice(0, 16));
  const matches = (signature: number[]) => signature.every((byte, index) => bytes[index] === byte);
  let valid = true;
  if (mime === "image/png") valid = matches([137, 80, 78, 71, 13, 10, 26, 10]);
  if (mime === "image/jpeg") valid = matches([255, 216, 255]);
  if (mime === "image/gif") valid = prefix.startsWith("GIF87a") || prefix.startsWith("GIF89a");
  if (mime === "image/webp") valid = prefix.startsWith("RIFF") && prefix.slice(8, 12) === "WEBP";
  if (mime === "application/pdf") valid = prefix.startsWith("%PDF-");
  if (["audio/wav", "audio/x-wav"].includes(mime)) valid = prefix.startsWith("RIFF") && prefix.slice(8, 12) === "WAVE";
  if (["audio/ogg", "video/ogg"].includes(mime)) valid = prefix.startsWith("OggS");
  if (mime === "video/webm") valid = matches([26, 69, 223, 163]);
  if (mime === "image/svg+xml") {
    let text: string;
    try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { throw new PublishingError(400, "media_type_mismatch"); }
    valid = /<svg[\s>]/i.test(text) && !/<!doctype|<!entity|<script|<foreignobject|\bon[a-z]+\s*=|javascript:|@import|(?:href\s*=\s*["']\s*(?!#)|url\s*\(\s*["']?(?!#))/i.test(text);
  }
  if (!valid) throw new PublishingError(400, "media_type_mismatch");
}
