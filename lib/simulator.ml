open Core.Std
open Common
open Eventlst 
open Summary

(* [RaftSim] is a main body of the implementation, it handles the simulation, the
 * core protcol implementation and communication. This aspects need to be
 * divided up but everything depend on the State module with a functor *)

module RaftSim = 
  functor (MonoTime: Clock.TIME) ->
  functor (Mach: Statemach.MACHINE) ->
  functor (P: PARAMETERS) -> struct    

(*Setting up the StateList and State, which hold the state for the nodes *)
module StateList = Env.StateHandlerHist(MonoTime)(Mach)
module State = StateList.State

module Client = Client.ClientHandler(MonoTime)(Mach)

open Event (*needed to quickly access the event constructors like RaftEvent and SimulationEvent *)

module EventItem = struct
  type t = (MonoTime.t,IntID.t,State.t,Client.t) Event.t
  let compare = Event.compare
end

module EventList = (LinkedList(EventItem) : EVENTLIST with type item = EventItem.t)

  type eventsig = State.t -> (State.t * EventList.item list)
  type clientsig = Client.t -> (Client.t * EventList.item list)


let debug x = if (P.debug_mode) then (printf " %s  \n" x) else ()
let json x = if (P.json_mode) then (printf " %s \n" x) else ()

(* TODO: consider spliting this up into 3 functions*)
(* get the timeout on the state *)
let timeout (s:State.t) = 
  match s.mode with
  | Follower | Leader -> MonoTime.span_of_float (P.timeout () s.mode)
  | Candidate ->
    if P.backoff then
     MonoTime.span_of_float ((P.timeout () Candidate)*.((Float.of_int 2)**(Float.of_int s.backoff)))
    else
      MonoTime.span_of_float (P.timeout () Candidate)

type datacollection = {
  mutable pkts: int; 
  mutable client_pkts: int; 
  mutable firstele: MonoTime.t option;
  mutable full_latency: (MonoTime.t option ) * (MonoTime.span list);
  mutable commit_requests: int;
  mutable election_time: (IntID.t * MonoTime.t) list;
  mutable total_election_time: MonoTime.t
    }

