import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {MOVE_SPEED_RATE,MOVE_CATCHUP_CAP_MS} from '../public/movement.js';

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-movement-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('world/move rejects direct departure while IN_CITY, so the safe city-exit command cannot be bypassed',async()=>{
  const before=await request('/api/character/char-demo/snapshot');
  assert.equal(before.state,'IN_CITY');
  const moved=await post('/api/commands/world/move',envelope('move-legal-1',{targetX:before.worldPosition.x+40,targetY:before.worldPosition.y}));
  assert.equal(moved.errorCode,'ERR_INVALID_STATE');
  const after=await request('/api/character/char-demo/snapshot');
  assert.equal(after.state,'IN_CITY');
  assert.deepEqual(after.worldPosition,before.worldPosition);
});

test('IN_WORLD accepts further legal moves',async()=>{
  // P1-07D: wait comfortably past MOVE_CATCHUP_CAP_MS so the elapsed-time allowance is not the
  // limiting factor here — this test is about accepting further legal moves, not about the
  // allowance/clamp mechanics themselves (see the teleport-clamp test below for that).
  await wait(MOVE_CATCHUP_CAP_MS+100);
  setPosition(220,222,'IN_WORLD');
  const before=await request('/api/character/char-demo/snapshot');
  assert.equal(before.state,'IN_WORLD');
  const moved=await post('/api/commands/world/move',envelope('move-legal-2',{targetX:before.worldPosition.x,targetY:before.worldPosition.y+30}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.state,'IN_WORLD');
  assert.deepEqual(moved.data.worldPosition,{x:before.worldPosition.x,y:before.worldPosition.y+30});
});

// P1-07D — Latency-Decoupled Movement (Issue #23). Replaces the old flat MAX_WORLD_STEP=60 clamp
// assertion: a single command's displacement is now bounded by
// MOVE_SPEED_RATE * min(elapsedSinceLastNonThrottledAttempt, MOVE_CATCHUP_CAP_MS), not a flat
// constant — see server.mjs's moveWorld() for the full, accurate invariant (this bound is about a
// single command's maximum displacement only; it does not prove actual held duration or an average
// speed). The protection this test exists to prove — no one-shot teleport, regardless of how far the
// requested target is — is unchanged, just now expressed as a time-scaled ceiling instead of a flat
// one. Waits comfortably past MOVE_CATCHUP_CAP_MS so the allowance actually saturates at the hard
// ceiling (the most direct exercise of "never exceeds it"), and so this request is never throttled.
test("world/move clamps a single command's displacement to the elapsed-time allowance, never exceeding the bounded catch-up ceiling, regardless of how far the requested target is",async()=>{
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const before=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('move-teleport-attempt',{targetX:before.worldPosition.x+99999,targetY:before.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  const distance=Math.hypot(moved.data.worldPosition.x-before.worldPosition.x,moved.data.worldPosition.y-before.worldPosition.y);
  const maxPossible=MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS;
  assert.ok(distance<=maxPossible+0.0001,`expected displacement <= hard catch-up ceiling ${maxPossible}, got ${distance}`);
  assert.ok(distance>0);
});

test("world/move sent shortly after the previous one clamps to a small, elapsed-time-proportional displacement, not the full catch-up ceiling",async()=>{
  const before=await request('/api/character/char-demo/snapshot');
  // This command itself sets lastWorldMoveAt=now; the FOLLOWING command (after a short wait, still
  // comfortably above MOVEMENT_MIN_INTERVAL_MS=120 so it is not throttled) should only be granted a
  // small allowance proportional to that short elapsed gap, not the full MOVE_CATCHUP_CAP_MS ceiling.
  await post('/api/commands/world/move',envelope('move-shortwait-anchor',{targetX:before.worldPosition.x,targetY:before.worldPosition.y}));
  await wait(150);
  const afterAnchor=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('move-shortwait-attempt',{targetX:afterAnchor.worldPosition.x+99999,targetY:afterAnchor.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  const distance=Math.hypot(moved.data.worldPosition.x-afterAnchor.worldPosition.x,moved.data.worldPosition.y-afterAnchor.worldPosition.y);
  const maxPossible=MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS;
  assert.ok(distance<maxPossible-1,`expected a short-elapsed displacement well under the full ceiling ${maxPossible}, got ${distance}`);
  assert.ok(distance>0);
});

test('world/move clamps a target outside world bounds so the result stays within [0,1000]x[0,1000]',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET world_x=5,world_y=5,state='IN_WORLD' WHERE id='char-demo'`).run();
  fixture.close();
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('move-bounds-clamp',{targetX:-99999,targetY:-99999}));
  assert.equal(moved.status,'ACCEPTED');
  assert.ok(moved.data.worldPosition.x>=0,`x should clamp to >=0, got ${moved.data.worldPosition.x}`);
  assert.ok(moved.data.worldPosition.y>=0,`y should clamp to >=0, got ${moved.data.worldPosition.y}`);
  assert.equal(moved.data.worldPosition.x,0);
  assert.equal(moved.data.worldPosition.y,0);
});

test('a command sent sooner than the minimum movement interval produces no additional displacement',async()=>{
  await wait(150);
  const first=await post('/api/commands/world/move',envelope('move-throttle-a',{targetX:500,targetY:500}));
  assert.equal(first.status,'ACCEPTED');
  assert.equal(first.data.throttled,false);
  const second=await post('/api/commands/world/move',envelope('move-throttle-b',{targetX:900,targetY:900}));
  assert.equal(second.status,'ACCEPTED');
  assert.equal(second.data.throttled,true);
  assert.deepEqual(second.data.worldPosition,first.data.worldPosition);
});

test('world/move is rejected while TRAVELING, and leaves the stored position unchanged',async()=>{
  await wait(150);
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET state='IN_CITY' WHERE id='char-demo'`).run();
  fixture.close();
  const cities=await request('/api/cities');
  const before=await request('/api/character/char-demo/snapshot');
  const started=await post('/api/commands/travel/start',envelope('move-travel-block-start',{destinationCityId:cities.find(c=>c.id!==before.cityId).id}));
  assert.equal(started.status,'ACCEPTED');
  const beforeMove=await request('/api/character/char-demo/snapshot');
  assert.equal(beforeMove.state,'TRAVELING');
  const moved=await post('/api/commands/world/move',envelope('move-during-travel',{targetX:beforeMove.worldPosition.x+10,targetY:beforeMove.worldPosition.y}));
  assert.equal(moved.status,'REJECTED');
  assert.equal(moved.errorCode,'ERR_INVALID_STATE');
  const check=new DatabaseSync(join(dir,'test.sqlite'));
  const row=check.prepare(`SELECT world_x,world_y,state FROM characters WHERE id='char-demo'`).get();
  check.close();
  assert.equal(row.state,'TRAVELING');
  assert.equal(row.world_x,beforeMove.worldPosition.x);
  assert.equal(row.world_y,beforeMove.worldPosition.y);
});

test('existing IN_CITY-only city functions (market buy, storage move) remain rejected once the character has left for IN_WORLD',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);
  fixture.close();
  const arrived=await post('/api/commands/travel/resolve-arrival',envelope('move-leave-city-arrive',{}));
  assert.equal(arrived.status,'ACCEPTED');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.state,'IN_CITY');
  await wait(150);
  const exited=await post('/api/commands/city/exit',envelope('move-leave-city',{}));
  assert.equal(exited.status,'ACCEPTED');
  assert.equal(exited.data.state,'IN_WORLD');
  const buyAttempt=await post('/api/commands/market/buy',envelope('move-market-blocked',{approvedQuote:{cityId:snap.cityId,goodTypeId:'rice',requestedQuantity:1,unitPrice:9999,total:9999}}));
  assert.equal(buyAttempt.status,'REJECTED');
  assert.equal(buyAttempt.errorCode,'ERR_INVALID_CONTEXT');
  const moveGoods=await post('/api/commands/container/move',envelope('move-storage-blocked',{direction:'CARGO_TO_STORAGE',cityId:snap.cityId,goodTypeId:'rice',quantity:1}));
  assert.equal(moveGoods.status,'REJECTED');
  assert.equal(moveGoods.errorCode,'ERR_PHYSICAL_PRESENCE_REQUIRED');
});

