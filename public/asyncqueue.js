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
