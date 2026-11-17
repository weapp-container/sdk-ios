#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync, createWriteStream, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeProject } from '../examples/consumer/make-project.mjs';
import { copyPack } from './native-input.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const compileOnly = args.includes('--compile-only');
if (compileOnly && args.includes('--simulator-only')) throw Error('Choose --compile-only or --simulator-only');
const option = (key, fallback) => { const i=args.indexOf(key); if(i<0)return fallback; if(!args[i+1] || args[i+1].startsWith('--'))throw Error(`${key} needs a value`); return args[i+1]; };
const distribution = resolve(option('--distribution', resolve(root, 'artifacts/ios/WeappContainer')));
const rotationMode = option('--rotation', 'device');
if (!['device', 'scene'].includes(rotationMode)) throw Error('--rotation must be device or scene');
const id = randomBytes(5).toString('hex');
const out = resolve(option('--out', resolve(root, 'artifacts/ios/validation', id)));
const workspace = resolve(out, 'independent-consumer');
const bundle = `org.weappcontainer.sdkconsumer.${id}`;
let simulator, active;
let installed = false;
const receipt = {schemaVersion:1,status:'running',distribution,bundle,rotationMode,startedAt:new Date().toISOString(),checks:[],resources:[],cleanup:[]};
mkdirSync(workspace,{recursive:true});
const save=()=>writeFileSync(resolve(out,'validation.json'),JSON.stringify(receipt,null,2)+'\n');
async function run(command, argv, name, allowFailure=false) {
  const log = createWriteStream(resolve(out, `${name}.log`));
  let output='';
  const child=spawn(command,argv,{cwd:workspace,stdio:['ignore','pipe','pipe']}); active=child;
  child.stdout.on('data',b=>{output+=b;log.write(b);}); child.stderr.on('data',b=>{output+=b;log.write(b);});
  let timeout;
  const status=await new Promise((done,reject)=>{
    timeout=setTimeout(()=>{child.kill('SIGTERM');},name==='ui-test'?180_000:600_000);
    child.on('error',reject);child.on('close',c=>done(c??1));
  });
  clearTimeout(timeout); active=undefined; log.end();
  if(status!==0 && !allowFailure)throw Error(`${name} failed (${status}); see ${name}.log\n${output.slice(-5000)}`);
  return {status,output};
}
let interrupted=false;
for(const sig of ['SIGINT','SIGTERM'])process.on(sig,()=>{interrupted=true;active?.kill('SIGTERM');});
try {
  const build=JSON.parse(readFileSync(resolve(distribution,'build.json')));
  if(build.status!=='built')throw Error('Distribution receipt is not built');
  receipt.distributionBuild={sourceCommit:build.sourceCommit,profile:build.profile,artifactManifestSha256:createHash('sha256').update(JSON.stringify(build.artifacts)).digest('hex')};
  for(const item of build.artifacts){const bytes=readFileSync(resolve(distribution,item.file));if(createHash('sha256').update(bytes).digest('hex')!==item.sha256)throw Error(`Distribution hash mismatch: ${item.file}`);}
  cpSync(distribution,resolve(workspace,'WeappContainer'),{recursive:true});
  cpSync(resolve(root,'examples/consumer/Sources/Consumer.swift'),resolve(workspace,'Consumer.swift'));
  writeFileSync(resolve(workspace,'ConsumerUITests.swift'),readFileSync(resolve(root,'examples/consumer/Sources/ConsumerUITests.swift'),'utf8').replaceAll('__SDK_BUNDLE_ID__',bundle).replaceAll('__SDK_ROTATION_MODE__',rotationMode));
  receipt.packIntegrity=copyPack(option('--pack'),resolve(workspace,'portable-pack'));
  const project=makeProject(workspace,bundle);
  if(readdirSync(workspace).some(n=>n==='crates'||n==='Cargo.toml'))throw Error('Consumer unexpectedly includes repository sources');
  if (!compileOnly) {
    const list=JSON.parse((await run('xcrun',['simctl','list','devices','booted','--json'],'simulators')).output);
    simulator=option('--simulator');
    if(!Object.values(list.devices).flat().some(d=>d.udid===simulator&&d.isAvailable&&d.state==='Booted'))throw Error('--simulator must explicitly select an already booted simulator');
    if(!simulator)throw Error('A booted iOS simulator is required; this script does not create or shut down simulators');
    receipt.resources.push({kind:'simulator',id:simulator,created:false,action:'borrowed'});
    save();
  }
  const common=['-project',project,'-scheme','SDKConsumer','-configuration','Debug'];
  const builds=args.includes('--simulator-only')?[]:[
    ['device-arm64',['-sdk','iphoneos','-destination','generic/platform=iOS','ARCHS=arm64']],
    ['simulator-x86_64',['-sdk','iphonesimulator','-destination','generic/platform=iOS Simulator','ARCHS=x86_64','ONLY_ACTIVE_ARCH=NO','EXCLUDED_ARCHS=']]
  ];
  for(const [name,options] of builds){
    if(interrupted)throw Error('Interrupted');
    await run('xcodebuild',[...common,...options,'-derivedDataPath',resolve(out,name),'CODE_SIGNING_ALLOWED=NO','build'],name);
    receipt.checks.push({name,status:'passed',evidence:'compile-and-link-only'});save();
  }
  if (!compileOnly) {
    const derived=resolve(out,'simulator-arm64');
    const simArgs=[...common,'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','-sdk','iphonesimulator','-destination',`platform=iOS Simulator,id=${simulator}`,'-derivedDataPath',derived];
    await run('xcodebuild',[...simArgs,'build'],'simulator-arm64');
    const app=resolve(derived,'Build/Products/Debug-iphonesimulator/SDKConsumer.app');
    const digest=file=>createHash('sha256').update(readFileSync(file)).digest('hex');
    receipt.application={executableSha256:digest(resolve(app,'SDKConsumer')),consumerSourceSha256:digest(resolve(workspace,'Consumer.swift')),uiTestSourceSha256:digest(resolve(workspace,'ConsumerUITests.swift'))};
    await run('xcrun',['simctl','install',simulator,app],'install');installed=true;
    receipt.resources.push({kind:'application',id:bundle,created:true},{kind:'test-runner',id:`${bundle}.tests.xctrunner`,created:true});save();
    await run('xcodebuild',[...simArgs,'-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-enablePerformanceTestsDiagnostics','NO','-maximum-concurrent-test-simulator-destinations','1','-resultBundlePath',resolve(out,'Consumer.xcresult'),'test'],'ui-test');
    const tests=JSON.parse((await run('xcrun',['xcresulttool','get','test-results','summary','--path',resolve(out,'Consumer.xcresult')],'test-summary')).output);
    if(tests.passedTests!==1||tests.failedTests!==0||tests.skippedTests!==0)throw Error('The native XCTest must execute exactly once without skips or failures');
    receipt.executedTests={passed:tests.passedTests,failed:tests.failedTests,skipped:tests.skippedTests};
    const container=(await run('xcrun',['simctl','get_app_container',simulator,bundle,'data'],'container')).output.trim();
    cpSync(resolve(container,'Documents/result.json'),resolve(out,'consumer-result.json'));
    const result=JSON.parse(readFileSync(resolve(out,'consumer-result.json')));
    if(result.failure||!result.unmeasuredObservationRejected||!result.reopened||!result.durableClose||result.initial?.stored!==1||!result.failedLoadPreservedGeneration||!result.hiddenCompletionWhileAttached||!result.hiddenPresentationStopped||!result.hostPausePreserved||!result.hostPausePresentationStopped||!result.pairClosed||result.secondTap?.count!==2||!(result.scroll?.scrollTop>0)||result.currentRoute!=='pages/home/index')throw Error('Consumer result contract failed');
    if(!result.nested||!(result.scroll?.scrollTop>30)||Math.abs(result.parentOffset??0)>=1||result.tap?.count!==2)throw Error('Native parent/embedded scrolling or multi-touch recovery contract failed');
    receipt.checks.push({name:'simulator-arm64',status:'passed',evidence:`xctest-dual-instances-os-touch-scroll-navigation-background-${rotationMode}-rotation-and-completed-metal-frames`,result:'consumer-result.json',xcresult:'Consumer.xcresult'});
    receipt.windowMetricsAcceptance={witness:'independent-UIKit-window-insets-to-fixed-screen-coordinate-space',snapshots:['initial','secondInitial','geometry','both-landscape-stable-snapshots','portrait-restoration','persistent-reopen','nested-geometry'],resizeAcceptance:'viewport-callback-plus-current-snapshot-after-scene-settles',unmeasuredPreflight:'no-owner-and-cancellation',result:'consumer-result.json',limitations:['external-display','interactive-multiwindow','status-bar-less-scene','upside-down-device','physical-device']};
  }
  receipt.status='passed';
} catch(error){receipt.status='failed';receipt.error=error.message;process.exitCode=1;console.error(error.message);}
finally {
  if(existsSync(resolve(out,'Consumer.xcresult'))){
    const exported=await run('xcrun',['xcresulttool','export','attachments','--path',resolve(out,'Consumer.xcresult'),'--output-path',resolve(out,'screenshots')],'export-attachments',true);
    receipt.attachmentExport=exported.status===0?'screenshots':'failed';
  }
  if(simulator&&installed){
    // Preserve the final native observation even when XCTest fails, before the
    // owned app's data container is removed during cleanup.
    if(!existsSync(resolve(out,'consumer-result.json'))){
      const container=await run('xcrun',['simctl','get_app_container',simulator,bundle,'data'],'failure-container',true);
      const result=resolve(container.output.trim(),'Documents/result.json');
      if(container.status===0&&existsSync(result)){
        cpSync(result,resolve(out,'last-consumer-result.json'));
        receipt.lastConsumerResult='last-consumer-result.json';
      }
    }
    for(const app of [`${bundle}.tests.xctrunner`,bundle]){
      const present=await run('xcrun',['simctl','get_app_container',simulator,app,'app'],`cleanup-probe-${app}`,true);
      if(present.status!==0){receipt.cleanup.push({application:app,status:'not-installed'});continue;}
      await run('xcrun',['simctl','terminate',simulator,app],`cleanup-terminate-${app}`,true);
      const removed=await run('xcrun',['simctl','uninstall',simulator,app],`cleanup-uninstall-${app}`,true);
      const probe=await run('xcrun',['simctl','get_app_container',simulator,app,'app'],`cleanup-verify-${app}`,true);
      const ok=removed.status===0&&probe.status!==0;
      receipt.cleanup.push({application:app,status:ok?'removed-and-verified':'failed'});
      if(!ok){receipt.status='failed';receipt.cleanupError=`Could not remove owned application ${app}`;process.exitCode=1;}
    }
  }
  receipt.finishedAt=new Date().toISOString();save();
  console.log(JSON.stringify({status:receipt.status,receipt:resolve(out,'validation.json'),error:receipt.error},null,2));
}
