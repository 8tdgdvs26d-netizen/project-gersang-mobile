import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {AuthorityModel} from '../spikes/vs01_wp01_supabase/model/authority_model.mjs';

const command=(key,overrides={})=>({sessionId:'session-a',idempotencyKey:key,moneyDelta:-10,itemId:'spike_item',quantityDelta:1,...overrides});

test('VS-01 spike: one active session and expiry-safe takeover',()=>{
  const model=new AuthorityModel({leaseMs:100});
  assert.equal(model.startSession('user-a','session-a',100).ok,true);
  assert.equal(model.startSession('user-a','session-b',150).errorCode,'ERR_SESSION_ACTIVE');
  assert.equal(model.startSession('user-a','session-b',201).ok,true);
  assert.equal(model.applyCommand('user-a',command('stale'),202).errorCode,'ERR_SESSION_STALE');
});

test('VS-01 spike: 100 duplicate deliveries mutate money, inventory and audit exactly once',()=>{
  const model=new AuthorityModel();
  model.startSession('user-a','session-a',0);
  const results=Array.from({length:100},()=>model.applyCommand('user-a',command('once'),1));
  assert.equal(results[0].replayed,false);
  assert.ok(results.slice(1).every(result=>result.replayed===true));
  assert.deepEqual(model.readState('user-a').state,{revision:1,money:990,inventory:{spike_item:1}});
  assert.equal(model.audit.length,1);
});

test('VS-01 spike: a lost response retry returns the committed revision without a second reward',()=>{
  const model=new AuthorityModel();
  model.startSession('user-a','session-a',0);
  model.applyCommand('user-a',command('lost-response'),1);
  const retry=model.applyCommand('user-a',command('lost-response'),2);
  assert.equal(retry.replayed,true);
  assert.equal(retry.state.revision,1);
  assert.equal(retry.state.money,990);
});

test('VS-01 spike: rejected commands are atomic and do not consume their idempotency key',()=>{
  const model=new AuthorityModel();
  model.startSession('user-a','session-a',0);
  const before=model.readState('user-a').state;
  assert.equal(model.applyCommand('user-a',command('repairable',{moneyDelta:-5000}),1).errorCode,'ERR_MONEY_DELTA');
  assert.deepEqual(model.readState('user-a').state,before);
  assert.equal(model.audit.length,0);
  const fixed=model.applyCommand('user-a',command('repairable'),2);
  assert.equal(fixed.ok,true);
  assert.equal(fixed.replayed,false);
});

test('VS-01 spike: cross-account reads and stale-session writes are refused',()=>{
  const model=new AuthorityModel();
  model.startSession('user-a','session-a',0);
  model.startSession('user-b','session-b',0);
  assert.equal(model.readState('user-a','user-b').errorCode,'ERR_FORBIDDEN');
  assert.equal(model.applyCommand('user-b',command('foreign'),1).errorCode,'ERR_SESSION_STALE');
  assert.equal(model.readState('user-b').state.money,1000);
});

test('VS-01 spike: rapid unique commands remain monotonic and conserve the expected deltas',()=>{
  const model=new AuthorityModel();
  model.startSession('user-a','session-a',0);
  for(let i=0;i<50;i++)assert.equal(model.applyCommand('user-a',command(`rapid-${i}`,{moneyDelta:-1}),i+1).ok,true);
  assert.deepEqual(model.readState('user-a').state,{revision:50,money:950,inventory:{spike_item:50}});
  assert.equal(model.audit.length,50);
});

test('VS-01 spike contracts keep authority and secrets out of the client',async()=>{
  const root=new URL('..',import.meta.url);
  const sql=await readFile(new URL('spikes/vs01_wp01_supabase/supabase/migrations/0001_spike.sql',root),'utf8');
  const edge=await readFile(new URL('spikes/vs01_wp01_supabase/supabase/functions/command/index.ts',root),'utf8');
  const godot=await readFile(new URL('godot/spikes/vs01_wp01_supabase/supabase_spike_client.gd',root),'utf8');
  assert.match(sql,/enable row level security/g);
  assert.match(sql,/revoke all .* authenticated/g);
  assert.match(sql,/for update/g);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/primary key \(user_id, idempotency_key\)/);
  assert.match(sql,/spike_audit_log/);
  assert.match(sql,/grant select on public\.spike_player_progress to service_role;/);
  assert.doesNotMatch(sql,/grant (insert|update|delete|all)[^;]* on public\.spike_player_progress to service_role/);
  assert.match(edge,/auth\.getUser\(\)/);
  assert.match(edge,/SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(edge,/safeDatabaseError/);
  assert.doesNotMatch(edge,/errorCode:error\.message/);
  assert.doesNotMatch(godot,/SERVICE_ROLE|service_role|SUPABASE_SERVICE/);
  assert.match(godot,/OS\.get_environment/);
  assert.match(godot,/HTTPRequest/);
});

test('VS-01 spike live runners report BLOCKED without credentials and never print secrets',async()=>{
  const root=new URL('..',import.meta.url);
  const env=Object.fromEntries(Object.entries(process.env).filter(([name])=>!name.startsWith('MYRIAL_SPIKE_')));
  for(const script of ['live_smoke.mjs','live_stress.mjs']){
    const run=spawnSync(process.execPath,[new URL(`spikes/vs01_wp01_supabase/${script}`,root).pathname],{env,encoding:'utf8'});
    assert.equal(run.status,2,script);
    assert.match(run.stderr,/BLOCKED missing environment/,script);
  }
  const stress=await readFile(new URL('spikes/vs01_wp01_supabase/live_stress.mjs',root),'utf8');
  const probe=await readFile(new URL('godot/spikes/vs01_wp01_supabase/live_probe.gd',root),'utf8');
  assert.doesNotMatch(stress,/SERVICE_ROLE|service_role/);
  assert.doesNotMatch(stress,/console\.\w+\([^)]*(token|password|key)\b/i);
  assert.doesNotMatch(probe,/SERVICE_ROLE|service_role|SUPABASE_SERVICE/);
  assert.doesNotMatch(probe,/print\([^)]*(password|access_token|_publishable_key)/);
  assert.match(probe,/quit\(2\)/);
  // HTTPRequest fails with ERR_UNCONFIGURED before the root enters the tree, which happens after _initialize.
  assert.ok(probe.indexOf('await process_frame')>-1&&probe.indexOf('await process_frame')<probe.indexOf('.new()'),'probe waits a frame before creating the client');
  const godotClient=await readFile(new URL('godot/spikes/vs01_wp01_supabase/supabase_spike_client.gd',root),'utf8');
  assert.match(godotClient,/if not is_inside_tree\(\):\s+return \{"ok": false, "errorCode": "ERR_NOT_IN_TREE"\}/);
});
