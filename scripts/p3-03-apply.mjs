import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';

const serverPath='server.mjs';
let server=readFileSync(serverPath,'utf8');
const oldSeed="db.prepare(`INSERT OR IGNORE INTO characters(id,account_id,city_id,state,wallet,cargo_capacity,world_x,world_y) VALUES('char-demo','account-demo','starter-village','IN_CITY',1000,20,?,?)`).run(startCity.coordinates.x,startCity.coordinates.y);";
const newSeed="db.prepare(`INSERT OR IGNORE INTO characters(id,account_id,city_id,state,wallet,cargo_capacity,world_x,world_y) VALUES('char-demo','account-demo','starter-village','IN_CITY',1000,60,?,?)`).run(startCity.coordinates.x,startCity.coordinates.y);\n  // P3-03 Prototype migration: only the legacy prototype default (20) is lifted to 60.\n  // Preserve every other character field and never lower/custom-overwrite a different capacity.\n  db.prepare(`UPDATE characters SET cargo_capacity=60 WHERE id='char-demo' AND cargo_capacity=20`).run();";
if(!server.includes(oldSeed))throw new Error('expected P3-03 seed target not found');
server=server.replace(oldSeed,newSeed);
writeFileSync(serverPath,server);

mkdirSync('test',{recursive:true});
writeFileSync('test/cargo-capacity-60.test.mjs',`import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';

async function startServer(dbPath){
  const child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(\`server exited \${code}\`)))});
  const base='http://127.0.0.1:'+line.match(/:(\\d+)/)[1];
  return {child,base};
}
const stop=child=>new Promise(resolve=>{child.once('exit',resolve);child.kill()});

test('P3-03 fresh save starts with Cargo Capacity 60',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'myrial-p3-03-fresh-'));const dbPath=join(dir,'test.sqlite');
  const {child,base}=await startServer(dbPath);
  try{const snap=await fetch(base+'/api/character/char-demo/snapshot').then(r=>r.json());assert.equal(snap.cargo.capacityUnits,60)}finally{await stop(child);await rm(dir,{recursive:true,force:true})}
});

test('P3-03 existing legacy 20-capacity save migrates to 60 without resetting progression',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'myrial-p3-03-migrate-'));const dbPath=join(dir,'test.sqlite');
  let running=await startServer(dbPath);await stop(running.child);
  const db=new DatabaseSync(dbPath);
  db.prepare(\`UPDATE characters SET cargo_capacity=20,wallet=4321,city_id='harbour-city',state='IN_CITY',world_x=780,world_y=780 WHERE id='char-demo'\`).run();
  db.prepare(\`INSERT OR REPLACE INTO cargo(character_id,good_id,quantity,cargo_units) VALUES('char-demo','tea',3,1)\`).run();
  db.close();
  running=await startServer(dbPath);
  try{
    const snap=await fetch(running.base+'/api/character/char-demo/snapshot').then(r=>r.json());
    assert.equal(snap.cargo.capacityUnits,60);assert.equal(snap.walletGold,4321);assert.equal(snap.cityId,'harbour-city');assert.equal(snap.state,'IN_CITY');
    assert.deepEqual(snap.worldPosition,{x:780,y:780});assert.equal(snap.cargo.stacks.find(x=>x.goodTypeId==='tea')?.quantity,3);
  }finally{await stop(running.child);await rm(dir,{recursive:true,force:true})}
});

test('P3-03 migration does not overwrite a non-legacy custom capacity',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'myrial-p3-03-custom-'));const dbPath=join(dir,'test.sqlite');
  let running=await startServer(dbPath);await stop(running.child);
  const db=new DatabaseSync(dbPath);db.prepare(\`UPDATE characters SET cargo_capacity=80 WHERE id='char-demo'\`).run();db.close();
  running=await startServer(dbPath);
  try{const snap=await fetch(running.base+'/api/character/char-demo/snapshot').then(r=>r.json());assert.equal(snap.cargo.capacityUnits,80)}finally{await stop(running.child);await rm(dir,{recursive:true,force:true})}
});
`);
