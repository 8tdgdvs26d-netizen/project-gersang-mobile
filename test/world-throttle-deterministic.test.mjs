import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {DatabaseSync} from 'node:sqlite';

// Test-only controlled clock: server gameplay code and the 120ms throttle constant stay untouched.
const requestJson=async(base,path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};

test('world/move minimum interval throttles a back-to-back command deterministically and makes zero extra DB write',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'myrial-world-throttle-deterministic-'));
  const dbPath=join(dir,'test.sqlite');
  const preload=fileURLToPath(new URL('./fake-clock-preload.mjs',import.meta.url));
  const child=spawn(process.execPath,['--import',preload,'server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});
  try{
    const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
    const base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
    const post=(path,body)=>requestJson(base,path,{method:'POST',body:JSON.stringify(body)});
    const sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
    const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
    const fixture=new DatabaseSync(dbPath);
    fixture.prepare(`UPDATE characters SET world_x=50,world_y=50,state='IN_WORLD' WHERE id='char-demo'`).run();
    fixture.close();

    const first=await post('/api/commands/world/move',envelope('det-throttle-first',{targetX:90,targetY:50}));
    assert.equal(first.status,'ACCEPTED');
    assert.equal(first.data.throttled,false);
    assert.deepEqual(first.data.worldPosition,{x:90,y:50});

    const beforeSecond=new DatabaseSync(dbPath);
    const rowAfterFirst=beforeSecond.prepare(`SELECT world_x,world_y,state FROM characters WHERE id='char-demo'`).get();
    beforeSecond.close();

    const second=await post('/api/commands/world/move',envelope('det-throttle-second',{targetX:900,targetY:900}));
    assert.equal(second.status,'ACCEPTED');
    assert.equal(second.data.throttled,true);
    assert.deepEqual(second.data.worldPosition,first.data.worldPosition);

    const afterSecond=new DatabaseSync(dbPath);
    const rowAfterSecond=afterSecond.prepare(`SELECT world_x,world_y,state FROM characters WHERE id='char-demo'`).get();
    afterSecond.close();
    assert.deepEqual(rowAfterSecond,rowAfterFirst,'throttled command must make zero additional characters-row write');
  }finally{
    child.kill();
    await new Promise(resolve=>child.once('exit',resolve));
    await rm(dir,{recursive:true,force:true});
  }
});
