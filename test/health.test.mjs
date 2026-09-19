import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

let child,base,dir;

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-health-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('health endpoint reports ok, version, and phase',async()=>{
  const res=await fetch(base+'/api/health');
  assert.equal(res.status,200);
  const body=await res.json();
  assert.equal(body.ok,true);
  assert.equal(body.version,'0.32.0');
  assert.equal(body.phase,'Phase 1 Free World Movement');
});
