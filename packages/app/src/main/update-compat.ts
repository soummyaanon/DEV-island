/**
 * Whether this Mac can run a release. 2.0 is a native app that needs macOS 14;
 * 1.x runs on 11 and up. Without this, 1.x's updater would offer 2.0 on an
 * older Mac and swap in an app that can't open.
 */

/** The oldest macOS (major version) each release line needs. */
const MINIMUM_MACOS: Array<{ fromMajor: number; macos: number }> = [{ fromMajor: 2, macos: 14 }];

/** `release` like "v2.0.0"; `macos` like "13.6.1" (process.getSystemVersion()). */
export function runsOnThisMac(release: string, macos: string): boolean {
  const major = Number.parseInt(release.replace(/^v/i, ""), 10) || 0;
  const macMajor = Number.parseInt(macos, 10) || 0;
  const need = MINIMUM_MACOS.filter((rule) => major >= rule.fromMajor).reduce((most, rule) => Math.max(most, rule.macos), 0);
  // An unreadable macOS version never blocks an update.
  return macMajor === 0 || macMajor >= need;
}
