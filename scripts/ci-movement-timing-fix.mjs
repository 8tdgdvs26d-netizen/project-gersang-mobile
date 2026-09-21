import { readFileSync, writeFileSync } from 'node:fs';

const path='test/world-movement.test.mjs';
const source=readFileSync(path,'utf8');
const start=source.indexOf('for(const cadenceMs of [400,500,700]){');
const endMarker="test('world/move: the maximum single-command grant is close to MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS (~128.6px), achieved once elapsed time reaches the cap'";
const end=source.indexOf(endMarker,start);
if(start<0||end<0)throw new Error('cadence test block not found');

const replacement=`for(const cadenceMs of [400,500,700]){
  test(\`world/move sustains catch-up at a \${cadenceMs}ms request cadence: each cycle's grant tracks the server's real elapsed-time allowance, not a nominal timer delay\`,async()=>{
    setPosition(100,500,'IN_WORLD'); // plenty of rightward room (900px) within WORLD_BOUNDS for
                                       // every cycle's grant, and a clean slate independent of
                                       // whatever earlier tests left lastWorldMoveAt/position at
    await wait(150);
    // The server bases allowance on its own Date.now() at request handling time. A client-side
    // setTimeout(cadenceMs) is only a minimum delay: under CI scheduler load it can wake late.
    // Bound each server timestamp between the local send and completion timestamps instead of
    // pretending the requested timeout duration is the actual elapsed wall-clock time.
    let previousSentAt=Date.now();
    const anchor=await post('/api/commands/world/move',envelope(\`move-cadence-\${cadenceMs}-anchor\`,{targetX:100,targetY:500}));
    let previousCompletedAt=Date.now();
    assert.equal(anchor.status,'ACCEPTED');
    let position=anchor.data.worldPosition;
    const cycles=3;
    for(let i=0;i<cycles;i++){
      await wait(cadenceMs);
      const sentAt=Date.now();
      const moved=await post('/api/commands/world/move',envelope(\`move-cadence-\${cadenceMs}-\${i}\`,{targetX:position.x+99999,targetY:position.y}));
      const completedAt=Date.now();
      assert.equal(moved.status,'ACCEPTED');
      assert.equal(moved.data.throttled,false);
      const distance=Math.hypot(moved.data.worldPosition.x-position.x,moved.data.worldPosition.y-position.y);
      const minElapsed=Math.max(0,sentAt-previousCompletedAt);
      const maxElapsed=Math.max(0,completedAt-previousSentAt);
      const minExpected=MOVE_SPEED_RATE*Math.min(minElapsed,MOVE_CATCHUP_CAP_MS);
      const maxExpected=MOVE_SPEED_RATE*Math.min(maxElapsed,MOVE_CATCHUP_CAP_MS);
      const epsilon=0.001;
      assert.ok(distance+epsilon>=minExpected,\`expected displacement \${distance} to be >= measured lower allowance \${minExpected} (elapsed >= \${minElapsed}ms)\`);
      assert.ok(distance<=maxExpected+epsilon,\`expected displacement \${distance} to be <= measured upper allowance \${maxExpected} (elapsed <= \${maxElapsed}ms)\`);
      position=moved.data.worldPosition;
      previousSentAt=sentAt;
      previousCompletedAt=completedAt;
    }
  });
}

`;

const updated=source.slice(0,start)+replacement+source.slice(end);
writeFileSync(path,updated);
