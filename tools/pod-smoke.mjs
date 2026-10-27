#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeProject } from '../examples/consumer/make-project.mjs';
import { copyPack } from './native-input.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2);
const option=(k,d)=>{const i=args.indexOf(k);if(i<0)return d;if(!args[i+1]||args[i+1].startsWith('--'))throw Error(`${k} needs a value`);return args[i+1];};
const distribution=resolve(option('--distribution',resolve(root,'artifacts/ios/WeappContainer')));
const out=resolve(option('--out',resolve(root,'artifacts/ios/pod-validation')));
const workspace=resolve(out,'independent-consumer');mkdirSync(workspace,{recursive:true});
const receipt={schemaVersion:1,status:'running',distribution,startedAt:new Date().toISOString(),checks:[]};
function run(command,argv,name){const r=spawnSync(command,argv,{cwd:workspace,encoding:'utf8',maxBuffer:64*1024*1024});writeFileSync(resolve(out,name+'.log'),(r.stdout||'')+(r.stderr||''));if(r.error||r.status!==0)throw Error(`${name} failed: ${r.error?.message||r.status}; see ${name}.log\n${r.stderr?.slice(-2500)||r.stdout?.slice(-2500)}`);}
try{
 const manifest=JSON.parse(readFileSync(resolve(distribution,'build.json')));if(manifest.status!=='built')throw Error('Distribution is not built');
 receipt.distributionBuild={sourceCommit:manifest.sourceCommit,profile:manifest.profile,artifactManifestSha256:createHash('sha256').update(JSON.stringify(manifest.artifacts)).digest('hex')};
 for(const a of manifest.artifacts)if(createHash('sha256').update(readFileSync(resolve(distribution,a.file))).digest('hex')!==a.sha256)throw Error(`Hash mismatch: ${a.file}`);
 cpSync(distribution,resolve(workspace,'WeappContainer'),{recursive:true});
 for(const f of ['Consumer.swift','ConsumerUITests.swift'])cpSync(resolve(root,'examples/consumer/Sources',f),resolve(workspace,f));
 copyPack(option('--pack'),resolve(workspace,'portable-pack'));
 makeProject(workspace,`org.weappcontainer.podconsumer.${randomBytes(4).toString('hex')}`,{cocoapods:true});
 writeFileSync(resolve(workspace,'Podfile'),"platform :ios, '16.0'\nuse_frameworks! :linkage => :static\nproject 'SDKConsumer.xcodeproj'\ntarget 'SDKConsumer' do\n  pod 'WeappContainer', :path => './WeappContainer'\nend\n");
 run('pod',['install','--no-repo-update'],'pod-install');
 run('xcodebuild',['-workspace','SDKConsumer.xcworkspace','-scheme','SDKConsumer','-configuration','Debug','-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','-derivedDataPath',resolve(out,'build'),'build'],'pod-build');
 receipt.status='passed';receipt.checks.push({name:'cocoapods-independent-consumer',status:'passed',evidence:'arm64-simulator-compile-and-link-only'});
}catch(error){receipt.status='failed';receipt.error=error.message;process.exitCode=1;console.error(error.message);}
receipt.finishedAt=new Date().toISOString();writeFileSync(resolve(out,'validation.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({status:receipt.status,receipt:resolve(out,'validation.json')},null,2));
