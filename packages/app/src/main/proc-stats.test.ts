import { describe, expect, it } from "vitest";
import { parsePs, subtreeTotals } from "./proc-stats";

const PS = `  PID  PPID  %CPU    RSS
    1     0   0.2  24624
  100     1  12.5 204800
  101   100  50.0 102400
  102   101   0.5   1024
  200     1   3.0  51200
garbage line
`;

describe("parsePs", () => {
  it("skips the header and junk, parses the rest", () => {
    const rows = parsePs(PS);
    expect(rows).toHaveLength(5);
    expect(rows[1]).toEqual({ pid: 100, ppid: 1, cpu: 12.5, rssKb: 204800 });
  });
});

describe("subtreeTotals", () => {
  it("sums the root and every descendant", () => {
    expect(subtreeTotals(parsePs(PS), 100)).toEqual({ cpu: 63, rssMb: 301, procs: 3 });
  });
  it("a leaf is just itself", () => {
    expect(subtreeTotals(parsePs(PS), 200)).toEqual({ cpu: 3, rssMb: 50, procs: 1 });
  });
  it("is null when the root no longer exists (PID reuse must not mislead)", () => {
    expect(subtreeTotals(parsePs(PS), 999)).toBeNull();
  });
  it("survives a parent cycle", () => {
    const rows = [
      { pid: 5, ppid: 6, cpu: 1, rssKb: 1024 },
      { pid: 6, ppid: 5, cpu: 1, rssKb: 1024 },
    ];
    expect(subtreeTotals(rows, 5)).toEqual({ cpu: 2, rssMb: 2, procs: 2 });
  });
});
