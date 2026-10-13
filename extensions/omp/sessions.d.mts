import type { SavedSession } from "../../packages/protocol/generated/SavedSession.ts";
export interface StoredSession extends SavedSession {
  path: string;
}
export function sessionsRoot(
  env?: Record<string, string | undefined>,
  home?: string,
  platform?: string,
): string;
export function readSavedSession(path: string): Promise<StoredSession | null>;
export function listSavedSessions(root?: string): Promise<StoredSession[]>;
