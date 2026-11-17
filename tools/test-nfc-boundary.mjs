#!/usr/bin/env node
import {spawnSync} from 'node:child_process'
import {mkdtempSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'
const root=fileURLToPath(new URL('../',import.meta.url)),temporary=mkdtempSync(resolve(tmpdir(),'weapp-nfc-boundary-'))
try {
  const executable=resolve(temporary,'nfc-boundary-tests')
  for(const [command,args] of [
    ['swiftc',[resolve(root,'Sources/WeappContainer/Types.swift'),resolve(root,'Sources/WeappContainer/NfcNativeBoundary.swift'),resolve(root,'test/NfcNativeBoundaryTests.swift'),'-o',executable]],
    [executable,[]],
  ]) {
    const result=spawnSync(command,args,{stdio:'inherit'})
    if(result.error||result.status!==0)throw new Error(`${command} failed: ${result.error?.message||result.status}`)
  }
} finally {rmSync(temporary,{recursive:true,force:true})}