(* The data's type is the datacollection above. *)
let data = {
  pkts=0; 
  client_pkts=0; 
  firstele=None; 
  full_latency= (None,[]); (* <option,list>. There are durations of Client Latency Timer in the list *)
  commit_requests =0;
  election_time = []; (* <id,start_time> list *)
  total_election_time = MonoTime.init();
  }

(* record counts of packet *)
let incr_pkts() =
  match (P.term_conditions LeaderEst), data.firstele with
  | false,_ | true,None -> data.pkts <- data.pkts +1
  | _ -> ()

(* election_timer id starts at the start_time when the candidate starts an election *)
let election_timer_start id start_time =
    data.election_time <- (List.Assoc.add data.election_time id start_time)

(* election_timer id stops at the stop_time when the candidate wins the election or go to follower again *)
let election_timer_stop id stop_time =
   let start_time = List.Assoc.find_exn data.election_time id  in
   let duration = MonoTime.diff stop_time start_time in
   data.election_time <- (List.Assoc.remove data.election_time id );
   data.total_election_time <- (MonoTime.add data.total_election_time duration)

(* remove all election timers *)
let rec final_election_time final_time = 
  match data.election_time with
  | [] -> ()
  | (id,start_time)::_ -> 
       let duration = MonoTime.diff final_time start_time in
        data.election_time <- (List.Assoc.remove data.election_time id );
        data.total_election_time <- (MonoTime.add data.total_election_time duration);
        final_election_time final_time

(* Client Latency Timer starts when the client sends the request, stops when the client get the committed request *)
let client_latency opt = 
  match opt with
  | `Start start_time -> (
    match data.full_latency with
    | (None,rest) -> 
        debug ("Starting Client Latency Timer at "^MonoTime.to_string start_time);
        data.full_latency <- (Some start_time,rest)
    | (Some _ ,_) -> () )
  | `Stop stop_time -> (
    match data.full_latency with
    | (None,rest) -> assert false
    | (Some start_time ,rest) -> 
      let time_diff = MonoTime.diff stop_time start_time in
      debug ("Stopping Client Latency Timer at "^MonoTime.to_string stop_time);
      data.full_latency <- ( None, time_diff::rest ) )

module type COMMS = sig
    val unicast_replica: IntID.t -> MonoTime.t -> eventsig -> EventList.item
    val unicast_client: MonoTime.t -> clientsig -> EventList.item
    val broadcast: IntID.t list -> MonoTime.t -> eventsig -> EventList.item list
  end

module type RAFT = sig

  (** Helper Functions - Called by the EventFunction to perform some computation
    at that specific time and location *)

  val startCand: eventsig
  val dispatchAppendEntries: eventsig
  val dispatchAppendEntries_unicast: IntID.t -> State.t -> EventList.item
  val startLeader: eventsig
  val refreshTimer: eventsig

  (** Event Functions , this have some kinda terporal/spacail info => 
     get stored in the EventList **)
  val checkTimer: int -> eventsig
  val startFollow: Index.t -> eventsig
  val requestVoteRq: Rpcs.RequestVoteArg.t -> eventsig
  val requestVoteRs: Rpcs.RequestVoteRes.t -> IntID.t -> eventsig
  val appendEntriesRq: Rpcs.AppendEntriesArg.t -> eventsig
  val appendEntriesRs: Rpcs.AppendEntriesRes.t -> IntID.t -> eventsig
  val clientRq: Rpcs.ClientArg.t -> eventsig

  (*Client events *)
  val clientRs: Rpcs.ClientRes.t -> clientsig
  val clientCommit: clientsig
  val checkTimer_client: int -> clientsig


end

module RaftImpl : RAFT = struct

module Comms : COMMS = struct 

(* Generate a RaftEvent which contains [e] will be delivered to the [dist] at the [t + delay] *)
let unicast_replica (dist: IntID.t) (t:MonoTime.t) (e) = 
  (*TODO: modify these to allow the user to specify some deley
   * distribution/bound *)
   (* if the probability <= P.loss ,the we drop the packet *)
 if (NumberGen.to_drop P.loss) then 
  (debug "packet dropped"; Ignore t)
 else (
  let delay = MonoTime.span_of_float (P.pkt_delay()) in
  let arriv = MonoTime.add t delay in
  debug ("dispatching msg to "^(IntID.to_string dist) ^ " to arrive at "^
  (MonoTime.to_string arriv));
  json ("'arrives':"^(MonoTime.to_string arriv)^",'sent':"^(MonoTime.to_string t)^",'dest':"^(IntID.to_string dist)^"}");
  incr_pkts();
  RaftEvent (arriv ,dist ,e ) )

(* Generate a ClientEvent which contains [e] will be delivered to the client at the [t + delay] *)
let unicast_client (t:MonoTime.t) (e) =
  if (NumberGen.to_drop P.loss) then 
  (debug "packet dropped"; Ignore t)
 else (
  let delay = MonoTime.span_of_float (P.pkt_delay()) in
  let arriv = MonoTime.add t delay in
  debug ("dispatching msg to client to arrive at "^
  (MonoTime.to_string arriv));
  data.client_pkts <- data.client_pkts + 1;
  ClientEvent (arriv, e))

(* Deliver [e] to [dests] *)
let broadcast (dests:IntID.t list) (t:MonoTime.t) e  = 
  List.map dests ~f:(fun dst -> unicast_replica(dst) t e) 

end 

(* the definition of the quorum or majority *)
let checkElection (s:State.t) = 
  (* TODO: check exactly def of majority, maybe off by one error here *)
  (List.length s.votesGranted) > ((List.length s.allNodes)+1)/2

(* the follower start the election or the candidate restart the election *)
let rec  startCand (s:State.t) = 
  debug "Entering Candidate Mode / Restarting Electon";
  let s_new =  State.tick StartCandidate s in
  let args = Rpcs.RequestVoteArg.(
    { term = s_new.term;
      cand_id = s_new.id;
      last_index = 
        if s.possible_leader then 
        s_new.lastlogIndex 
        else Index.init() |> Index.pred ;
      last_term = s_new.lastlogTerm; 
    }) in
  json("{'node':"^(IntID.to_string
  s_new.id)^",'newMode':'candidate','time':"^(MonoTime.to_string
  (s_new.time()))^",'newTerm':"^(Index.to_string
  s_new.term)^",'newInfo':'last index:"^(Index.to_string
  s_new.lastlogIndex)^"last Term:"^(Index.to_string s_new.lastlogTerm)^"'}");
  election_timer_start s.id (s.time());

  json ("{'source':"^(IntID.to_string s_new.id)^
       ",'RPC':'requestVote','info':'Request Vote Broadcast<br>term:"^(Index.to_string s_new.term)^"<br>Last Index:"^
         (Index.to_string s_new.lastlogIndex)^"<br>Last Term:"^(Index.to_string
         s_new.lastlogTerm)^ "',");
  (* Send RequestVote request *)
  let reqs = Comms.broadcast s_new.allNodes (s_new.time()) 
    (* Set callback requestVoteRq*)
    (requestVoteRq args) in
    (* Attach request to a timeout event *)
  let s_new,timeout_event = refreshTimer s_new in
  (s_new, timeout_event@reqs)

(* Generate a timeout event [RaftEvent] for the state [s] *)
and refreshTimer (s:State.t) = 
  let s_new = State.tick Set s in
  let timeout = MonoTime.add (s.time()) (timeout s) in

  json("{'node':"^(IntID.to_string s.id)^",'start':"^(MonoTime.to_string
    (s.time()))^",'expires':"^(MonoTime.to_string timeout)^"}");

  let (event:EventList.item) = RaftEvent (timeout, s.id, checkTimer s_new.timer) in 
  (s_new,[event])

(* Node will do the action after the timeout  *)
and checkTimer (timer_num:int) (s:State.t) = 
  debug "Checking timer"; 
  if (s.timer=timer_num) then (
    debug "timer is valid, need execuating";
    match s.mode with
      | Follower -> 
          debug "follower hasn't heard from leader so becoming candidate"; 
          startCand s
      | Candidate -> 
          debug "election hasn't yet been won, as timer has benn invalidated"; 
          startCand s
      | Leader -> 
          debug "heartbeat dispatch due to timeout";
          dispatchAppendEntries s )
   else (
    debug "timer no longer valid"; 
    (s,[]) )

(* The client will give another request after the timeout *)
and checkTimer_client (timer_num:int) (c:Client.t) = 
  debug "Checking timer"; 
  if (c.timer=timer_num) then (
    debug "timer is valid, need to retry";
    let c_new = Client.tick NoResponse c in
    clientCommit c_new
  ) else (
    debug "timer no longer valid"; (c,[]) )

(* this function send heartbeat versions of AppendEntries to all other nodes *)
and dispatchAppendEntries (s:State.t) =
  (* [dispatch id] will deliver AppendEntries to node [id] *)
  let dispatch id = 
    let next_index = List.Assoc.find_exn s.nextIndex id in
    let (prev_index,prev_term) = Log.specific_index_term (Index.pred (List.Assoc.find_exn s.nextIndex id)) s.log in
    let args = Rpcs.AppendEntriesArg.(
      (*just a heartbeat message *)
        { term = s.term;
        lead_id = s.id;
        prevLogIndex = prev_index;
        prevLogTerm = prev_term;
        leaderCommit = s.commitIndex;
        entries = List.map (Log.get_entries next_index s.log) 
          ~f:(fun (i,t,c_sexp) -> (i,t,Mach.sexp_of_cmd c_sexp)) ; (*emprt list means this is heartbeat *)
        } ) in
    json ("{'source':"^(IntID.to_string
    s.id)^",'RPC':'appendEntries','info':'append entries heartbeat<br>term:"^(Index.to_string
    s.term)^"<br>prevLogIndex:"^(Index.to_string
    prev_index)^"<br>prevLogTerm:"^(Index.to_string
    prev_term)^"<br>leaderCommit:"^(Index.to_string s.commitIndex)^"',");   
  Comms.unicast_replica id (s.time()) 
    (appendEntriesRq args) in
  let reqs = List.map s.allNodes ~f:dispatch in
  let s_new,timeout_event = refreshTimer s in
  (s_new, timeout_event@reqs )
(* It will send AppendEntries to the node [id] *)
and dispatchAppendEntries_unicast id (s:State.t) =
    let next_index = List.Assoc.find_exn s.nextIndex id in
    let (prev_index,prev_term) = Log.specific_index_term (Index.pred (List.Assoc.find_exn s.nextIndex id)) s.log in
    let args = Rpcs.AppendEntriesArg.(
      (*just a heartbeat message *)
        { term = s.term;
        lead_id = s.id;
        prevLogIndex = prev_index;
        prevLogTerm = prev_term;
        leaderCommit = s.commitIndex;
        entries = List.map (Log.get_entries next_index s.log) 
          ~f:(fun (i,t,c_sexp) -> (i,t,Mach.sexp_of_cmd c_sexp)) ; (*emprt list means this is heartbeat *)
        } ) in  
  Comms.unicast_replica id (s.time()) (appendEntriesRq args) 

(* The node stepdown to the follower *)
and startFollow term (s:State.t)  = debug "Entering Follower mode";
  (* used for setdown too so need to reset follower state *)
  let s = State.tick (StepDown term) s in 
  json("{'node':"^(IntID.to_string
    s.id)^",'newMode':'follower','time':"^(MonoTime.to_string
    (s.time()))^",'newTerm':"^(Index.to_string
    s.term)^",'newInfo':'last index:"^(Index.to_string
    s.lastlogIndex)^"last Term:"^(Index.to_string s.lastlogTerm)^"'}"); 

  refreshTimer s

(* The candidate wins the quorum and becomes the leader*)
and startLeader (s:State.t) = 
  debug "Election Won - Becoming Leader";
  if (data.firstele=None) then data.firstele <- Some (s.time()) else ();
  (* The node converts to the leader and the leader sends AE requests *)
  let s_new,dispatch_pkts = dispatchAppendEntries (State.tick StartLeader s) in
  (* Close the election timer *)
  election_timer_stop s.id (s.time());
  json("{'node':"^(IntID.to_string
    s_new.id)^",'newMode':'leader','time':"^(MonoTime.to_string
    (s_new.time()))^",'newTerm':"^(Index.to_string
    s_new.term)^",'newInfo':'last index:"^(Index.to_string
    s_new.lastlogIndex)^"last Term:"^(Index.to_string s_new.lastlogTerm)^"'}");
  (s_new, dispatch_pkts)

(* The comparison between [incoming_mode,term] with [s.mode,s.term]*)
(* Some actions will be taken after the comparison *)
and stepDown incoming_mode term lead_id_maybe (s:State.t) = 
  let s_new,e_new = (
      if (term > s.term) then 
        match s.mode with  
      | Leader -> 
        startFollow term s
      | Candidate ->  startFollow term s
      | Follower -> 
        (State.tick (SetTerm term) s,[])  
      else if (term=s.term)&&(incoming_mode=Leader) then
        match s.mode with
      | Leader -> 
      debug "we have two leaders in one term";
      assert false
      | Candidate -> 
      debug "leader has been discovered, stopping election and step down";
      election_timer_stop s.id (s.time());
      startFollow term s
      | Follower -> 
      debug "all is upto date"; 
      (s,[]) 
      else if (term=s.term)&&(incoming_mode=Candidate) then
         match s.mode with
      | Leader -> 
      debug "ignore candidate in this term";
      (s,[])
      | Candidate -> 
      debug "competing candidate";
      (s,[])
      | Follower -> 
      debug "all is well";
      (s,[]) 
       else (s,[])) in
    match lead_id_maybe with
    | Some id -> (State.tick (SetLeader id) s_new), e_new
    | None -> s_new,e_new
           
  (* TODO check if this case it handled correctly *)
  (* else if (term=s.term) && (s.mode=Leader) then startFollower term s *) 

  (* TODO ask anil why s needs to explicitly annotated to access its field *)

(* When the node receive a RV request,it will call the function and send the response *)
and requestVoteRq (args: Rpcs.RequestVoteArg.t) (s:State.t) =
  debug ("I've got a vote request from: "^ IntID.to_string args.cand_id^ 
         " term number: "^Index.to_string args.term);
  debug (Rpcs.RequestVoteArg.to_string args);
  let (s_new:State.t),e_new = stepDown Candidate args.term None s in
  json ("{'source':"^(IntID.to_string
    args.cand_id)^",'RPC':'requestVote','info':'vote request<br>term:"^(Index.to_string
    s_new.term)^"<br>lastIndex:"^(Index.to_string
    s_new.lastlogIndex)^"<br>lastTerm:"^(Index.to_string
    s_new.lastlogTerm)^"',");
  (* Grant the vote or not *)
  let vote = 
    (args.term = s_new.term) &&  (
    (args.last_term > s_new.lastlogTerm ) || 
    ( (args.last_term = s_new.lastlogTerm ) && 
      (args.last_index >= s_new.lastlogIndex ) ))  && 
    (s_new.votedFor = None) &&
    (s.mode=Follower)
  in
  let s_new,e_new = 
   ( if vote then (
      debug "vote will be granted";
      refreshTimer (State.tick (Vote args.cand_id) s_new) )
    else 
      (*no changes required *) (
      debug "vote will not be granted";
      s_new,e_new  ))in
  let res = 
    Rpcs.RequestVoteRes.(
      { term = s_new.term;
        votegranted = vote;
        replyto = args;
      }) in
  json ("{'source':"^(IntID.to_string
    s_new.id)^",'RPC':'requestVote','info':'vote reply:"^(string_of_bool vote)^"<br>term:"^(Index.to_string
    s_new.term)^"<br>lastIndex:"^(Index.to_string
    s_new.lastlogIndex)^"<br>lastTerm:"^(Index.to_string
    s_new.lastlogTerm)^"',");
  (s_new, (Comms.unicast_replica(args.cand_id) (s_new.time()) (requestVoteRs res
  s_new.id))::e_new)
  
(* When the node receive a RV response,it will call the function *)
and requestVoteRs (res: Rpcs.RequestVoteRes.t) id (s:State.t) = 
  debug ("Receive vote request reply from "^ IntID.to_string id );
  debug (Rpcs.RequestVoteRes.to_string res);
  (* TODO: consider how term check may effect old votes in the network *)
  if (res.term > s.term)  
    then startFollow res.term s
  else (
    if (s.mode=Candidate)&&(s.term=res.term) 
      then ( 
      let s = State.tick (VoteFrom (id,res.votegranted)) s in
      if (res.votegranted) then (
        debug "Vote was granted";
        (* Get the quorum and Go to the leader *)
        (if (checkElection s) then startLeader s else (s, [])) 
      ) else(
        debug "Vote wasn't granted"; (s,[]) 
      )
      ) else (s, []) )

(* When the node receive a AE request,it will call the function and send the response *)
and appendEntriesRq (args: Rpcs.AppendEntriesArg.t) (s:State.t) =
  (* in terms of log consistenty there our 4 states: 
     - perfect consisenty - just append entries
     - consistent to (term,index) - just remove extra entries and append
     - inconsistent at (term,index) - reply false
     - not even at (term,index) let - reply false *)
  debug ("Recieve hearbeat from "^IntID.to_string args.lead_id);
  debug (Rpcs.AppendEntriesArg.to_string args);
  if (args.term >= s.term) then 
    begin
    debug ("this AppendEntries is up to date and therefore valid");
    (*if required then stepDown from leader or follower or/and update term *)
    let (s_new:State.t),e_stepdown = 
        debug "handling the new term info";
        stepDown Leader args.term (Some args.lead_id) s in
    let s_new,e_timeout = refreshTimer s_new in
    debug("we are now in the same term");
    assert (s_new.mode=Follower);
    assert (s_new.term=args.term); 
    assert (s_new.leader=Some args.lead_id);
    (*TODO: investigate ordering of theres event, in particular commit Index and AppendEntries *)
    match (Log.consistency_check s_new.log args.prevLogIndex args.prevLogTerm) with
    | `Consistent-> 
          (* begin by removing surplus entries if required *)
          let s_new = (
            if (args.prevLogIndex=s_new.lastlogIndex)&&(args.prevLogTerm=s_new.lastlogTerm) then (
              debug("My log is perfectally consistent with the leader so no removals needed"); s_new
            ) else (   
              debug ("My log is consistent until prevLogIndex");
              (* RAFT SPEC: If an existing entry conflicts with a new one (same index 
              but different terms), delete the existing entry and all that 
              follow it (§5.3) *)
              State.tick (RemoveEntries (args.prevLogIndex,args.prevLogTerm)) s_new ) ) in 
          (* next add entries if required *)
          let s_new = (
            match args.entries with
            | [] -> debug("this is a heartbeat message"); s_new
            | x::xs -> debug ("this is not a heartbeat");
                let entries_cmd = List.map args.entries ~f:(fun (i,t,c_sexp) -> (i,t,Mach.cmd_of_sexp c_sexp)) in
                State.tick (AppendEntries entries_cmd) s_new  ) in
          (* RAFT SPEC: If leaderCommit > commitIndex, set commitIndex = min(leaderCommit, last log index) *)
          let s_new = (
              if (args.leaderCommit > s.commitIndex) then (
                debug "updating commitIndex";
                State.tick (Commit args.leaderCommit) s_new )
              else (
                debug "not updating commitIndex";
                s_new )) in
          (*works finished now sent reply *)
         json ("{'source':"^(IntID.to_string
         s.id)^",'RPC':'appendEntries','info':'appendEntries Response<br>Successful<br>term:"^
         (Index.to_string s_new.term)^"',");
          let res = Rpcs.AppendEntriesRes.(
                { term = s_new.term; success=true; replyto = args; follower_id = s.id;} ) in
          (s_new,(Comms.unicast_replica(args.lead_id) (s_new.time()) (appendEntriesRs res s.id))::e_stepdown@e_timeout)
    | `Inconsistent -> (
          debug ("not consistent at prevLogIndex so fail");
        (* RAFT SPEC: Reply false if log doesn’t contain an entry at prevLogIndex
         whose term matches prevLogTerm (§5.3) *)
        (*TODO: workout when entry should actually be removed *)
       let res = Rpcs.AppendEntriesRes.(
        { term = s_new.term; success= false; replyto = args; follower_id = s.id;} ) in
        json ("{'source':"^(IntID.to_string
         s.id)^",'RPC':'appendEntries','info':'appendEntries Response<br>Failed - log inconsistent<br>term:"^
         (Index.to_string s_new.term)^"',");
        (s_new,(Comms.unicast_replica(args.lead_id) (s_new.time()) (appendEntriesRs res s.id))::e_stepdown@e_timeout) )

    end
  else
    (* RAFT SPEC: Reply false if term < currentTerm (§5.1) *)
    begin
    debug("this AppendEntries is behind the time, so ignore");
    let res = Rpcs.AppendEntriesRes.(
    { term = s.term; success= false; replyto = args; follower_id = s.id;} ) in
    json ("{'source':"^(IntID.to_string
         s.id)^",'RPC':'appendEntries','info':'appendEntries Response<br>Failed - term too low<br>term:"^
         (Index.to_string s.term)^"',");
    (s,[Comms.unicast_replica(args.lead_id) (s.time()) (appendEntriesRs res s.id)])
    end

(* When the node receive a AE response,it will call the function*)
and appendEntriesRs (res: Rpcs.AppendEntriesRes.t) id (s:State.t) =
  debug (Rpcs.AppendEntriesRes.to_string res);
  (* 3 term cases: *)
  if (res.term>s.term) then (
    debug "step down, I'm no longer leader, ignore packet";
    (startFollow res.term s)
  ) else if (res.term<s.term) then (
    debug "this message is delayed so ignore it";
    (s,[])
  ) else (
    (* assert(s.mode=Leader); *)
    (* we have same terms so proceed *)
  match res.success with
  | true -> (
    debug "Successfully added to followers log"; 
    assert (s.mode=Leader);
    let new_index = (
      match res.replyto.entries with
     | [] -> (*it was a heartbeat so nextIndex is already correct *)
        res.replyto.prevLogIndex
     | (i,_,_)::_ -> i) in
    (* update commit index *)
    let s_new = State.tick (ReplicationSuccess (res.follower_id, new_index)) s in
    match (s_new.outstanding_request) with
    (* handle replying to client *)
    | Some (i,args) ->
    debug ("we have an outstanding request "^(Index.to_string i));
    debug ("we are ready to commit upto (inclusive) "^(Index.to_string s_new.commitIndex));
       begin
        if (i=s_new.commitIndex) then (
          let s_new = State.tick RemoveClientRes s_new in
          let s_new = State.tick (Commit i) s_new in (
          match (Mach.check_cmd s_new.state_mach (Mach.cmd_of_sexp args.cmd)) with
         | Some res ->
            let result = Mach.sexp_of_res res in
            let res = { Rpcs.ClientRes.success = Some result; node_id = s_new.id; leader = s_new.leader; replyto=args; } in
            (s_new, [Comms.unicast_client (s.time()) (clientRs res)]) 
         | None ->
            debug "this is a delayed request so ignore"; 
            (s_new,[]) ))
        else if (i>s_new.commitIndex) then (
          debug "try to commit but can't yet"; (s_new,[]) )
        else (
          debug "over commited"; assert false )
       end
    (* no outstanding client requests *)
    | None -> 
    debug "we have no outstanding requests";
    (s_new,[]) )
  | false -> (
    debug "Unsuccessful at adding to followers log";
    match s.mode with
    | Leader -> (
      let s_new = State.tick (ReplicationFailure (res.follower_id, res.replyto.prevLogIndex)) s in
      if P.cons 
        then (s_new,[])
        else (s_new, [dispatchAppendEntries_unicast id s_new]) )
    | Candidate | Follower -> (s,[]) ) )

(* When the node receive a client request,it will call the function and send the response *)
 and clientRq (args: Rpcs.ClientArg.t) (s:State.t) = 
  debug (Rpcs.ClientArg.to_string args);
  let cmd = Mach.cmd_of_sexp args.cmd in
  match s.mode , (Mach.check_cmd s.state_mach cmd) with
  | Follower, None  | Candidate, None ->
    let res = { Rpcs.ClientRes.success = None; node_id = s.id; leader = s.leader; replyto = args; } in
    debug("I'm not the leader so can't commit");
    (s, [Comms.unicast_client (s.time()) (clientRs res)] )
  | _, Some result -> 
    debug "This command has already been committed";
          let s_new = State.tick RemoveClientRes s in
          let res = { Rpcs.ClientRes.success = Some (Mach.sexp_of_res result) ; node_id = s.id; leader = s.leader; replyto = args; } in
          (s_new, [Comms.unicast_client (s.time()) (clientRs res)])
  | Leader, None -> (
    if (Mach.expected_serial s.state_mach cmd) then (
    let entry_index = Index.succ s.lastlogIndex in
    let log_entry = (entry_index, s.term, (Mach.cmd_of_sexp args.cmd)) in
    let to_string (i,t,c) = (Index.to_string i)^" "^(Index.to_string t)^" "^(Mach.cmd_to_string c) in
    let s_new = State.tick (AppendEntry log_entry) s in
  (*  let s_new = State.tick (Commit entry_index) s_new in *)
    let s_new = State.tick (AddClientRequest (entry_index,args)) s_new in
    debug("I'm the leader so will try to commit command "^to_string log_entry);
    (if P.cons then
    (s_new, [] ) else dispatchAppendEntries s_new ))
    else 
    ( debug ("State machine isn't expecting this cmd so ignore"); (s,[]))
    )

(* When the node receive a client response,it will call the function and send the response *)
and clientRs (res: Rpcs.ClientRes.t) (s:Client.t) = 
  (*TODO: make check if old packets mess this up *)
  debug ("Simulating clients response");
  debug (Rpcs.ClientRes.to_string res);
  match List.hd s.workload with
  | Some request when ( Mach.cmd_of_sexp res.replyto.cmd ) = request -> (
      match res.success with
      | Some result_sexp -> 
        let result = Mach.res_of_sexp result_sexp in 
        let timer = MonoTime.add (s.time()) (MonoTime.span_of_int P.client_wait_success ) in
        debug ("successfully committed result is "^Mach.res_to_string result); 
        debug ("Expected result is "^Mach.res_to_string (List.hd_exn s.expected_results));
        client_latency (`Stop (s.time()) );
        let s_new = Client.tick (Successful (res.node_id,result) )s in
        (s_new,[ClientEvent (timer,clientCommit) ]) 
      | None -> debug "unsucessful, try again";
        let s_new = Client.tick (Unsuccessful (res.node_id,res.leader) ) s in
       let timer = MonoTime.add (s.time()) (MonoTime.span_of_int P.client_wait_failure ) in   
        (s_new,[ClientEvent (timer,clientCommit)])  )
  | Some _ | None -> 
    debug "ignoring reponse as its not for the currently outstanding request"; (s,[])

(* client send a request *)
and clientCommit (s: Client.t) =
  match (s.workload) with
  | cmd::later -> 
    debug ("Client is attempting to commit "^(Mach.cmd_to_string cmd)) ;
    data.commit_requests <- data.commit_requests +1;
    client_latency (`Start (s.time()) );
    let args = {Rpcs.ClientArg.cmd = (Mach.sexp_of_cmd cmd); } in
    let s_new = Client.tick Set s in
    let timeout = MonoTime.add (s_new.time()) (MonoTime.span_of_int P.client_timeout) in
    let timer_check = ClientEvent (timeout,checkTimer_client s_new.timer) in
    (match s.leader with
    | Leader id -> 
      json ("{'source':'client','RPC':'clientRq','info':'Client attempting to commit:<br>"^(Mach.cmd_to_string cmd)^"<br>Believes leader to be:"^
         (IntID.to_string id)^"',");
      (s_new, [timer_check; Comms.unicast_replica id (s.time()) (clientRq args) ])
    | TryAsking (id::_) -> 
      json ("{'source':'client','RPC':'clientRq','info':'Client attempting to commit:<br>"^(Mach.cmd_to_string cmd)^"<br>Trying:"^
         (IntID.to_string id)^"',");
      (s_new, [timer_check; Comms.unicast_replica id (s.time()) (clientRq args) ]) )
  | [] -> 
    debug "successfully committed all commands "; (s,[])

end



let start_time = MonoTime.init()


let nxt_failure (t:MonoTime.t) = 
  match P.nxt_failure with
  | Some dl ->
    let delay = MonoTime.span_of_float (dl ()) in
    MonoTime.add t delay

let nxt_recover (t:MonoTime.t) = 
  match P.nxt_failure with
  | Some dl ->
  let delay = MonoTime.span_of_float (dl ()) in
  MonoTime.add t delay

let span_to_string (time:MonoTime.t) =
   let duration = MonoTime.diff (time) start_time in
    MonoTime.span_to_string (duration)

let state_span (sl:StateList.t) = 
  (* TODO: fix this so it finds the first live node *)
  (*let state = match (StateList.find sl (IntID.from_int 0)) with Live x -> x in*)
  match StateList.get_leader sl with
    | None -> assert false
    | Some (state) -> span_to_string (state.time()) 

let termination_output reason sl (cl: Client.t) =
  let time_str = match reason with
    | LeaderEst -> 
      state_span sl
    | WorkloadEmpty -> 
      span_to_string (cl.time()) 
    | Timeout -> 
      MonoTime.span_to_string (MonoTime.span_of_int P.term_time) in
  let first_election = 
    match data.firstele with 
      Some x -> Some (MonoTime.to_int x)
      | None -> None in
   let latency_list = List.rev (match data.full_latency with (_,lst) -> lst) in
  let ava = ( (Int.to_float (List.length latency_list)) /.(Int.to_float data.commit_requests)) *. 100.0 in
  final_election_time (cl.time());
 (* let term_str = Index.to_string StateList.get_leader term in *)
  {
  reason = reason;
  time = time_str;
  replica_pkts = data.pkts;
  client_pkts = data.client_pkts;
  leader_est = first_election;
  client_latency = (List.to_string ~f:MonoTime.span_to_string latency_list);
  avalability = ava;
  election_time = MonoTime.to_string data.total_election_time; 
  }

let wake (s:State.t) : EventList.item list =
  debug ((IntID.to_string s.id)^" node is restarting after failing");
  let timeout = MonoTime.add (s.time()) (timeout s) in
  let (event:EventList.item) = RaftEvent (timeout, s.id, RaftImpl.checkTimer s.timer) in 
  [(SimulationEvent (nxt_failure (s.time()), s.id, Kill)); event]

let kill (s:State.t) = 
  debug ((IntID.to_string s.id)^"node has failed");
  [SimulationEvent (nxt_recover (s.time()), s.id, Wake)]

(* the simulator apply raft event *)
let apply_RaftEvent (st: State.t status) (e: (MonoTime.t,IntID.t,State.t,Client.t) event) (t: MonoTime.t) 
   : (State.t * EventList.item list) option =
  (* wait used in realtime simulation, just instant unit for DES *)
  MonoTime.wait_until t;
  match st with 
  | Live s ->
     debug ("Start Simulating event on node "^(IntID.to_string s.id));
     let s = State.tick (SetTime t) s in
     let s_new,e_new = e s in
     debug (State.print s_new);
     Some (s_new,e_new)
 | Down s -> (*node is down so event is lost *)
     debug ("Discard event, for node "^(IntID.to_string s.id));
     None
 | Notfound -> assert false

(* the simulator apply wake or kill event *)
let apply_SimulationEvent (sl: StateList.t) (e: failures) (t: MonoTime.t) (id:IntID.t) 
   : StateList.t * EventList.item list =
  MonoTime.wait_until t;
  (
  match e with 
  | Wake -> 
      debug ("Simulating recovery for node "^(IntID.to_string id)); 
      let sl_new = StateList.wake sl id t in (* handle state changes *)
      let s_new = StateList.find_wst sl_new id in 
      let e_new = wake s_new  in(*handle waking events *)
      debug (State.print s_new);
      (sl_new,e_new)
  | Kill ->
      debug ("Simulating failure for node "^(IntID.to_string id)); 
      let sl_new = StateList.kill sl id t in
      let e_new = kill (StateList.find_wst sl_new id) in
      (sl_new,e_new) )

(* the simulator apply client event *)
let apply_ClientEvent (cl: Client.t) (e: (MonoTime.t,IntID.t,State.t,Client.t) client) (t: MonoTime.t) 
   : (Client.t * EventList.item list) =
  (* wait used in realtime simulation, just instant unit for DES *)
  MonoTime.wait_until t;
  debug "Simulating Client Event";
     let cl = Client.tick (SetTime t) cl in
     let cl_new,e_new = e cl in
     debug (Client.print cl_new);
     (cl_new,e_new)

(* terminate the simulation process *)
let terminate reason sl cl = 
  (match reason with
  | LeaderEst -> debug "terminating as leader has been agreed"
  | WorkloadEmpty -> debug "terminating as all commands have been commited " 
  | Timeout -> debug "terminating as terminate time has been reached");
  debug "checking simulation was safe";
  debug (StateList.check_safety sl);
  termination_output reason sl cl

(* the core of the simulator *)
(* Main excuation cycle *)  
let rec run_multi
  (sl: StateList.t) 
  (el: EventList.t)
  (cl: Client.t)  =
  (* checking termination condition for tests *)
    if (P.term_conditions LeaderEst)&&(StateList.leader_agreed sl) then 
    terminate LeaderEst sl cl
    else if (P.term_conditions WorkloadEmpty)&&(cl.workload=[]) then
    terminate WorkloadEmpty sl cl
    else 
  (* we will not be terminating as the term condition has been reached so get
   * the next event in the event queue and apply it *)
  match EventList.hd el with
  | None -> 
      debug "terminating as no events remaining"; 
      assert false (* debug "terminating as no events remain"; (span_to_string (cl.time())) *)
  (* next event is a simulated failure/recovery *)
  | Some (SimulationEvent (t,id,e),els) -> 
      let sl_new, el_new = apply_SimulationEvent sl e t id in
      assert (
        match StateList.find sl_new id, e with 
        | Live _, Wake | Down _, Kill -> true
        | _ -> false);
      run_multi sl_new (EventList.add el_new els) cl
  (* next event is some computation at a node *)
  | Some (RaftEvent (t,id,e),els) -> (
      match (apply_RaftEvent (StateList.find sl id) e t) with
      | Some (s_new,el_new) -> run_multi (StateList.add sl id s_new) (EventList.add el_new els) cl
      | None -> run_multi sl els cl )

 | Some (ClientEvent (t,e),els) -> (
      let (cl_new,el_new) = apply_ClientEvent cl e t in
      run_multi sl (EventList.add el_new els) cl_new )

  | Some (Terminate t,_) -> 
      terminate Timeout sl cl

  | Some (Ignore t, els) -> run_multi sl els cl

(* initialize the eventlist with raft event, simulation event, term event, client event *)
let init_eventlist num  :EventList.t  =  
  let initial_RaftEvent = 
    List.init num ~f:(fun i ->
    RaftEvent (MonoTime.init(), IntID.from_int i, RaftImpl.startFollow (Index.init()) ) ) in
  let initial_SimulationEvent = 
    match P.nxt_failure with
    | Some _ ->
      List.init num ~f:(fun i -> SimulationEvent (nxt_failure (MonoTime.init()), IntID.from_int i, Kill)) 
    | None -> [] in
  let term_event = [Terminate (MonoTime.add start_time (MonoTime.span_of_int P.term_time))] in
  let inital_ClientEvent = [ClientEvent (MonoTime.init(), RaftImpl.clientCommit)] in
  EventList.init (initial_SimulationEvent@initial_RaftEvent@inital_ClientEvent@term_event)

(* Start the Simulator *)
let start () =
  debug "Raft Simulator is Starting Up ...";
  json ("'numNodes':"^(string_of_int P.nodes)^",");
  run_multi 
  (StateList.init P.nodes P.hist P.possible_leaders)  
  (init_eventlist P.nodes)
  (Client.init P.nodes P.workload_size)

end