test("worldPosition set by world/move survives a fresh snapshot request (reload/reconnect simulation)",async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  const reloaded=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(reloaded.worldPosition,snap.worldPosition);
  assert.equal(reloaded.state,snap.state);
});

test('world/move rejects a non-numeric or missing target payload without crashing the server',async()=>{
  await wait(150);
  const before=await request('/api/character/char-demo/snapshot');
  const badString=await post('/api/commands/world/move',envelope('move-invalid-string',{targetX:'abc',targetY:150}));
  assert.equal(badString.status,'REJECTED');
  assert.equal(badString.errorCode,'ERR_INVALID_WORLD_TARGET');
  const missing=await post('/api/commands/world/move',envelope('move-invalid-missing',{}));
  assert.equal(missing.status,'REJECTED');
  assert.equal(missing.errorCode,'ERR_INVALID_WORLD_TARGET');
  const after=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(after.worldPosition,before.worldPosition);
});

// P1-07D — Latency-Decoupled Movement (Issue #23). Simulates a sustained single-in-flight hold at a
// fixed request cadence (standing in for round-trip time, since asyncqueue.js's single-in-flight
// coalescing means "how often a request actually lands" is effectively bound by RTT) and proves the
// server grants close to the full cadence-proportional allowance each cycle — the steady-state
// throughput this whole feature exists to decouple from a flat per-call cap.
for(const cadenceMs of [400,500,700]){
  test(`world/move sustains catch-up at a ${cadenceMs}ms request cadence: each cycle's grant is close to MOVE_SPEED_RATE*cadence, not clipped to a flat per-call cap`,async()=>{
    setPosition(100,500,'IN_WORLD'); // plenty of rightward room (900px) within WORLD_BOUNDS for
                                       // every cycle's grant, and a clean slate independent of
                                       // whatever earlier tests left lastWorldMoveAt/position at
    await wait(150);
    // Anchor move: establishes a clean lastWorldMoveAt "now" so the FIRST cadence cycle's elapsed
    // time is exactly one cadence wait, not inflated by this test's own setup waits.
    const anchor=await post('/api/commands/world/move',envelope(`move-cadence-${cadenceMs}-anchor`,{targetX:100,targetY:500}));
    assert.equal(anchor.status,'ACCEPTED');
    let position=anchor.data.worldPosition;
    let totalDistance=0;
    const cycles=3;
    for(let i=0;i<cycles;i++){
      await wait(cadenceMs);
      const moved=await post('/api/commands/world/move',envelope(`move-cadence-${cadenceMs}-${i}`,{targetX:position.x+99999,targetY:position.y}));
      assert.equal(moved.status,'ACCEPTED');
      const distance=Math.hypot(moved.data.worldPosition.x-position.x,moved.data.worldPosition.y-position.y);
      totalDistance+=distance;
      position=moved.data.worldPosition;
    }
    const expectedPerCycle=MOVE_SPEED_RATE*cadenceMs,expectedTotal=expectedPerCycle*cycles;
    // Generous tolerance for real wall-clock scheduling jitter around setTimeout — the point being
    // proven is "close to the full cadence-proportional allowance every cycle", not exact-to-the-ms.
    assert.ok(totalDistance>=expectedTotal*0.85,`expected total displacement close to ${expectedTotal} (${cycles} cycles at ${cadenceMs}ms), got ${totalDistance}`);
    assert.ok(totalDistance<=expectedTotal*1.15,`expected total displacement not to exceed ${expectedTotal} by more than jitter tolerance, got ${totalDistance}`);
  });
}

