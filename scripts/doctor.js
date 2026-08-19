#!/usr/bin/env node
'use strict';

const { runDoctor } = require('./doctor-lib');

const args = new Set(process.argv.slice(2));
const json = args.has('--json');
const strict = args.has('--strict');
const noNetwork = args.has('--no-network');

const icons = { pass: '✓', warn: '!', error: '✗' };

async function main() {
  const report = await runDoctor({ skipNetwork: noNetwork });
  if (json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log('');
    console.log(`  serein doctor ${report.version}  ${report.platform}`);
    console.log('');
    for (const check of report.checks) {
      console.log(`  ${icons[check.status]} ${check.message}`);
      if (check.detail) console.log(`    ${check.detail}`);
    }
    console.log('');
    console.log(`  结果：${report.summary.pass} 通过，${report.summary.warn} 提醒，${report.summary.error} 错误`);
    if (report.summary.error) console.log('  修复错误后重新运行：serein doctor');
    console.log('');
  }

  if (report.summary.error > 0) process.exitCode = 1;
  else if (strict && report.summary.warn > 0) process.exitCode = 2;
}

main().catch(error => {
  console.error('[serein doctor] 诊断失败:', error.message || error);
  process.exitCode = 1;
});
