#!/usr/bin/env node
/**
 * Scoring helpers and --self-test fixtures for verify-context.sh.
 * Reads a JSON report on stdin or --fixture path; prints score table JSON on stdout.
 *
 * Fixture shape: { checks: [{ id, group, weight, pass, evidence, skip? }], hubIntegrationMerged? }
 */
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const selfTest = args.includes('--self-test');
const fixtureIdx = args.indexOf('--fixture');
const fixturePath = fixtureIdx >= 0 ? args[fixtureIdx + 1] : null;

function score(report) {
  const checks = report.checks || [];
  let earned = 0;
  let possible = 0;
  let groupBFail = false;
  const rows = [];
  for (const c of checks) {
    if (c.skip) {
      rows.push({ ...c, status: 'SKIP', points: 0 });
      continue;
    }
    possible += c.weight;
    const ok = Boolean(c.pass);
    if (c.group === 'B' && !ok) groupBFail = true;
    if (ok) earned += c.weight;
    rows.push({ ...c, status: ok ? 'PASS' : 'FAIL', points: ok ? c.weight : 0 });
  }
  const total = earned;
  const verdict = !groupBFail && total >= 90 ? 'PASS' : 'FAIL';
  return { rows, earned: total, possible, groupBFail, verdict };
}

function brokenFixtures() {
  return {
    leak: {
      checks: [
        { id: 'B.canary', group: 'B', weight: 8, pass: false, evidence: 'CANARY-B-7f3a found in packet' },
        { id: 'A.sections', group: 'A', weight: 5, pass: true, evidence: 'sections ok' },
      ],
    },
    overBudget: {
      checks: [
        { id: 'C.budget', group: 'C', weight: 5, pass: false, evidence: 'tokens 9000 > budget 100' },
        { id: 'B.canary', group: 'B', weight: 8, pass: true, evidence: 'no foreign canary' },
      ],
    },
    missingGap: {
      checks: [
        { id: 'D.gap', group: 'D', weight: 3, pass: false, evidence: 'expected no_analytics_for_campaign' },
        { id: 'B.canary', group: 'B', weight: 8, pass: true, evidence: 'no foreign canary' },
      ],
    },
  };
}

if (selfTest) {
  const fixtures = brokenFixtures();
  const results = {};
  for (const [name, report] of Object.entries(fixtures)) {
    const s = score(report);
    results[name] = s.verdict;
    if (name === 'leak' && s.verdict !== 'FAIL') {
      console.error('self-test leak fixture must FAIL');
      process.exit(1);
    }
    if (name === 'overBudget' && s.verdict !== 'FAIL') {
      console.error('self-test overBudget fixture must FAIL');
      process.exit(1);
    }
    if (name === 'missingGap' && s.verdict !== 'FAIL') {
      console.error('self-test missingGap fixture must FAIL');
      process.exit(1);
    }
  }
  console.log(JSON.stringify({ ok: true, results }, null, 2));
  process.exit(0);
}

let report;
if (fixturePath) {
  report = JSON.parse(readFileSync(fixturePath, 'utf8'));
} else {
  report = JSON.parse(readFileSync(0, 'utf8'));
}
const s = score(report);
console.log(JSON.stringify(s, null, 2));
process.exit(s.verdict === 'PASS' ? 0 : 1);
