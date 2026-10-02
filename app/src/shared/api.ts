// The HTTP contract between the Car Thing app and TV Thing's Bridgething extension.
// The extension serves on the computer's loopback; the Car Thing reaches it through
// Bridgething's net.fetch, and Bridgething's host player loads the same URLs for audio.

import type { PlaybackMode, SourceReference } from './library';

export const EXTENSION_PORT = 17839;
export const EXTENSION_ORIGIN = `http://127.0.0.1:${EXTENSION_PORT}`;
export const API_VERSION = 2;

export interface SessionRequest {
  source: SourceReference;
  playback?: PlaybackMode;
}

export interface SessionReply {
  /** Changes on every tune. */
  id: string;
  /** Root-relative path of the playlist both the Car Thing and the host player load. */
  playlist: string;
}

export interface Health {
  app: 'TV Thing';
  version: string;
  api: number;
  ffmpeg: boolean;
}

export interface LogRequest {
  message: string;
}

/** `GET /api/v1/sessions/<id>/host` (`DELETE` forgets it, before the host player reloads). */
export interface HostTimeline {
  /** Program-date-time (Unix ms) where the host player's position counts from, once known. */
  origin: number | null;
}
