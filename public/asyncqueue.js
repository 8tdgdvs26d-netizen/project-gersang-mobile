export function createCoalescingSender(send){
  let inFlight=false,pending=null;
  async function run(target){
    if(inFlight){pending=target;return}
    inFlight=true;
    try{await send(target)}
    finally{
      inFlight=false;
      if(pending){const next=pending;pending=null;run(next)}
    }
  }
  return run;
}


// P1-07 transport diagnostic only: unlike createCoalescingSender, this sender does not
// serialize movement behind network RTT. Calls start immediately, while completion handling is
// gated so an older request cannot overwrite state after a newer request has already completed.
// This is intentionally isolated diagnostic behavior, not an approved production transport.
export function createLatestParallelSender(send){
  let issued=0,latestCompleted=0;
  return async function run(target){
    const sequence=++issued;
    const outcome=await send(target,sequence);
    if(sequence<latestCompleted)return {staleCompletion:true,outcome};
    latestCompleted=sequence;
    return {staleCompletion:false,outcome};
  };
}
