open Core.Std
open Common

module type TIME = sig
  type t (* the absolute time such as the Unix time or the time since the simulation was started *)
  type span (* the interval of time *)
  val init : unit -> t
  val compare : t -> t -> int (*TODO ask anil why explicity write this instead
  of using Core's with compare *)
  val add : t -> span -> t
  val diff : t -> t -> span
  val span_of_int : int -> span
  val span_of_float : float -> span
  val span_to_string: span -> string
  val to_string: t -> string
  val to_int: t -> int
  val wait_until: t -> unit (* a blocking wait for RES or instantaneously returns unit for a DES *)
  val store: t -> (unit -> t)
end 

module FakeTime : TIME = struct
  type t = int
  type span = int
  let init () = 0
  let compare a b = compare a b
  let add a b = a + b
  let diff a b = a - b
(*  let t_of_int t = t *)
  let span_of_int s = s
  let span_of_float = Float.to_int
  let span_to_string = string_of_int
  let to_string t = string_of_int t
  let to_int t = t
(*  let wait t span = 
    Printf.printf "fake wait %s\n%!" (to_string t); 
    add t span *)
  let wait_until _ = ()
  let store t = (fun () -> t)
end

module RealTime : TIME = struct
  type t = Time.t
  type span = Time.Span.t
  let init () = Time.now ()
  let compare = Time.compare
  let add a b = Time.add a b
(*  let t_of_int _t = Time.now () (* TODO fixme *) *)
  let span_of_int s = Time.Span.create ~ms:s ()
  let span_of_float s = span_of_int (Float.to_int s)
  let span_to_string = Time.Span.to_string 
  let to_string = Time.to_string 
  let to_int t = 
    Time.to_float t 
    |> Int.of_float
  let diff a b = Time.diff a b

(*  let wait t span =
    Printf.printf "real wait %s\n" (to_string t);
    let sec = Time.Span.to_sec span |> Float.to_int in
    Unix.sleep sec;
    Time.now () *)

  let wait_until t = 
    Time.now ()
    |> Time.diff t
    |> Time.Span.to_sec
    |> (fun t -> if (t>0.0) then ignore(Unix.nanosleep t)  else ())

  let store _ = init
end
(*
module Counter(T:TIME) = struct
  let run () =
    let t = T.init () in
    let initial_span = T.diff t t in
    let last_time = T.wait t initial_span in
    print_endline (T.to_string last_time)
end 

module FakeCounter = Counter(FakeTime)
module RealCounter = Counter(RealTime)

let () =
  FakeCounter.run ();
  RealCounter.run () *)
