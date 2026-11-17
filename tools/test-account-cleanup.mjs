#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const temporary=mkdtempSync(resolve(tmpdir(),'weapp-account-cleanup-'));
try {
  const executable=resolve(temporary,'account-cleanup-tests');
  for(const [command,args] of [
    ['swiftc',[resolve(root,'Sources/WeappContainer/AccountCleanupQueue.swift'),resolve(root,'test/AccountCleanupQueueTests.swift'),'-o',executable]],
    [executable,[]],
  ]) {
    const result=spawnSync(command,args,{stdio:'inherit'});
    if(result.error||result.status!==0)throw new Error(`${command} failed: ${result.error?.message??result.status}`);
  }
} finally {rmSync(temporary,{recursive:true,force:true});}
