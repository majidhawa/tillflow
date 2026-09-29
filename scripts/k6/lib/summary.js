// Shared handleSummary() for the G3 capacity-test profiles. Writes the
// full, machine-readable k6 summary as JSON to evidence/reliability/
// (committable after a real run, per the G3 evidence requirement — "not
// screenshots alone"), and prints a short human-readable recap to stdout.
// Deliberately dependency-free: no external jslib.k6.io import, to match
// the rest of this project's k6 scripts.

export function summaryHandler(profileName) {
  return function (data) {
    const path = `evidence/reliability/k6-${profileName}-summary.json`;
    const m = data.metrics || {};

    const val = (metric, stat) => {
      const v = m[metric] && m[metric].values;
      return v && stat in v ? v[stat] : null;
    };

    const fmtMs = (n) => (typeof n === 'number' ? n.toFixed(2) + 'ms' : 'n/a');
    const fmtPct = (n) => (typeof n === 'number' ? (n * 100).toFixed(3) + '%' : 'n/a');

    const recap = [
      '',
      `=== ${profileName} summary ===`,
      `requests:      ${val('http_reqs', 'count') ?? 'n/a'}`,
      `failed rate:   ${fmtPct(val('http_req_failed', 'rate'))}`,
      `p95 duration:  ${fmtMs(val('http_req_duration', 'p(95)'))}`,
      `checks passed: ${fmtPct(val('checks', 'rate'))}`,
      `full summary:  ${path}`,
      '',
    ].join('\n');

    const result = { stdout: recap };
    result[path] = JSON.stringify(data, null, 2);
    return result;
  };
}
