import test from 'node:test';
import assert from 'node:assert/strict';
import {createCoalescingSender} from '../public/asyncqueue.js';

const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test('a single call sends immediately',async()=>{
  const calls=[];
  const send=createCoalescingSender(async target=>{calls.push(target)});
  await send('a');
  assert.deepEqual(calls,['a']);
});

test('a call arriving while one is in-flight is coalesced into a single follow-up call using only the latest target',async()=>{
  const calls=[];
  let resolveFirst;
  const send=createCoalescingSender(async target=>{
    calls.push(target);
    if(target==='first')await new Promise(resolve=>{resolveFirst=resolve});
  });
  send('first');
  await wait(5);
  send('second');
  send('third');
  send('fourth');
  assert.deepEqual(calls,['first']);
  resolveFirst();
  await wait(5);
  assert.deepEqual(calls,['first','fourth']);
});

test('the underlying sender is never invoked concurrently, even under rapid repeated calls',async()=>{
  let concurrent=0,maxConcurrent=0;
  const send=createCoalescingSender(async target=>{
    concurrent++;
    maxConcurrent=Math.max(maxConcurrent,concurrent);
    await wait(10);
    concurrent--;
  });
  for(let i=0;i<20;i++)send(i);
  await wait(200);
  assert.equal(maxConcurrent,1);
});

test('sequential calls that do not overlap in time are each sent individually, not dropped',async()=>{
  const calls=[];
  const send=createCoalescingSender(async target=>{calls.push(target)});
  await send('x');
  await send('y');
  await send('z');
  assert.deepEqual(calls,['x','y','z']);
});