test('world/move: the maximum single-command grant is close to MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS (~128.6px), achieved once elapsed time reaches the cap',async()=>{
  setPosition(100,500,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('move-cap-boundary',{targetX:100+99999,targetY:500}));
  assert.equal(moved.status,'ACCEPTED');
  const distance=Math.hypot(moved.data.worldPosition.x-100,moved.data.worldPosition.y-500);
  const expected=MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS;
  assert.ok(Math.abs(distance-expected)<expected*0.05,`expected displacement close to the ${expected}px cap, got ${distance}`);
});

test('world/move: elapsed time beyond MOVE_CATCHUP_CAP_MS does not increase the single-command allowance any further — the cap is a hard ceiling, not just a floor',async()=>{
  setPosition(100,500,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const atCap=await post('/api/commands/world/move',envelope('move-beyond-cap-a',{targetX:100+99999,targetY:500}));
  assert.equal(atCap.status,'ACCEPTED');
  const distanceAtCap=Math.hypot(atCap.data.worldPosition.x-100,atCap.data.worldPosition.y-500);
  const afterAtCap=atCap.data.worldPosition;
  await wait(MOVE_CATCHUP_CAP_MS*2+200); // twice as long an idle gap
  const beyondCap=await post('/api/commands/world/move',envelope('move-beyond-cap-b',{targetX:afterAtCap.x+99999,targetY:afterAtCap.y}));
  assert.equal(beyondCap.status,'ACCEPTED');
  const distanceBeyondCap=Math.hypot(beyondCap.data.worldPosition.x-afterAtCap.x,beyondCap.data.worldPosition.y-afterAtCap.y);
  assert.ok(Math.abs(distanceBeyondCap-distanceAtCap)<distanceAtCap*0.05,`expected the doubled-idle-gap grant (${distanceBeyondCap}) to be no larger than the at-cap grant (${distanceAtCap}), proving the cap is a hard ceiling`);
});
